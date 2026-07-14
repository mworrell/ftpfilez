-module(ftpfilez_e2e_tests).

-include_lib("eunit/include/eunit.hrl").

e2e_test_() ->
    {foreach,
        fun setup/0,
        fun cleanup/1,
        [
            test_case(fun reuses_connection_for_file_operations/1),
            test_case(fun switches_username_without_reconnecting/1),
            test_case(fun reconnects_after_unexpected_close/1),
            test_case(fun closes_connection_after_idle_timeout/1),
            test_case(fun queues_at_four_connections_per_server/1),
            test_case(fun removes_queued_request_when_caller_stops/1),
            test_case(fun returns_connect_error/1)
        ]}.

test_case(Fun) ->
    fun(Ctx) ->
        fun() -> Fun(Ctx) end
    end.

setup() ->
    MaxConnections = application:get_env(ftpfilez, max_connections),
    Backoff = application:get_env(ftpfilez, connect_error_backoff_ms),
    IdleTimeout = application:get_env(ftpfilez, connection_idle_timeout_ms),
    application:set_env(ftpfilez, max_connections, 4),
    application:set_env(ftpfilez, connect_error_backoff_ms, 0),
    {ok, Server} = ftpfilez_test_ftp_server:start_link(),
    unlink(Server),
    {ok, _} = application:ensure_all_started(ftp),
    StartedSupervisor = start_supervisor(),
    #{
        server => Server,
        port => ftpfilez_test_ftp_server:port(Server),
        started_supervisor => StartedSupervisor,
        max_connections => MaxConnections,
        backoff => Backoff,
        idle_timeout => IdleTimeout
    }.

