%% @doc Short-lived cache for connection/login failures.
%%
%% This prevents a queue with many jobs for the same FTP credentials from
%% opening many connections that are very likely to fail with the same error.
%% Only connection setup errors are cached; file operation errors are not.
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

-module(ftpfilez_backoff).

-behaviour(gen_server).

-export([
    start_link/0,
    lookup/4,
    remember/5,
    forget/4
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(TABLE, ?MODULE).
-define(DEFAULT_BACKOFF_MS, 3000).

-type key() :: {binary(), pos_integer(), binary(), binary()}.

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec lookup(Host, Port, Username, Password) -> none | {error, term()} when
    Host :: string() | binary(),
    Port :: pos_integer(),
    Username :: string() | binary(),
    Password :: string() | binary().
lookup(Host, Port, Username, Password) ->
    Key = key(Host, Port, Username, Password),
    Now = erlang:monotonic_time(millisecond),
    try ets:lookup(?TABLE, Key) of
        [{Key, Until, Error}] when Until > Now ->
            Error;
        [{Key, _Until, _Error}] ->
            ets:delete(?TABLE, Key),
            none;
        [] ->
            none
    catch
        error:badarg ->
            none
    end.

-spec remember(Host, Port, Username, Password, Error) -> ok when
    Host :: string() | binary(),
    Port :: pos_integer(),
    Username :: string() | binary(),
    Password :: string() | binary(),
    Error :: {error, term()}.
remember(Host, Port, Username, Password, {error, _} = Error) ->
    BackoffMs = backoff_ms(),
    case BackoffMs > 0 of
        true ->
            Key = key(Host, Port, Username, Password),
            Until = erlang:monotonic_time(millisecond) + BackoffMs,
            try ets:insert(?TABLE, {Key, Until, Error}) of
                true -> ok
            catch
                error:badarg -> ok
            end;
        false ->
            ok
    end.

-spec forget(Host, Port, Username, Password) -> ok when
    Host :: string() | binary(),
    Port :: pos_integer(),
    Username :: string() | binary(),
    Password :: string() | binary().
forget(Host, Port, Username, Password) ->
    Key = key(Host, Port, Username, Password),
    try ets:delete(?TABLE, Key) of
        true -> ok
    catch
        error:badarg -> ok
    end.

init([]) ->
    ?TABLE = ets:new(?TABLE, [
        named_table,
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    {ok, #{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

-spec key(string() | binary(), pos_integer(), string() | binary(), string() | binary()) -> key().
key(Host, Port, Username, Password) ->
    PasswordHash = erlang:md5(to_bin(Password)),
    {to_bin(Host), Port, to_bin(Username), PasswordHash}.

-spec backoff_ms() -> non_neg_integer().
backoff_ms() ->
    case application:get_env(ftpfilez, connect_error_backoff_ms) of
        {ok, N} when is_integer(N), N >= 0 -> N;
        undefined -> ?DEFAULT_BACKOFF_MS
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(undefined) -> <<>>.
