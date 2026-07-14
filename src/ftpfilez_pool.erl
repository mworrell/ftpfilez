%% @doc Pool of persistent FTP connections.
%%
%% Requests are queued while all workers are busy. Each worker owns at most one
%% FTP connection, as required by the OTP ftp client. Idle connections are
%% reused only for matching server credentials. Each server has its own limit;
%% the least recently used idle connection is repurposed when new credentials
%% are requested.
%% @author Marc Worrell
%% @copyright 2026 Marc Worrell
%% @end

%% Copyright 2026 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(ftpfilez_pool).

-behaviour(gen_server).

-export([
    start_link/0,
    run/2,
    status/0,
    max_connections/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ifdef(TEST).
-export([
    test_select_worker/2,
    test_server_key/1,
    test_info/0
]).
-endif.

-define(SERVER, ?MODULE).
-define(DEFAULT_MAX_CONNECTIONS, 4).
-define(MAX_CONNECTIONS, 4).
-define(DEFAULT_IDLE_TIMEOUT_MS, 5 * 60 * 1000).

-type operation() :: fun((pid()) -> term()).

-record(worker, {
    monitor :: reference(),
    status = idle :: idle | {busy, reference()},
    key = undefined :: undefined | map(),
    server = undefined :: undefined | {term(), pos_integer()},
    last_used = 0 :: integer()
}).

-record(request, {
    from :: gen_server:from(),
    caller_monitor :: reference(),
    config :: map(),
    operation :: operation()
}).

-record(call, {
    from :: gen_server:from(),
    caller_monitor :: reference()
}).

-record(state, {
    workers = #{} :: #{ pid() => #worker{} },
    waiting = queue:new() :: queue:queue(),
    calls = #{} :: #{ reference() => #call{} },
    idle_timer = undefined :: undefined | reference()
}).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Run an FTP operation on a pooled connection. Calls wait in FIFO order
%% when all connection workers are occupied.
-spec run(ftpfilez_ftps:config(), operation()) -> term().
run(Cfg, Fun) when is_function(Fun, 1) ->
    gen_server:call(?SERVER, {run, Cfg, Fun}, infinity).

%% @doc Return a sanitized snapshot of all connection workers and queued work.
-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

%% @doc Configured pool size, capped at four open connections.
-spec max_connections() -> 1..4.
max_connections() ->
    case application:get_env(ftpfilez, max_connections) of
        {ok, N} when is_integer(N), N > 0 -> min(N, ?MAX_CONNECTIONS);
        _ -> ?DEFAULT_MAX_CONNECTIONS
    end.

init([]) ->
    {ok, #state{}}.

handle_call({run, Cfg, Fun}, From, #state{waiting = Waiting} = State) ->
    CallerMonitor = erlang:monitor(process, caller_pid(From)),
    Request = #request{
        from = From,
        caller_monitor = CallerMonitor,
        config = Cfg,
        operation = Fun
    },
    State1 = State#state{waiting = queue:in(Request, Waiting)},
    {noreply, schedule_idle_timer(dispatch(State1))};
handle_call(status, _From, State) ->
    {reply, status(State), State};
handle_call(test_info, _From, State) ->
    {monitors, Monitors} = process_info(self(), monitors),
    Info = #{
        workers => maps:size(State#state.workers),
        open_connections => length([
            ok
            || {_Pid, #worker{key = Key}} <- maps:to_list(State#state.workers),
               Key =/= undefined
        ]),
        waiting => queue:len(State#state.waiting),
        calls => maps:size(State#state.calls),
        monitors => length(Monitors)
    },
    {reply, Info, State};
handle_call(Msg, _From, State) ->
    {reply, {error, {unknown_call, Msg}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({ftpfilez_connection, WorkerPid, Ref, Result, Key}, State) ->
    State1 = dispatch(finish_call(WorkerPid, Ref, Result, Key, State)),
    {noreply, schedule_idle_timer(State1)};
handle_info({ftpfilez_connection_down, WorkerPid}, #state{workers = Workers} = State) ->
    case maps:find(WorkerPid, Workers) of
        {ok, Worker} ->
            Workers1 = Workers#{ WorkerPid => Worker#worker{
                key = undefined,
                server = undefined,
                last_used = timestamp()
            } },
            {noreply, schedule_idle_timer(State#state{workers = Workers1})};
        error ->
            {noreply, State}
    end;
handle_info({timeout, Timer, close_idle_connections},
        #state{idle_timer = Timer} = State) ->
    State1 = State#state{idle_timer = undefined},
    {noreply, schedule_idle_timer(close_idle_connections(State1))};
handle_info({'DOWN', Monitor, process, Pid, Reason}, #state{workers = Workers} = State) ->
    case is_worker_monitor(Pid, Monitor, Workers) of
        true ->
            State1 = dispatch(replace_worker(Pid, Monitor, Reason, State)),
            {noreply, schedule_idle_timer(State1)};
        false ->
            {noreply, cancel_waiting(Monitor, State)}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

-spec dispatch(#state{}) -> #state{}.
dispatch(#state{waiting = Waiting} = State) ->
    Requests = queue:to_list(Waiting),
    dispatch_requests(Requests, [], State#state{waiting = queue:new()}).

-spec dispatch_requests([#request{}], [#request{}], #state{}) -> #state{}.
dispatch_requests([], Blocked, State) ->
    State#state{waiting = queue:from_list(lists:reverse(Blocked))};
dispatch_requests([
        #request{
            from = From,
            caller_monitor = CallerMonitor,
            config = Cfg,
            operation = Fun
        } = Request
        | Rest
    ], Blocked, State) ->
    case select_worker(Cfg, State) of
        {ok, WorkerPid, State1} ->
            Ref = make_ref(),
            gen_server:cast(WorkerPid, {run, Ref, Cfg, Fun}),
            Worker = maps:get(WorkerPid, State1#state.workers),
            Server = server_key(Cfg),
            Workers1 = (State1#state.workers)#{
                WorkerPid => Worker#worker{
                    status = {busy, Ref},
                    key = Cfg,
                    server = Server
                }
            },
            Call = #call{from = From, caller_monitor = CallerMonitor},
            Calls1 = (State1#state.calls)#{ Ref => Call },
            dispatch_requests(Rest, Blocked, State1#state{
                workers = Workers1,
                calls = Calls1
            });
        none ->
            dispatch_requests(Rest, [Request | Blocked], State)
    end.

-spec select_worker(map(), #state{}) -> {ok, pid(), #state{}} | none.
select_worker(Key, #state{workers = Workers} = State) ->
    Server = server_key(Key),
    IdleMatching = [
        {Pid, LastUsed}
        || {Pid, #worker{status = idle, key = WorkerKey, last_used = LastUsed}}
            <- maps:to_list(Workers),
           WorkerKey =:= Key
    ],
    case least_recently_used(IdleMatching) of
        {ok, Pid} ->
            {ok, Pid, State};
        none ->
            select_free_worker(Server, State)
    end.

-spec select_free_worker({term(), pos_integer()}, #state{}) ->
    {ok, pid(), #state{}} | none.
select_free_worker(Server, #state{workers = Workers} = State) ->
    ServerWorkers = [
        {Pid, Status, LastUsed}
        || {Pid, #worker{server = WorkerServer, status = Status, last_used = LastUsed}}
            <- maps:to_list(Workers),
           WorkerServer =:= Server
    ],
    Idle = [
        {Pid, LastUsed}
        || {Pid, idle, LastUsed} <- ServerWorkers
    ],
    HasCapacity = length(ServerWorkers) < max_connections(),
    case least_recently_used(Idle) of
        {ok, Pid} ->
            {ok, Pid, State};
        none when HasCapacity ->
            case disconnected_worker(Workers) of
                {ok, Pid} -> {ok, Pid, State};
                none ->
                    {Pid, State1} = start_worker(State),
                    {ok, Pid, State1}
            end;
        none ->
            none
    end.

-spec disconnected_worker(#{pid() => #worker{}}) -> {ok, pid()} | none.
disconnected_worker(Workers) ->
    Idle = [
        {Pid, LastUsed}
        || {Pid, #worker{status = idle, server = undefined, last_used = LastUsed}}
            <- maps:to_list(Workers)
    ],
    least_recently_used(Idle).

-spec least_recently_used([{pid(), integer()}]) -> {ok, pid()} | none.
least_recently_used([]) ->
    none;
least_recently_used([Worker | Rest]) ->
    {Pid, _LastUsed} = lists:foldl(
        fun({_Pid, Used} = Candidate, {_AccPid, AccUsed}) when Used < AccUsed ->
                Candidate;
           (_Candidate, Acc) ->
                Acc
        end,
        Worker,
        Rest),
    {ok, Pid}.

-spec finish_call(pid(), reference(), term(), undefined | map(), #state{}) -> #state{}.
finish_call(WorkerPid, Ref, Result, Key, #state{workers = Workers, calls = Calls} = State) ->
    case {maps:find(WorkerPid, Workers), maps:take(Ref, Calls)} of
        {{ok, #worker{status = {busy, Ref}} = Worker}, {Call, Calls1}} ->
            reply(Call, Result),
            Server = case Key of
                undefined -> undefined;
                _ -> server_key(Key)
            end,
            Workers1 = Workers#{ WorkerPid => Worker#worker{
                status = idle,
                key = Key,
                server = Server,
                last_used = timestamp()
            } },
            State#state{workers = Workers1, calls = Calls1};
        _ ->
            State
    end.

-spec replace_worker(pid(), reference(), term(), #state{}) -> #state{}.
replace_worker(WorkerPid, Monitor, Reason, #state{workers = Workers, calls = Calls} = State) ->
    case maps:find(WorkerPid, Workers) of
        {ok, #worker{monitor = Monitor, status = Status}} ->
            {Calls1, Reply} = take_worker_call(Status, Calls),
            maybe_reply_worker_down(Reply, Reason),
            State#state{workers = maps:remove(WorkerPid, Workers), calls = Calls1};
        _ ->
            State
    end.

-spec take_worker_call(idle | {busy, reference()}, map()) -> {map(), none | #call{}}.
take_worker_call(idle, Calls) ->
    {Calls, none};
take_worker_call({busy, Ref}, Calls) ->
    case maps:take(Ref, Calls) of
        {Call, Calls1} -> {Calls1, Call};
        error -> {Calls, none}
    end.

-spec maybe_reply_worker_down(none | #call{}, term()) -> ok.
maybe_reply_worker_down(none, _Reason) ->
    ok;
maybe_reply_worker_down(Call, Reason) ->
    reply(Call, {error, {connection_worker_down, Reason}}).

-spec reply(#call{}, term()) -> ok.
reply(#call{from = From, caller_monitor = Monitor}, Result) ->
    erlang:demonitor(Monitor, [flush]),
    gen_server:reply(From, Result).

-spec is_worker_monitor(pid(), reference(), #{pid() => #worker{}}) -> boolean().
is_worker_monitor(Pid, Monitor, Workers) ->
    case maps:find(Pid, Workers) of
        {ok, #worker{monitor = Monitor}} -> true;
        _ -> false
    end.

-spec cancel_waiting(reference(), #state{}) -> #state{}.
cancel_waiting(Monitor, #state{waiting = Waiting} = State) ->
    Requests = queue:to_list(Waiting),
    Remaining = [
        Request
        || #request{caller_monitor = RequestMonitor} = Request <- Requests,
           RequestMonitor =/= Monitor
    ],
    erlang:demonitor(Monitor, [flush]),
    State#state{waiting = queue:from_list(Remaining)}.

-spec caller_pid(gen_server:from()) -> pid().
caller_pid({Pid, _Tag}) ->
    Pid.

-spec start_worker(#state{}) -> {pid(), #state{}}.
start_worker(#state{workers = Workers} = State) ->
    {ok, WorkerPid} = ftpfilez_connection:start(self()),
    Monitor = erlang:monitor(process, WorkerPid),
    Worker = #worker{monitor = Monitor, last_used = timestamp()},
    {WorkerPid, State#state{workers = Workers#{ WorkerPid => Worker }}}.

-spec server_key(map()) -> {term(), pos_integer()}.
server_key(Cfg) ->
    Port = case maps:get(port, Cfg, 21) of
        undefined -> 21;
        P -> P
    end,
    {normalize_host(maps:get(host, Cfg)), Port}.

-spec normalize_host(binary() | string()) -> binary().
normalize_host(Host) ->
    z_string:to_lower(Host).

-spec timestamp() -> integer().
timestamp() ->
    erlang:monotonic_time(millisecond).

-spec schedule_idle_timer(#state{}) -> #state{}.
schedule_idle_timer(#state{idle_timer = OldTimer, workers = Workers} = State) ->
    cancel_idle_timer(OldTimer),
    Timeout = idle_timeout_ms(),
    case next_idle_deadline(Workers, Timeout) of
        none ->
            State#state{idle_timer = undefined};
        {ok, Deadline} ->
            Delay = max(0, Deadline - timestamp()),
            Timer = erlang:start_timer(Delay, self(), close_idle_connections),
            State#state{idle_timer = Timer}
    end.

-spec cancel_idle_timer(undefined | reference()) -> ok.
cancel_idle_timer(undefined) ->
    ok;
cancel_idle_timer(Timer) ->
    erlang:cancel_timer(Timer),
    ok.

-spec next_idle_deadline(#{pid() => #worker{}}, pos_integer()) ->
    none | {ok, integer()}.
next_idle_deadline(Workers, Timeout) ->
    Deadlines = [
        LastUsed + Timeout
        || {_Pid, #worker{
                status = idle,
                key = Key,
                last_used = LastUsed
            }} <- maps:to_list(Workers),
           Key =/= undefined
    ],
    case Deadlines of
        [] -> none;
        _ -> {ok, lists:min(Deadlines)}
    end.

-spec close_idle_connections(#state{}) -> #state{}.
close_idle_connections(#state{workers = Workers} = State) ->
    Now = timestamp(),
    Timeout = idle_timeout_ms(),
    Workers1 = maps:fold(
        fun(Pid, Worker, Acc) ->
            close_idle_connection(Pid, Worker, Now, Timeout, Acc)
        end,
        Workers,
        Workers),
    State#state{workers = Workers1}.

-spec close_idle_connection(pid(), #worker{}, integer(), pos_integer(),
    #{pid() => #worker{}}) -> #{pid() => #worker{}}.
close_idle_connection(Pid,
        #worker{status = idle, key = Key, last_used = LastUsed} = Worker,
        Now,
        Timeout,
        Workers)
        when Key =/= undefined, Now - LastUsed >= Timeout ->
    try ftpfilez_connection:close_connection(Pid) of
        ok ->
            Workers#{Pid => Worker#worker{
                key = undefined,
                server = undefined,
                last_used = Now
            }};
        killed ->
            erlang:demonitor(Worker#worker.monitor, [flush]),
            maps:remove(Pid, Workers)
    catch
        exit:_Reason ->
            kill_worker(Pid, Worker#worker.monitor),
            maps:remove(Pid, Workers)
    end;
close_idle_connection(_Pid, _Worker, _Now, _Timeout, Workers) ->
    Workers.

-spec kill_worker(pid(), reference()) -> ok.
kill_worker(Pid, Monitor) ->
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 1000 ->
        erlang:demonitor(Monitor, [flush]),
        ok
    end.

-spec idle_timeout_ms() -> pos_integer().
idle_timeout_ms() ->
    case application:get_env(ftpfilez, connection_idle_timeout_ms) of
        {ok, N} when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_IDLE_TIMEOUT_MS
    end.

-spec status(#state{}) -> map().
status(#state{workers = Workers, waiting = Waiting, calls = Calls}) ->
    Connections = lists:sort([
        connection_status(Pid, Worker)
        || {Pid, Worker} <- maps:to_list(Workers)
    ]),
    #{
        connections => Connections,
        waiting_requests => queue:len(Waiting),
        in_flight_requests => maps:size(Calls)
    }.

-spec connection_status(pid(), #worker{}) -> map().
connection_status(Pid, #worker{status = idle, key = undefined}) ->
    #{pid => Pid, state => disconnected};
connection_status(Pid, #worker{status = idle, key = Config, last_used = LastUsed}) ->
    (connection_details(Pid, idle, Config))#{
        idle_ms => max(0, timestamp() - LastUsed)
    };
connection_status(Pid, #worker{status = {busy, _Ref}, key = Config}) ->
    connection_details(Pid, busy, Config).

-spec connection_details(pid(), idle | busy, map()) -> map().
connection_details(Pid, State, Config) ->
    #{
        pid => Pid,
        state => State,
        host => normalize_host(maps:get(host, Config)),
        port => connection_port(Config),
        username => to_binary(maps:get(username, Config, <<"anonymous">>)),
        tls => maps:get(tls, Config, true)
    }.

-spec connection_port(map()) -> pos_integer().
connection_port(Config) ->
    case maps:get(port, Config, 21) of
        undefined -> 21;
        Port -> Port
    end.

-spec to_binary(binary() | string()) -> binary().
to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) -> unicode:characters_to_binary(Value).

-ifdef(TEST).

-spec test_info() -> map().
test_info() ->
    gen_server:call(?SERVER, test_info).

-spec test_select_worker(map(), [map()]) -> {ok, pid()} | none.
test_select_worker(Cfg, WorkerSpecs) ->
    Workers = maps:from_list([test_worker(Spec) || Spec <- WorkerSpecs]),
    case select_worker(Cfg, #state{workers = Workers}) of
        {ok, Pid, _State} -> {ok, Pid};
        none -> none
    end.

-spec test_server_key(map()) -> {term(), pos_integer()}.
test_server_key(Cfg) ->
    server_key(Cfg).

test_worker(#{pid := Pid} = Spec) ->
    Key = maps:get(key, Spec, undefined),
    Server = maps:get(server, Spec, test_worker_server(Key)),
    Worker = #worker{
        monitor = make_ref(),
        status = maps:get(status, Spec, idle),
        key = Key,
        server = Server,
        last_used = maps:get(last_used, Spec, 0)
    },
    {Pid, Worker}.

test_worker_server(undefined) -> undefined;
test_worker_server(Key) -> server_key(Key).
-endif.
