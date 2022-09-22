%% @doc FTPS file storage. Can put, get and stream files from FTP servers.
%% Similar interface as s3filez.
%% @author Marc Worrell
%% @copyright 2022 Marc Worrell

%% Copyright 2022 Marc Worrell
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(ftpfilez).

-export([
    queue_get/3,
    queue_get_id/4,
    queue_put/3,
    queue_put/4,
    queue_put/5,
    queue_put_id/5,
    queue_delete/2,
    queue_delete/3,
    queue_delete_id/4,

    queue_stream/3,
    queue_stream_id/4,

    get/2,
    delete/2,
    put/3,
    put/4,
    stream/3,

    create_bucket/2,
    create_bucket/3
    ]).

% -include_lib("kernel/include/logger.hrl").

-type config() :: {Username::binary(), Password::binary()}.
-type url() :: binary() | string().
-type ready_fun() :: undefined
                    | {atom(),atom(),list()}
                    | fun()
                    | pid().
-type stream_fun() :: {atom(),atom(),list()}
                    | fun()
                    | pid().
-type put_data() :: {data, binary()}
                  | {filename, pos_integer(), file:filename_all()}
                  | {filename, file:filename_all()}.

-type queue_reply() :: {ok, any(), pid()} | {error, {already_started, pid()}}.

-type sync_reply() :: ok | {error, enoent | forbidden | term()}.

-type put_opts() :: [ put_opt() ].

% The s3filez options below are not yet implemented or supported by ftpfilez
-type put_opt() :: {acl, acl_type()} | {content_type, string()}.
-type acl_type() :: private | public_read | public_read_write | authenticated_read
                  | bucket_owner_read | bucket_owner_full_control.

-export_type([
    config/0,
    url/0,
    ready_fun/0,
    stream_fun/0,
    put_data/0,
    queue_reply/0,
    sync_reply/0,
    put_opt/0,
    put_opts/0,
    acl_type/0
    ]).

%% @doc Queue a file dowloader and call ready_fun when finished.
-spec queue_get(config(), url(), ready_fun()) -> queue_reply().
queue_get(Config, Url, ReadyFun) ->
    ftpfilez_jobs_sup:queue({get, Config, Url, ReadyFun}).


%% @doc Queue a named file dowloader and call ready_fun when finished.
%%      Names must be unique, duplicates are refused with <tt>{error, {already_started, _}}</tt>.
-spec queue_get_id(any(), config(), url(), ready_fun()) -> queue_reply().
queue_get_id(JobId, Config, Url, ReadyFun) ->
    ftpfilez_jobs_sup:queue(JobId, {get, Config, Url, ReadyFun}).


%% @doc Queue a file uploader. The data can be a binary or a filename.
-spec queue_put(config(), url(), put_data()) -> queue_reply().
queue_put(Config, Url, What) ->
    queue_put(Config, Url, What, undefined).


%% @doc Queue a file uploader and call ready_fun when finished.
-spec queue_put(config(), url(), put_data(), ready_fun()) -> queue_reply().
queue_put(Config, Url, What, ReadyFun) ->
    queue_put(Config, Url, What, ReadyFun, []).


%% @doc Queue a file uploader and call ready_fun when finished. Options include
%% the <tt>acl</tt> setting and <tt>content_type</tt> for the file.
-spec queue_put(config(), url(), put_data(), ready_fun(), put_opts()) -> queue_reply().
queue_put(Config, Url, What, ReadyFun, Opts) ->
    ftpfilez_jobs_sup:queue({put, Config, Url, What, ReadyFun, Opts}).

%% @doc Start a named file uploader. Names must be unique, duplicates are refused with
%% <tt>{error, {already_started, _}}</tt>.
-spec queue_put_id(any(), config(), url(), put_data(), ready_fun()) -> queue_reply().
queue_put_id(JobId, Config, Url, What, ReadyFun) ->
    ftpfilez_jobs_sup:queue(JobId, {put, Config, Url, What, ReadyFun}).


%% @doc Async delete a file on S3
-spec queue_delete(config(), url()) -> queue_reply().
queue_delete(Config, Url) ->
    queue_delete(Config, Url, undefined).

%% @doc Async delete a file on S3, call ready_fun when ready.
-spec queue_delete(config(), url(), ready_fun()) -> queue_reply().
queue_delete(Config, Url, ReadyFun) ->
    ftpfilez_jobs_sup:queue({delete, Config, Url, ReadyFun}).


%% @doc Queue a named file deletion process, call ready_fun when ready.
-spec queue_delete_id(any(), config(), url(), ready_fun()) -> queue_reply().
queue_delete_id(JobId, Config, Url, ReadyFun) ->
    ftpfilez_jobs_sup:queue(JobId, {delete, Config, Url, ReadyFun}).


%% @doc Queue a file downloader that will stream chunks to the given stream_fun. The
%% default block size for the chunks is 64KB.
-spec queue_stream(config(), url(), stream_fun()) -> queue_reply().
queue_stream(Config, Url, self) ->
    queue_stream(Config, Url, self());
queue_stream(Config, Url, StreamFun) ->
    ftpfilez_jobs_sup:queue({stream, Config, Url, StreamFun}).