cleanup(#{server := Server} = Ctx) ->
    stop_supervisor(maps:get(started_supervisor, Ctx)),
    ftpfilez_test_ftp_server:stop(Server),
    restore_env(max_connections, maps:get(max_connections, Ctx)),
    restore_env(connect_error_backoff_ms, maps:get(backoff, Ctx)),
    restore_env(connection_idle_timeout_ms, maps:get(idle_timeout, Ctx)),
    ok.

reuses_connection_for_file_operations(Ctx) ->
    Config = config(<<"alice">>),
    Url = url(Ctx, <<"file.txt">>),
    Data = <<"persistent connection">>,
    ?assertEqual(ok, ftpfilez:put(Config, Url, {data, Data})),
    ?assertEqual(
        {ok, <<"application/octet-stream">>, Data},
        ftpfilez:get(Config, Url)),
    ?assertEqual(ok, ftpfilez:delete(Config, Url)),
    ?assertEqual({error, enoent}, ftpfilez:get(Config, Url)),
    Stats = stats(Ctx),
    ?assertEqual(1, maps:get(total_connections, Stats)),
    Status = ftpfilez:status(),
    ?assertEqual(0, maps:get(waiting_requests, Status)),
    ?assertEqual(0, maps:get(in_flight_requests, Status)),
    [Connection] = connections_for_port(Ctx, Status),
    ?assertEqual(idle, maps:get(state, Connection)),
    ?assertEqual(<<"127.0.0.1">>, maps:get(host, Connection)),
    ?assertEqual(<<"alice">>, maps:get(username, Connection)),
    ?assertEqual(false, maps:get(tls, Connection)),
    ?assertNot(maps:is_key(password, Connection)).

switches_username_without_reconnecting(Ctx) ->
    Alice = config(<<"alice">>),
    Bob = config(<<"bob">>),
    Url = url(Ctx, <<"shared.txt">>),
    Data = <<"shared data">>,
    ?assertEqual(ok, ftpfilez:put(Alice, Url, {data, Data})),
    ?assertEqual(
        {ok, <<"application/octet-stream">>, Data},
        ftpfilez:get(Bob, Url)),
    Stats = stats(Ctx),
    ?assertEqual(1, maps:get(total_connections, Stats)),
    ?assertEqual(
        [<<"alice">>, <<"bob">>],
        maps:get(authentications, Stats)).

reconnects_after_unexpected_close(Ctx) ->
    Config = config(<<"alice">>),
    Url = url(Ctx, <<"reconnect.txt">>),
    Data = <<"reconnect data">>,
    ?assertEqual(ok, ftpfilez:put(Config, Url, {data, Data})),
    ok = ftpfilez_test_ftp_server:close_connections(maps:get(server, Ctx)),
    ok = wait_until(fun() -> maps:get(connections, stats(Ctx)) =:= 0 end, 1000),
    ?assertEqual(
        {ok, <<"application/octet-stream">>, Data},
        ftpfilez:get(Config, Url)),
    ?assertEqual(2, maps:get(total_connections, stats(Ctx))).

closes_connection_after_idle_timeout(Ctx) ->
    application:set_env(ftpfilez, connection_idle_timeout_ms, 50),
    Config = config(<<"alice">>),
    Url = url(Ctx, <<"idle.txt">>),
    Data = <<"idle timeout data">>,
    ?assertEqual(ok, ftpfilez:put(Config, Url, {data, Data})),
    ?assertEqual(1, maps:get(connections, stats(Ctx))),
    ok = wait_until(fun() ->
        PoolInfo = ftpfilez_pool:test_info(),
        maps:get(connections, stats(Ctx)) =:= 0
            andalso maps:get(open_connections, PoolInfo) =:= 0
    end, 1000),
    ?assertEqual(
        {ok, <<"application/octet-stream">>, Data},
        ftpfilez:get(Config, Url)),
    ?assertEqual(2, maps:get(total_connections, stats(Ctx))).

queues_at_four_connections_per_server(Ctx) ->
    Config = config(<<"alice">>),
    Url = url(Ctx, <<"queue.txt">>),
    Data = <<"queued data">>,
    Server = maps:get(server, Ctx),
    ?assertEqual(ok, ftpfilez:put(Config, Url, {data, Data})),
    ok = ftpfilez_test_ftp_server:set_transfer_delay(Server, 600),
    Parent = self(),
    Workers = [
        spawn(fun() ->
            receive
                start -> Parent ! {self(), ftpfilez:get(Config, Url)}
            end
        end)
        || _ <- lists:seq(1, 5)
    ],
    [Pid ! start || Pid <- Workers],
    ok = wait_until(fun() ->
        maps:get(active_transfers, stats(Ctx)) =:= 4
    end, 2000),
    InFlight = stats(Ctx),
    ?assertEqual(4, maps:get(connections, InFlight)),
    Results = receive_results(Workers, []),
    Expected = {ok, <<"application/octet-stream">>, Data},
    ?assert(lists:all(fun(Result) -> Result =:= Expected end, Results)),
    Final = stats(Ctx),
    ?assertEqual(4, maps:get(max_connections, Final)),
    ?assertEqual(4, maps:get(max_active_transfers, Final)).

removes_queued_request_when_caller_stops(Ctx) ->
    Config = config(<<"alice">>),
    Url = url(Ctx, <<"cancel.txt">>),
    Data = <<"canceled queue data">>,
    Server = maps:get(server, Ctx),
    ?assertEqual(ok, ftpfilez:put(Config, Url, {data, Data})),
    ok = ftpfilez_test_ftp_server:set_transfer_delay(Server, 600),
    Workers = start_gets(4, Config, Url),
    ok = wait_until(fun() ->
        maps:get(active_transfers, stats(Ctx)) =:= 4
    end, 2000),
    Parent = self(),
    QueuedPid = spawn(fun() ->
        Parent ! {queued, self()},
        Result = ftpfilez:get(Config, Url),
        Parent ! {self(), Result}
    end),
    receive
        {queued, QueuedPid} -> ok
    after 1000 ->
        error(queued_caller_start_timeout)
    end,
    ok = wait_until(fun() ->
        maps:get(waiting, ftpfilez_pool:test_info()) =:= 1
    end, 1000),
    PublicStatus = ftpfilez:status(),
    ?assertEqual(1, maps:get(waiting_requests, PublicStatus)),
    ?assertEqual(4, maps:get(in_flight_requests, PublicStatus)),
    ?assertEqual(4, length(connections_for_port(Ctx, PublicStatus))),
    Queued = ftpfilez_pool:test_info(),
    ?assertEqual(
        maps:get(workers, Queued) + maps:get(calls, Queued) + maps:get(waiting, Queued),
        maps:get(monitors, Queued)),
    QueuedMonitor = erlang:monitor(process, QueuedPid),
    exit(QueuedPid, kill),
    receive
        {'DOWN', QueuedMonitor, process, QueuedPid, killed} -> ok
    after 1000 ->
        error(queued_caller_stop_timeout)
    end,
    ok = wait_until(fun() ->
        maps:get(waiting, ftpfilez_pool:test_info()) =:= 0
    end, 1000),
    Canceled = ftpfilez_pool:test_info(),
    ?assertEqual(
        maps:get(workers, Canceled) + maps:get(calls, Canceled),
        maps:get(monitors, Canceled)),
    Results = receive_results(Workers, []),
    Expected = {ok, <<"application/octet-stream">>, Data},
    ?assert(lists:all(fun(Result) -> Result =:= Expected end, Results)),
    ok = wait_until(fun() ->
        maps:get(calls, ftpfilez_pool:test_info()) =:= 0
    end, 1000),
    Finished = ftpfilez_pool:test_info(),
    ?assertEqual(maps:get(workers, Finished), maps:get(monitors, Finished)),
    ?assertEqual(5, maps:get(total_transfers, stats(Ctx))).

returns_connect_error(Ctx) ->
    Server = maps:get(server, Ctx),
    ok = ftpfilez_test_ftp_server:stop(Server),
    Config = config(<<"alice">>),
    ?assertMatch({error, _}, ftpfilez:get(Config, url(Ctx, <<"missing.txt">>))).

receive_results([], Results) ->
    Results;
receive_results([Pid | Rest], Results) ->
    receive
        {Pid, Result} -> receive_results(Rest, [Result | Results])
    after 5000 ->
        error({timeout, Pid})
    end.

start_gets(Count, Config, Url) ->
    Parent = self(),
    Workers = [
        spawn(fun() ->
            receive
                start -> Parent ! {self(), ftpfilez:get(Config, Url)}
            end
        end)
        || _ <- lists:seq(1, Count)
    ],
    [Pid ! start || Pid <- Workers],
    Workers.

wait_until(Fun, Timeout) when Timeout =< 0 ->
    case Fun() of
        true -> ok;
        false -> {error, timeout}
    end;
wait_until(Fun, Timeout) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(10),
            wait_until(Fun, Timeout - 10)
    end.

config(Username) ->
    #{
        username => Username,
        password => <<"secret">>,
        tls => false
    }.

