-module(ftpfilez_pool_tests).

-include_lib("eunit/include/eunit.hrl").

matches_username_test() ->
    [AlicePid, BobPid] = workers(2),
    try
        Alice = config(<<"ftp.example.com">>, <<"alice">>),
        Bob = config(<<"ftp.example.com">>, <<"bob">>),
        WorkerSpecs = [
            worker(AlicePid, Alice, 1),
            worker(BobPid, Bob, 2)
        ],
        ?assertEqual({ok, BobPid}, ftpfilez_pool:test_select_worker(Bob, WorkerSpecs))
    after
        stop_workers([AlicePid, BobPid])
    end.

reuses_oldest_idle_for_new_username_test() ->
    [OldPid, NewPid] = workers(2),
    try
        Alice = config(<<"ftp.example.com">>, <<"alice">>),
        Bob = config(<<"ftp.example.com">>, <<"bob">>),
        Carol = config(<<"ftp.example.com">>, <<"carol">>),
        WorkerSpecs = [
            worker(OldPid, Alice, 1),
            worker(NewPid, Bob, 2)
        ],
        ?assertEqual({ok, OldPid}, ftpfilez_pool:test_select_worker(Carol, WorkerSpecs))
    after
        stop_workers([OldPid, NewPid])
    end.

limits_busy_connections_per_server_test() ->
    Pids = workers(5),
    try
        [P1, P2, P3, P4, DisconnectedPid] = Pids,
        Cfg = config(<<"ftp.example.com">>, <<"alice">>),
        OtherCfg = config(<<"ftp.example.org">>, <<"alice">>),
        Busy = fun(Pid) ->
            (worker(Pid, Cfg, 1))#{status => {busy, make_ref()}}
        end,
        WorkerSpecs = [
            Busy(P1), Busy(P2), Busy(P3), Busy(P4),
            #{pid => DisconnectedPid, last_used => 1}
        ],
        Bob = Cfg#{username => <<"bob">>},
        ?assertEqual(none, ftpfilez_pool:test_select_worker(Bob, WorkerSpecs)),
        ?assertEqual(
            {ok, DisconnectedPid},
            ftpfilez_pool:test_select_worker(OtherCfg, WorkerSpecs))
    after
        stop_workers(Pids)
    end.

normalizes_server_identity_test() ->
    Cfg = config(<<"FTP.Example.COM">>, <<"alice">>),
    ?assertEqual(
        {<<"ftp.example.com">>, 21},
        ftpfilez_pool:test_server_key(Cfg)),
    ?assertEqual(
        ftpfilez_pool:test_server_key(Cfg),
        ftpfilez_pool:test_server_key(Cfg#{host => "ftp.example.com"})).

worker(Pid, Key, LastUsed) ->
    #{pid => Pid, key => Key, last_used => LastUsed}.

config(Host, Username) ->
    #{
        host => Host,
        port => 21,
        username => Username,
        password => <<"secret">>,
        tls_options => []
    }.

workers(N) ->
    [spawn(fun worker_loop/0) || _ <- lists:seq(1, N)].

worker_loop() ->
    receive
        stop -> ok
    end.

stop_workers(Pids) ->
    [Pid ! stop || Pid <- Pids],
    ok.