%% @doc Queue a named file downloader that will stream chunks to the given stream_fun. The
%% default block size for the chunks is 64KB.
-spec queue_stream_id(any(), config(), url(), stream_fun()) -> queue_reply().
queue_stream_id(JobId, Config, Url, self) ->
    queue_stream_id(JobId, Config, Url, self());
queue_stream_id(JobId, Config, Url, StreamFun) ->
    ftpfilez_jobs_sup:queue(JobId, {stream, Config, Url, StreamFun}).


%%% Normal API - blocking on the process

%% @doc Fetch the data at the url.
%% @todo Ensure a queue per hostname.
-spec get( config(), url() ) ->
      {ok, ContentType::binary(), Data::binary()}
    | {error, enoent | forbidden | term()}.
get(Config, Url) ->
    % jobs:run(ftpfilez_jobs, fun() -> request(Config, get, Url, [], []) end),
    {Cfg, Path} = config_path(Config, Url),
    case ftpfilez_ftps:download(Cfg, Path) of
        {ok, Data} ->
            {ok, <<"application/octet-stream">>, Data};
        {error, epath} ->
            {error, enoent};
        {error, _} = Error ->
            Error
    end.

%% @doc Delete the file at the url.
-spec delete( config(), url() ) -> sync_reply().
delete(Config, Url) ->
    {Cfg, Path} = config_path(Config, Url),
    case ftpfilez_ftps:delete(Cfg, Path) of
        ok ->
            ok;
        {error, epath} ->
            {error, enoent};
        {error, _} = Error ->
            Error
    end.


%% @doc Put a binary or file to the given url.
-spec put( config(), url(), put_data() ) -> sync_reply().
put(Config, Url, Payload) ->
    put(Config, Url, Payload, []).


%% @doc Put a binary or file to the given url. Set options for acl.
%% Ensures that the directory of the file is present by recursively creating
%% the sub directories.
-spec put( config(), url(), put_data(), put_opts() ) -> sync_reply().
put(Config, Url, {data, Data}, _Opts) ->
    {Cfg, Path} = config_path(Config, Url),
    ftpfilez_ftps:upload(Cfg, Path, Data);
put(Config, Url, {filename, Filename}, _Opts) ->
    {Cfg, Path} = config_path(Config, Url),
    ftpfilez_ftps:upload(Cfg, Path, {file, Filename});
put(Config, Url, {filename, _Size, Filename}, Opts) ->
    put(Config, Url, {filename, Filename}, Opts).

%% @doc Create a private bucket (aka directory) at the URL.
-spec create_bucket( config(), url() ) -> sync_reply().
create_bucket(Config, Url) ->
    create_bucket(Config, Url, [ {acl, private} ]).

%% @doc Create a bucket at the URL, with acl options.
-spec create_bucket( config(), url(), put_opts() ) -> sync_reply().
create_bucket(Config, Url, _Opts) ->
    {Cfg, Path} = config_path(Config, Url),
    ftpfilez_ftps:mkdir(Cfg, Path).

%% @doc Stream the contents of the url to the function, callback or to the httpc-streaming Pid.
-spec stream( config(), url(), stream_fun() | {any(), pid()} ) -> sync_reply().
stream(Config, Url, {_Ref, Pid} = Fun) when is_pid(Pid) ->
    {Cfg, Path} = config_path(Config, Url),
    ftpfilez_ftps:stream(Cfg, Path, Fun);
stream(Config, Url, Fun) when is_function(Fun,1); is_pid(Fun) ->
    {Cfg, Path} = config_path(Config, Url),
    ftpfilez_ftps:stream(Cfg, Path, Fun);
stream(Config, Url, {_M,_F,_A} = MFA) ->
    {Cfg, Path} = config_path(Config, Url),
    ftpfilez_ftps:stream(Cfg, Path, MFA).


config_path({Username, Password}, Url) ->
    {_Scheme, Host, Path} = urlsplit(Url),
    {Host1, Port} = case binary:split(Host, <<":">>) of
        [H1] -> {H1, undefined};
        [H1,P] -> {H1, binary_to_integer(P)}
    end,
    Cfg = #{
        host => Host1,
        port => Port,
        username => Username,
        password => Password
    },
    {Cfg, Path}.


urlsplit(Url) when is_binary(Url) ->
    case binary:split(Url, <<":">>) of
        [Scheme, <<"//", HostPath/binary>>] ->
            {Host,Path} = urlsplit_hostpath(HostPath),
            {Scheme, Host, Path};
        [<<"//", HostPath/binary>>] ->
            {Host,Path} = urlsplit_hostpath(HostPath),
            {no_scheme, Host, Path};
        [Path] ->
            {no_scheme, <<>>, Path}
    end;
urlsplit(Url) ->
    urlsplit(unicode:characters_to_binary(Url)).

urlsplit_hostpath(HP) ->
    case binary:split(HP, <<"/">>) of
        [Host,Path] -> {Host,urlsplit_path(binary:split(Path, <<"?">>))};
        [Host] -> {Host, <<"/">>}
    end.

urlsplit_path([Path]) -> <<"/", Path/binary>>;
urlsplit_path([Path, _]) -> <<"/", Path/binary>>.