url(#{port := Port}, Filename) ->
    iolist_to_binary(io_lib:format(
        "ftp://127.0.0.1:~B/~s",
        [Port, Filename])).

stats(#{server := Server}) ->
    ftpfilez_test_ftp_server:stats(Server).

connections_for_port(#{port := Port}, Status) ->
    [
        Connection
        || #{port := ConnectionPort} = Connection <- maps:get(connections, Status),
           ConnectionPort =:= Port
    ].

start_supervisor() ->
    case whereis(ftpfilez_pool) of
        undefined ->
            {ok, Supervisor} = ftpfilez_sup:start_link(),
            unlink(Supervisor),
            Supervisor;
        _Pid ->
            undefined
    end.

stop_supervisor(undefined) ->
    ok;
stop_supervisor(Supervisor) ->
    Monitor = erlang:monitor(process, Supervisor),
    exit(Supervisor, shutdown),
    receive
        {'DOWN', Monitor, process, Supervisor, _Reason} -> ok
    after 1000 ->
        erlang:demonitor(Monitor, [flush]),
        error(supervisor_stop_timeout)
    end.

restore_env(Key, undefined) ->
    application:unset_env(ftpfilez, Key);
restore_env(Key, {ok, Value}) ->
    application:set_env(ftpfilez, Key, Value).
