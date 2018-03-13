-module(metric_vnode).
-behaviour(riak_core_vnode).

-include_lib("riak_core/include/riak_core_vnode.hrl").
-include_lib("mmath/include/mmath.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([start_vnode/1,
         init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         get_bitmap/4,
         delete/1,
         repair/3,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_info/2,
         handle_overload_command/3,
         handle_overload_info/2,
         handle_exit/3]).

-export([mput/3, put/5, get/5]).

-export([
         object_info/1,
         request_hash/1,
         nval_map/1
        ]).

-ignore_xref([
              object_info/1,
              request_hash/1,
              nval_map/1
             ]).

-ignore_xref([
              start_vnode/1,
              put/5,
              mput/3,
              get/4,
              repair/4,
              handle_info/2,
              repair/3
             ]).

-record(state, {
          %% The partition (i.e. vnode)
          partition :: pos_integer(),
          %% The node itself
          node :: node(),
          cache,
          %% PID of the io node
          io :: metric_io:io_handle(),
          %% the current time
          now :: pos_integer() ,
          %% Resolution cache
          bucket_info = btrie:new()
         }).

-define(MASTER, metric_vnode_master).

%% API

get_bitmap(PN, Bucket, Metric, Time) ->
    Ref = make_ref(),
    ok = riak_core_vnode_master:command(
           [PN],
           {bitmap, self(), Ref, Bucket, Metric, Time},
           raw,
           ?MASTER),
    receive
        {reply, Ref, Reply} ->
            Reply
    after
        5000 ->
            {error, timeout}
    end.

start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

repair(IdxNode, {Bucket, Metric}, {Time, Obj}) ->
    riak_core_vnode_master:command(
      IdxNode,
      {repair, Bucket, Metric, Time, Obj},
      ignore,
      ?MASTER).


put(Preflist, ReqID, Bucket, Metric, {Time, Values}) when is_list(Values) ->
    put(Preflist, ReqID, Bucket, Metric,
        {Time, << <<?INT:?TYPE_SIZE, V:?BITS/?INT_TYPE>> || V <- Values >>});

put(Preflist, ReqID, Bucket, Metric, {Time, Value}) when is_integer(Value) ->
    put(Preflist, ReqID, Bucket, Metric,
        {Time, <<?INT:?TYPE_SIZE, Value:?BITS/?INT_TYPE>>});

put(Preflist, ReqID, Bucket, Metric, {Time, Value}) ->
    riak_core_vnode_master:command(Preflist,
                                   {put, Bucket, Metric, {Time, Value}},
                                   {raw, ReqID, self()},
                                   ?MASTER).

mput(Preflist, ReqID, Data) ->
    riak_core_vnode_master:command(Preflist,
                                   {mput, Data},
                                   {raw, ReqID, self()},
                                   ?MASTER).

get(Preflist, ReqID, {Bucket, Metric}, HPTS, {Time, Count}) ->
    riak_core_vnode_master:command(Preflist,
                                   {get, ReqID, Bucket, Metric, HPTS,
                                    {Time, Count}},
                                   {fsm, undefined, self()},
                                   ?MASTER).
init([Partition]) ->
    ok = dalmatiner_vacuum:register(),
    process_flag(trap_exit, true),
    WorkerPoolSize = case application:get_env(metric_vnode, async_workers) of
                         {ok, Val} ->
                             Val;
                         undefined ->
                             5
                     end,
    FoldWorkerPool = {pool, metric_worker, WorkerPoolSize, []},
    {ok, IO} = metric_io:start_link(Partition),
    {ok, update_env(#state{
                       partition = Partition,
                       node = node(),
                       cache = new_cache(),
                       io = IO,
                       now = timestamp()
                      }),
     [FoldWorkerPool]}.

