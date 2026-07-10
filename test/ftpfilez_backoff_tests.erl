-module(ftpfilez_backoff_tests).

-include_lib("eunit/include/eunit.hrl").

backoff_test_() ->
    {foreach,
        fun setup/0,
        fun cleanup/1,
        [
            test_case(fun remembers_connection_error/1),
            test_case(fun isolates_different_credentials/1),
            test_case(fun expires_connection_error/1),
            test_case(fun can_disable_backoff/1),
            test_case(fun lookup_is_safe_before_table_exists/1)
        ]}.

test_case(Fun) ->
    fun(Ctx) ->
        fun() -> Fun(Ctx) end
    end.

setup() ->
    Env = application:get_env(ftpfilez, connect_error_backoff_ms),
    Started = case whereis(ftpfilez_backoff) of
        undefined ->
            {ok, Pid} = ftpfilez_backoff:start_link(),
            unlink(Pid),
            {true, Pid};
        Pid ->
            {false, Pid}
    end,
    clear_table(),
    {Started, Env}.

cleanup({{StartedByTest, Pid}, Env}) ->
    restore_env(Env),
    clear_table(),
    case StartedByTest andalso is_process_alive(Pid) of
        true ->
            Ref = erlang:monitor(process, Pid),
            exit(Pid, shutdown),
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            after 1000 ->
                erlang:demonitor(Ref, [flush]),
                ok
            end;
        false ->
            ok
    end.

remembers_connection_error(_Ctx) ->
    application:set_env(ftpfilez, connect_error_backoff_ms, 5000),
    Error = {error, econn},
    ok = ftpfilez_backoff:remember(<<"ftp.example.com">>, 21, <<"user">>, <<"password">>, Error),
    ?assertEqual(Error, ftpfilez_backoff:lookup(<<"ftp.example.com">>, 21, <<"user">>, <<"password">>)).

isolates_different_credentials(_Ctx) ->
    application:set_env(ftpfilez, connect_error_backoff_ms, 5000),
    Error = {error, econn},
    ok = ftpfilez_backoff:remember(<<"ftp.example.com">>, 21, <<"user">>, <<"password">>, Error),
    ?assertEqual(none, ftpfilez_backoff:lookup(<<"ftp.example.com">>, 21, <<"user">>, <<"other">>)),
    ?assertEqual(none, ftpfilez_backoff:lookup(<<"ftp.example.com">>, 21, <<"other">>, <<"password">>)),
    ?assertEqual(none, ftpfilez_backoff:lookup(<<"ftp.example.org">>, 21, <<"user">>, <<"password">>)),
    ?assertEqual(none, ftpfilez_backoff:lookup(<<"ftp.example.com">>, 990, <<"user">>, <<"password">>)).

expires_connection_error(_Ctx) ->
    application:set_env(ftpfilez, connect_error_backoff_ms, 20),
    Error = {error, econn},
    ok = ftpfilez_backoff:remember(<<"ftp.example.com">>, 21, <<"user">>, <<"password">>, Error),
    ?assertEqual(Error, ftpfilez_backoff:lookup(<<"ftp.example.com">>, 21, <<"user">>, <<"password">>)),
    timer:sleep(40),
    ?assertEqual(none, ftpfilez_backoff:lookup(<<"ftp.example.com">>, 21, <<"user">>, <<"password">>)).

can_disable_backoff(_Ctx) ->
    application:set_env(ftpfilez, connect_error_backoff_ms, 0),
    ok = ftpfilez_backoff:remember(<<"ftp.example.com">>, 21, <<"user">>, <<"password">>, {error, econn}),
    ?assertEqual(none, ftpfilez_backoff:lookup(<<"ftp.example.com">>, 21, <<"user">>, <<"password">>)).

lookup_is_safe_before_table_exists({{StartedByTest, Pid}, _Env}) ->
    case StartedByTest andalso is_process_alive(Pid) of
        true ->
            Ref = erlang:monitor(process, Pid),
            exit(Pid, shutdown),
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            after 1000 ->
                erlang:demonitor(Ref, [flush]),
                ok
            end;
        false ->
            ets:delete(ftpfilez_backoff)
    end,
    ?assertEqual(none, ftpfilez_backoff:lookup(<<"ftp.example.com">>, 21, <<"user">>, <<"password">>)).

restore_env(undefined) ->
    application:unset_env(ftpfilez, connect_error_backoff_ms);
restore_env({ok, Value}) ->
    application:set_env(ftpfilez, connect_error_backoff_ms, Value).

clear_table() ->
    try ets:delete_all_objects(ftpfilez_backoff) of
        true -> ok
    catch
        error:badarg -> ok
    end.
