%% @doc Main app code. Start the supervisor for the queued jobs.
%% @author Marc Worrell
%% @copyright 2022 Marc Worrell
%% @end

%% Copyright 2022 Marc Worrell
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

-module(ftpfilez_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case ftpfilez_sup:start_link() of
        {ok, Pid} ->
            ensure_queue(),
            {ok, Pid};
        Other ->
            {error, Other}
    end.

stop(_State) ->
    ok.

ensure_queue() ->
    jobs:add_queue(ftpfilez_jobs, [
            {regulators, [{counter, [
                                {limit, max_connections()}
                             ]}]}
        ]).

%% @doc Max number of parallel connections. Quite some FTP servers
%% have a limit of 10 connections, so default to 8.
-spec max_connections() -> pos_integer().
max_connections() ->
    case application:get_env(ftpfilez, max_connections) of
        {ok, N} when is_integer(N) -> N;
        undefined -> 8
    end.