handle_command({bitmap, From, Ref, Bucket, Metric, Time},
               _Sender, State = #state{io = IO, cache = C})
  when is_binary(Bucket), is_binary(Metric), is_integer(Time),
       Time >= 0 ->
    case mcache:take(C, Bucket, Metric) of
        {ok, Data} ->
            write_chunks(State#state.io, Bucket, Metric, Data);
        _ ->
            ok
    end,
    metric_io:get_bitmap(IO, Bucket, Metric, Time, Ref, From),
    {noreply, State};

%% Repair request are always full values not including non set values!2
handle_command({repair, Bucket, Metric, Time, Value}, _Sender, State)
  when is_binary(Bucket), is_binary(Metric), is_integer(Time) ->
    Count = mmath_bin:length(Value),
    case valid_ts(Time + Count, Bucket, State) of
        {true, _, State1} ->
            State2 = do_put(Bucket, Metric, Time, Value, State1),
            {noreply, State2};
        {false, _, State1} ->
            {noreply, State1}
    end;

handle_command({mput, Data}, _Sender, State) ->
    State1 = lists:foldl(fun({Bucket, Metric, Time, Value}, StateAcc)
                               when is_binary(Bucket), is_binary(Metric),
                                    is_integer(Time) ->
                                 do_put(Bucket, Metric, Time, Value, StateAcc)
                         end, State, Data),
    {reply, ok, State1};

handle_command({put, Bucket, Metric, {Time, Value}}, _Sender, State)
  when is_binary(Bucket), is_binary(Metric), is_integer(Time) ->
    State1=  do_put(Bucket, Metric, Time, Value, State),
    {reply, ok, State1};

handle_command({get, ReqID, Bucket, Metric, HPTS, {Time, Count}}, Sender,
               #state{cache = C, io=IO, node=N, partition=P} = State) ->
    case mcache:get(C, Bucket, Metric) of
        %% we do have cached data!
        {ok, Data} ->
            {#{hpts := BktHPTS}, State1} = get_bucket_info(Bucket, State),
            DataSize = case BktHPTS of
                           true ->
                               ?DATA_SIZE * 2;
                           false ->
                               ?DATA_SIZE
                       end,
            case get_overlap(Time, Count, DataSize, Data) of
                %% but there is no overlap
                undefined ->
                    metric_io:read(IO, Bucket, Metric, Time, Count, HPTS,
                                   ReqID, Sender),
                    {noreply, State1};
                %% we have all in the cache!
                {ok, Time, Bin} when byte_size(Bin) div DataSize == Count ->
                    %% We might need to alter the reply
                    case {BktHPTS, HPTS} of
                        {true, false} ->
                            {reply, {ok, ReqID, {P, N},
                                     mmath_hpts:values(Bin)}, State1};
                        _ ->
                            {reply, {ok, ReqID, {P, N}, Bin}, State1}
                    end;

                %% The request is neither before, after nor entirely inside the
                %% cache we have to read data, but apply cached part on top of
                %% it.
                {ok, _PartStart, _Bin} ->
                    %% This seems problematic, we'll just revert to old
                    %% behaviour of write then read. Optinisations ca
                    %% happen later.
                    %% OLD:
                    %%Offset = PartStart - Time,
                    %%Part = {Offset, byte_size(Bin) div DataSize, Bin},
                    %%metric_io:read_rest(
                    %%  IO, Bucket, Metric, Time, Count, Part, ReqID, Sender),
                    %% We evict the data we're going to write from the cache.
                    {ok, _} = mcache:take(C, Bucket, Metric),
                    write_chunks(State1#state.io, Bucket, Metric, Data),
                    metric_io:read(IO, Bucket, Metric, Time, Count, HPTS,
                                   ReqID, Sender),
                    {noreply, State1}
            end;
        _ ->
            metric_io:read(IO, Bucket, Metric, Time, Count,
                           HPTS, ReqID, Sender),
            {noreply, State}
    end;

handle_command(?FOLD_REQ{foldfun=Fun, acc0=Acc0}, Sender,
               State=#state{cache = C, io = IO}) ->
    empty_cache(C, IO),
    FinishFun =
        fun(Acc) ->
                riak_core_vnode:reply(Sender, Acc)
        end,
    case metric_io:fold(IO, Fun, Acc0) of
        {ok, AsyncWork} ->
            {async, {fold, AsyncWork, FinishFun}, Sender, State};
        empty ->
            {async, {fold, fun() -> Acc0 end, FinishFun}, Sender, State}
    end.

handle_handoff_command(?FOLD_REQ{foldfun=Fun, acc0=Acc0}, Sender,
                       State=#state{cache = C, io = IO}) ->
    empty_cache(C, IO),
    FinishFun =
        fun(Acc) ->
                riak_core_vnode:reply(Sender, Acc)
        end,
    case metric_io:fold(IO, Fun, Acc0) of
        {ok, AsyncWork} ->
            {async, {fold, AsyncWork, FinishFun}, Sender, State};
        empty ->
            {async, {fold, fun() -> Acc0 end, FinishFun}, Sender, State}
    end;

%% We want to forward all the other handoff commands
handle_handoff_command(_Message, _Sender, State) ->
    {forward, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

decode_v2_handoff_data(<<02:16, Compressed/binary>>) ->
    {ok, Decompressed} = snappiest:decompress(Compressed),
    Decompressed.

handle_handoff_data(In, State) ->
    Data = case riak_core_capability:get({ddb, handoff}) of
               v2 ->
                   decode_v2_handoff_data(In);
               plain ->
                   In
           end,
    {{Bucket, {Metric, _T0}}, ValList} = binary_to_term(Data),
    true = is_binary(Bucket),
    true = is_binary(Metric),
    State1 = lists:foldl(fun ({T, Bin}, StateAcc) ->
                                 do_put(Bucket, Metric, T, Bin, StateAcc)
                         end, State, ValList),
    {reply, ok, State1}.

encode_handoff_item(Key, Value) ->
    case riak_core_capability:get({ddb, handoff}) of
        v2 ->
            {ok, R} = snappiest:compress(term_to_binary({Key, Value})),
            <<02:16, R/binary>>;
        plain ->
            term_to_binary({Key, Value})
    end.

is_empty(State = #state{cache = C, io = IO}) ->
    case mcache:is_empty(C) andalso metric_io:empty(IO) of
        true ->
            {true, State};
        false ->
            Count = metric_io:count(IO),
            {false, {Count, objects}, State}
    end.

delete(State = #state{io = IO, partition = P}) ->
    lager:warning("[metric:~p] deleting vnode.", [P]),
    ok = metric_io:delete(IO),
    %% We're sneaky, we let the Gc take care of deleting our cache
    %% muhaha!
    {ok, State#state{ cache = new_cache()}}.

handle_coverage({metrics, Bucket}, _KS, Sender, State = #state{io = IO}) ->
    AsyncWork = fun() ->
                        {ok, Ms} = metric_io:metrics(IO, Bucket),
                        Ms
                end,
    FinishFun = fun(Data) ->
                        reply(Data, Sender, State)
                end,
    {async, {fold, AsyncWork, FinishFun}, Sender, State};

handle_coverage({metrics, Bucket, Prefix}, _KS, Sender,
                State = #state{io = IO}) ->
    AsyncWork = fun() ->
                        {ok, Ms} = metric_io:metrics(IO, Bucket, Prefix),
                        Ms
                end,
    FinishFun = fun(Data) ->
                        reply(Data, Sender, State)
                end,
    {async, {fold, AsyncWork, FinishFun}, Sender, State};

handle_coverage(list, _KS, Sender, State = #state{io = IO}) ->
    AsyncWork = fun() ->
                        {ok, Bs} = metric_io:buckets(IO),
                        Bs
                end,
    FinishFun = fun(Data) ->
                        reply(Data, Sender, State)
                end,
    {async, {fold, AsyncWork, FinishFun}, Sender, State};

handle_coverage({update_ttl, Bucket}, _KeySpaces, _Sender,
                State = #state{partition=P, node=N,
                               bucket_info = BktInfo}) ->
    BktInfo1 = btrie:erase(Bucket, BktInfo),
    R = btrie:new(),
    R1 = btrie:store(Bucket, t, R),
    Reply = {ok, undefined, {P, N}, R1},
    {reply, Reply, State#state{bucket_info = BktInfo1}};

handle_coverage(update_env, _KeySpaces, _Sender,
                State = #state{partition=P, node=N, io = IO}) ->
    IO1 = metric_io:update_env(IO),
    Reply = {ok, undefined, {P, N}, btrie:new()},
    {reply, Reply, update_env(State#state{io = IO1})};

handle_coverage({delete, Bucket}, _KeySpaces, _Sender,
                State = #state{partition=P, node=N, cache = C, io = IO,
                               bucket_info = BktInfo}) ->
    mcache:remove_bucket(C, Bucket),
    _Repply = metric_io:delete(IO, Bucket),
    R = btrie:new(),
    R1 = btrie:store(Bucket, t, R),
    Reply = {ok, undefined, {P, N}, R1},
    BktInfo1 = btrie:erase(Bucket, BktInfo),
    {reply, Reply, State#state{bucket_info = BktInfo1}}.

handle_info(vacuum, State = #state{io = IO, partition = P}) ->
    lager:info("[vaccum] Starting vaccum for partition ~p.", [P]),
    {ok, Bs} = metric_io:buckets(IO),
    State1 = State#state{now = timestamp()},
    State2 =
        lists:foldl(fun (Bucket, SAcc) ->
                            case expiry(Bucket, SAcc) of
                                {infinity, SAcc1} ->
                                    SAcc1;
                                {Exp, SAcc1} ->
                                    metric_io:delete(IO, Bucket, Exp),
                                    SAcc1
                            end
                    end, State1, btrie:fetch_keys(Bs)),
    lager:info("[vaccum] Finalized vaccum for partution ~p.", [P]),
    {ok, State2};

handle_info({'EXIT', _PID, normal}, State) ->
    {ok, State};

handle_info({'EXIT', Pid, E}, State = #state{io = IO}) ->
    case metric_io:pid(IO) of
        R when R =:= Pid ->
            {stop, E, State};
        _ ->
            {ok, State}
    end;

handle_info(_, State) ->
    {ok, State}.

handle_exit(_Pid, normal, State) ->
    {ok, State};

handle_exit(Pid, E, State = #state{io = IO}) ->
    case metric_io:pid(IO) of
        R when R =:= Pid ->
            {stop, E, State};
        _ ->
            {ok, State}
    end;

handle_exit(_PID, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, #state{cache = C, io = IO}) ->
    empty_cache(C, IO),
    metric_io:close(IO),
    ok.

do_put(Bucket, Metric, Time, Value, State = #state{partition=P, cache = C})
  when is_binary(Bucket), is_binary(Metric), is_integer(Time) ->
    Len = mmath_bin:length(Value),
    %% Technically, we could still write data that falls within a range that is
    %% to be deleted by the vacuum.  See the `timestamp()' function doc.
    {Info = #{hpts := BktHPTS}, State1} = get_bucket_info(Bucket, State),
    case valid_ts(Time + Len, Info, State1) of
        {false, Exp, State2} ->
            lager:warning("[~p:~p] Trying to write beyond TTL: ~p + ~p < ~p",
                          [P, Bucket, Time, Len, Exp]),
            State2;
        {true, _, State2} ->
            R = case BktHPTS of
                    true ->
                        mcache:insert_hpts(C, Bucket, Metric, Time, Value);
                    false ->
                        mcache:insert(C, Bucket, Metric, Time, Value)
                end,
            case R of
                ok ->
                    ok;
                {overflow, {OfBucket, OfMetric}, Overflow} ->
                    write_chunks(State2#state.io, OfBucket, OfMetric, Overflow)
            end,
            State2
    end.


reply(Reply, {_, ReqID, _} = Sender, #state{node=N, partition=P}) ->
    riak_core_vnode:reply(Sender, {ok, ReqID, {P, N}, Reply}).

%% The timestamp is primarily used by the vacuum to remove data in accordance
%% with the bucket lifetime. The timestamp is only updated once per
%% vacuum cycle, and may not accurately reflect the current system time.
%% Although more performant than the monotonic `now()', there are nevertheless
%% performance penalties for calling this too frequently. Also, updating the
%% time on a self tick message may prevent the VNode being marked as idle by
%% riak core.
timestamp() ->
    erlang:system_time(milli_seconds).


valid_ts(TS, Bucket, State) ->
    case expiry(Bucket, State) of
        %% TODO:
        %% We ignore every data where the last point is older then the
        %% lifetime this means we could still potentially write in the
        %% past if writing batches but this is a problem for another day!
        {Exp, State1} when is_integer(Exp),
                           TS < Exp ->
            {false, Exp, State1};
        {Exp, State1} ->
            {true, Exp, State1}
    end.

%% Return the latest point we'd ever want to save. This is more strict
%% then the expiration we do on the data but it is strong enough for
%% our guarantee.
expiry(Bucket, State) when is_binary(Bucket) ->
    {Info, State1} = get_bucket_info(Bucket, State),
    expiry(Info, State1);
expiry(#{ttl := infinity}, State) ->
    {infinity, State};
expiry(#{ttl := LT, resolution := Res}, State = #state{now=Now}) ->
    Exp = (Now - LT) div Res,
    {Exp, State}.

get_bucket_info(Bucket, State = #state{bucket_info = BktInfo}) ->
    case btrie:find(Bucket, BktInfo) of
        {ok, Info} ->
            {Info, State};
        error ->
            metric_io:inform(State#state.io, Bucket),
            {ok, Info} = dalmatiner_bucket:info(Bucket),
            Info1 = case Info of
                        #{ttl := infinity} ->
                            Info;
                        #{resolution := Res, ttl := TTL} ->
                            Info#{ttl := TTL * Res}
                    end,
            BktInfo1 = btrie:store(Bucket, Info1, BktInfo),
            {Info1, State#state{bucket_info = BktInfo1}}
    end.

update_env(State) ->
    State.

%% Handling a get request overload
handle_overload_command({get, ReqID, _Bucket, _Metric, {_Time, _Count}},
                        Sender, Idx) ->
    ddb_counter:inc({<<"drop">>, <<"read">>}),
    riak_core_vnode:reply(Sender, {fail, ReqID, Idx, overload});

%% Handling write failures
handle_overload_command({put, _Bucket, _Metric, {_Time, _Value}},
                        {raw, ReqID, _PID} = Sender, Idx) ->
    ddb_counter:inc({<<"drop">>, <<"write">>}),
    riak_core_vnode:reply(Sender, {fail, ReqID, Idx, overload});
handle_overload_command({mput, _Data},
                        {raw, ReqID, _PID} = Sender, Idx) ->
    ddb_counter:inc({<<"drop">>, <<"write">>}),
    riak_core_vnode:reply(Sender, {fail, ReqID, Idx, overload});
handle_overload_command(_, {raw, ReqID, _PID} = Sender, Idx) ->
    ddb_counter:inc({<<"overflow">>, <<"other">>}),
    riak_core_vnode:reply(Sender, {fail, ReqID, Idx, overload});

%% Handling other failures
handle_overload_command(_Req, Sender, Idx) ->
    ddb_counter:inc({<<"overflow">>, <<"other">>}),
    riak_core_vnode:reply(Sender, {fail, Idx, overload}).

handle_overload_info(_, _Idx) ->
    ok.

%%%===================================================================
%%% Resize functions
%%%===================================================================

nval_map(Ring) ->
    riak_core_bucket:bucket_nval_map(Ring).

%% callback used by dynamic ring sizing to determine where requests should be
%% forwarded.

%% Puts/deletes are forwarded during the operation, all other requests are not

%% We do use the sniffle_prefix to define bucket as the bucket in read/write
%% does equal the system.
request_hash({put, Bucket, Metric, {Time, _Value}}) ->
    PPF = dalmatiner_opt:ppf(Bucket),
    riak_core_util:chash_key({Bucket, {Metric, Time div PPF}});

request_hash(_) ->
    undefined.

object_info({Bucket, {Metric, Time}}) ->
    PPF = dalmatiner_opt:ppf(Bucket),
    Hash = riak_core_util:chash_key({Bucket, {Metric, Time div PPF}}),
    {Bucket, Hash}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% We calculate the jitter (end) for a cache by reducing it to (at maximum)
%% half the size.

write_chunks(_IO, _Bucket, _Metric, []) ->
    ok;

write_chunks(IO, Bucket, Metric, [{T, V} | R]) ->
    metric_io:write(IO, Bucket, Metric, T, V),
    write_chunks(IO, Bucket, Metric, R).

%% We're completely before the data
get_overlap(Time, Count, DataSize, [{CT, CD} | R])
  when CT + (byte_size(CD) div DataSize)  < Time ->
    get_overlap(Time, Count, DataSize, R);

%% We're completely behind the data to read so we
%% can stop and say we got nothing
get_overlap(Time, Count, _DataSize, [{CT, _CD} | _R])
  when CT > Time + Count ->
    undefined;
%% We overlap but data is spread over two chunks ...
%% damn inconsistant writes ...
get_overlap(Time, Count, DataSize, [{CT, CD}, {CT1, CD1} | R])
  when  Time >= CT, CT1 =< Time + Count ->
    %% We fuse then with NULLs and continue
    %% missing bits
    %% We need to multiply the times by the DataSize
    %% to get byte then multiply
    MissingByte = (CT1 * DataSize - (CT * DataSize + byte_size(CD))),
    %% the whole by 8 to get bit to get the bits
    MissingBit = MissingByte * 8,
    Data1 = <<CD/binary, 0:MissingBit, CD1/binary>>,
    get_overlap(Time, Count, DataSize, [{CT, Data1} | R]);
get_overlap(Time, Count, DataSize, [{CT, CD} | _R]) ->
    %% If Time < CT we skip 0, if Time > CT our
    %% request begins inside the chunk so we need
    %% to skip.
    Skip = max(Time - CT, 0) * DataSize,
    %% Drop the skip
    <<_:Skip/binary, Rest/binary>> = CD,
    %% See how many bytes we can get either the rest of
    %% count or the maximum lengt of our buffer
    Take = min((Time + Count - CT) * DataSize, byte_size(Rest)),
    <<Bin:Take/binary, _/binary>> = Rest,
    Start = max(Time, CT),
    {ok, Start, Bin};

get_overlap(_Time, _Count, _DAtaSize, []) ->
    undefined.

empty_cache(C, IO) ->
    case mcache:pop(C) of
        undefined ->
            ok;
        {ok, {Bucket, Metric} , Data} ->
            write_chunks(IO, Bucket, Metric, Data),
            empty_cache(C, IO)
    end.

new_cache() ->
    CacheSize = application:get_env(metric_vnode, cache_size, 1024*1024*10),
    Buckets = application:get_env(metric_vnode, cache_buckets, 128),
    AgeCycle = application:get_env(metric_vnode, cache_age_cycle, 1000000),
    Gap = application:get_env(metric_vnode, cache_max_gap, 10),
    InitEntries = application:get_env(metric_vnode, cache_initial_entries, 10),
    InitData = application:get_env(metric_vnode, cache_initial_data, 10),
    EvictionTarget = application:get_env(
                       metric_vnode, eviction_scan_target, 0.1),
    mcache:new(CacheSize,
               [
                {initial_data_size, InitData},
                {initial_entries, InitEntries},
                {buckets, Buckets},
                {max_gap, Gap},
                {age_cycle, AgeCycle},
                {eviction_target, EvictionTarget}
               ]).

-ifdef(TEST).
overlap_test() ->
    Time = 1497181112,
    Count = 1200,
    D1 = << <<$1>> || _ <- lists:seq(1, 3608) >>,
    D2 = << <<$2>> || _ <- lists:seq(1, 2520) >>,
    Data = [{1497181501, D1}, {1497181995, D2}],
    DataSize = ?DATA_SIZE,
    {ok, TOut, DOut} = get_overlap(Time, Count, DataSize, Data),
    ?assert(byte_size(DOut) =< Count * DataSize),
    ?assert(Time =< TOut),
    ok.

overlap_end_test() ->
    Time = 1498484790,
    Count = 21600,
    D1 = << <<$1:64>> || _ <- lists:seq(1, 300) >>, % more then 240
    Data = [{1498484790 + 21360, D1}],
    {ok, TOut, DOut} = get_overlap(Time, Count, ?DATA_SIZE, Data),
    DataSize = ?DATA_SIZE,
    RCount = byte_size(DOut) div DataSize,
    ?assertEqual(Time - TOut + 21600, 240),
    ?assertEqual(240, RCount),
    ?assertEqual(Time + Count, TOut + RCount),
    ?assert((Time - TOut) *DataSize + byte_size(DOut) =< Count * DataSize),
    ?assert(Time =< TOut),
    ok.

-endif.

%% {_, {_, _, _, {_, _, _, C, _, _, _, _}, _, _, _, _, _, _, _, _}}
%% = sys:get_state(pid(0,637,0)).
