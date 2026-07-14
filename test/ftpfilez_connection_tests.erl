-module(ftpfilez_connection_tests).

-include_lib("eunit/include/eunit.hrl").

can_switch_username_on_same_transport_test() ->
    Alice = #{
        host => <<"FTP.Example.COM">>,
        port => undefined,
        username => <<"alice">>,
        password => <<"alice-secret">>,
        tls_options => []
    },
    Bob = Alice#{
        host => "ftp.example.com",
        username => <<"bob">>,
        password => <<"bob-secret">>
    },
    ?assert(ftpfilez_connection:same_transport(Alice, Bob)),
    ?assertNot(ftpfilez_connection:same_transport(Alice, Bob#{port => 990})),
    ?assertNot(ftpfilez_connection:same_transport(
        Alice,
        Bob#{tls_options => [{verify, verify_none}]})),
    ?assertNot(ftpfilez_connection:same_transport(Alice, Bob#{tls => false})).

brutally_kills_unresponsive_connection_owner_test() ->
    PreviousTimeout = application:get_env(ftpfilez, connection_close_timeout_ms),
    application:set_env(ftpfilez, connection_close_timeout_ms, 20),
    Pid = spawn(fun unresponsive/0),
    Monitor = erlang:monitor(process, Pid),
    try
        ?assertEqual(killed, ftpfilez_connection:close_connection(Pid)),
        receive
            {'DOWN', Monitor, process, Pid, killed} -> ok
        after 1000 ->
            error(connection_owner_was_not_killed)
        end
    after
        restore_env(connection_close_timeout_ms, PreviousTimeout)
    end.

unresponsive() ->
    receive
        _Message -> unresponsive()
    end.

restore_env(Key, undefined) ->
    application:unset_env(ftpfilez, Key);
restore_env(Key, {ok, Value}) ->
    application:set_env(ftpfilez, Key, Value).
