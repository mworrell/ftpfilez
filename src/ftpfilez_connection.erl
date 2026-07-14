%% @doc Owner process for a single persistent FTP connection.
%% @private
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

-module(ftpfilez_connection).

-behaviour(gen_server).

-define(DEFAULT_CLOSE_TIMEOUT_MS, 5000).
-define(KILL_WAIT_TIMEOUT_MS, 1000).

-export([
    start/1,
    close_connection/1
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
-export([same_transport/2]).
-endif.

-record(state, {
    pool :: pid(),
    pool_monitor :: reference(),
    ftp_pid = undefined :: undefined | pid(),
    base_directory = undefined :: undefined | string(),
    key = undefined :: undefined | map()
}).

-spec start(pid()) -> {ok, pid()} | ignore | {error, term()}.
start(PoolPid) ->
    gen_server:start(?MODULE, [PoolPid], []).

%% @doc Close the owned FTP connection. Called synchronously by the pool
%% manager after it has marked the worker as idle. An unresponsive owner is
%% killed after the configured close timeout.
-spec close_connection(pid()) -> ok | killed.
close_connection(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    try gen_server:call(Pid, close_connection, close_timeout_ms()) of
        ok ->
            erlang:demonitor(Monitor, [flush]),
            ok
    catch
        exit:_Reason ->
            exit(Pid, kill),
            wait_for_killed(Pid, Monitor),
            killed
    end.

init([PoolPid]) ->
    process_flag(trap_exit, true),
    PoolMonitor = erlang:monitor(process, PoolPid),
    {ok, #state{pool = PoolPid, pool_monitor = PoolMonitor}}.

handle_call(close_connection, _From, State) ->
    {reply, ok, close(State)};
handle_call(Msg, _From, State) ->
    {reply, {error, {unknown_call, Msg}}, State}.

handle_cast({run, Ref, Cfg, Fun}, #state{pool = PoolPid} = State) ->
    {Result, State1} = run(Cfg, Fun, State),
    PoolPid ! {
        ftpfilez_connection,
        self(),
        Ref,
        Result,
        State1#state.key
    },
    {noreply, State1};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', FtpPid, _Reason}, #state{ftp_pid = FtpPid, pool = PoolPid} = State) ->
    PoolPid ! {ftpfilez_connection_down, self()},
    {noreply, disconnected(State)};
handle_info({'DOWN', Monitor, process, PoolPid, Reason},
        #state{pool = PoolPid, pool_monitor = Monitor} = State) ->
    {stop, Reason, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    close(State),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

-spec run(map(), fun((pid()) -> term()), #state{}) -> {term(), #state{}}.
run(Cfg, Fun, State) ->
    case ensure_connection(Cfg, State) of
        {ok, #state{ftp_pid = FtpPid} = State1} ->
            Result = call_operation(Fun, FtpPid),
            {Result, check_connection(State1)};
        {{error, _} = Error, State1} ->
            {Error, State1}
    end.

-spec ensure_connection(map(), #state{}) -> {ok, #state{}} | {{error, term()}, #state{}}.
ensure_connection(Cfg, #state{key = Cfg, ftp_pid = FtpPid, base_directory = Base} = State)
        when is_pid(FtpPid) ->
    case ftpfilez_ftps:prepare(FtpPid, Base) of
        ok ->
            {ok, State};
        {error, _} ->
            connect(Cfg, close(State))
    end;
ensure_connection(Cfg, #state{key = OldCfg, ftp_pid = FtpPid} = State)
        when is_map(OldCfg), is_pid(FtpPid) ->
    case same_transport(OldCfg, Cfg) of
        true ->
            case ftpfilez_ftps:reauthenticate(FtpPid, Cfg) of
                {ok, BaseDirectory} ->
                    {ok, State#state{
                        base_directory = BaseDirectory,
                        key = Cfg
                    }};
                {error, _} ->
                    connect(Cfg, close(State))
            end;
        false ->
            connect(Cfg, close(State))
    end;
ensure_connection(Cfg, State) ->
    connect(Cfg, close(State)).

-spec connect(map(), #state{}) -> {ok, #state{}} | {{error, term()}, #state{}}.
connect(Cfg, State) ->
    case ftpfilez_ftps:connect(Cfg) of
        {ok, FtpPid, BaseDirectory} ->
            {ok, State#state{
                ftp_pid = FtpPid,
                base_directory = BaseDirectory,
                key = Cfg
            }};
        {error, _} = Error ->
            {Error, disconnected(State)}
    end.

-spec call_operation(fun((pid()) -> term()), pid()) -> term().
call_operation(Fun, FtpPid) ->
    try Fun(FtpPid) of
        Result -> Result
    catch
        Class:Reason ->
            {error, {ftp_operation_failed, {Class, Reason}}}
    end.

-spec check_connection(#state{}) -> #state{}.
check_connection(#state{ftp_pid = FtpPid} = State) ->
    case ftpfilez_ftps:healthy(FtpPid) of
        true -> State;
        false -> close(State)
    end.

-spec close(#state{}) -> #state{}.
close(#state{ftp_pid = FtpPid} = State) when is_pid(FtpPid) ->
    ftpfilez_ftps:close(FtpPid),
    disconnected(State);
close(State) ->
    disconnected(State).

-spec disconnected(#state{}) -> #state{}.
disconnected(State) ->
    State#state{ftp_pid = undefined, base_directory = undefined, key = undefined}.

-spec same_transport(map(), map()) -> boolean().
same_transport(CfgA, CfgB) ->
    transport_key(CfgA) =:= transport_key(CfgB).

-spec transport_key(map()) -> {term(), pos_integer(), boolean(), list()}.
transport_key(Cfg) ->
    Port = case maps:get(port, Cfg, 21) of
        undefined -> 21;
        P -> P
    end,
    {
        normalize_host(maps:get(host, Cfg)),
        Port,
        maps:get(tls, Cfg, true),
        maps:get(tls_options, Cfg, [])
    }.

-spec normalize_host(binary() | string()) -> binary().
normalize_host(Host) ->
    z_string:to_lower(Host).

-spec close_timeout_ms() -> pos_integer().
close_timeout_ms() ->
    case application:get_env(ftpfilez, connection_close_timeout_ms) of
        {ok, N} when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_CLOSE_TIMEOUT_MS
    end.

-spec wait_for_killed(pid(), reference()) -> ok.
wait_for_killed(Pid, Monitor) ->
    receive
        {'DOWN', Monitor, process, Pid, _Reason} ->
            ok
    after ?KILL_WAIT_TIMEOUT_MS ->
        erlang:demonitor(Monitor, [flush]),
        ok
    end.
