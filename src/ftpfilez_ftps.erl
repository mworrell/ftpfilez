%% @doc Place a data file on a FTP server, list home directory, or fetch a file.
%% @enddoc

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

-module(ftpfilez_ftps).

-export([
    list/1,
    upload/3,
    mkdir/2,
    download/2,
    stream/3,
    delete/2
]).

-include_lib("kernel/include/logger.hrl").

-define(BLOCK_SIZE, 65536).

-type config() :: #{
    host := string() | binary(),
    port => pos_integer(),
    username => string() | binary(),
    password => string() | binary()
}.
-export_type([ config/0 ]).

-spec list(Config) -> Result when
    Config :: config(),
    Result :: {ok, list(binary())} | {error, term()}.
list(Cfg) ->
    Fun = fun(Pid) ->
        parse_dir(ftp:nlist(Pid))
    end,
    do_ftp(Cfg, Fun).

-spec upload(Config, Filename, Data) -> Result when
    Config :: config(),
    Filename :: binary() | string(),
    Data :: binary() | {file, file:filename_all()},
    Result :: ok | {error, term()}.
upload(Cfg, Filename, Data) when is_binary(Data) ->
    Fun = fun(Pid) ->
        {Directory, Basename} = split_filename(to_bin(Filename)),
        case ensure_directory(Pid, Directory) of
            ok ->
                ftp:send_bin(Pid, Data, to_list(Basename));
            {error, _} = Error ->
                Error
        end
    end,
    do_ftp(Cfg, Fun);
upload(Cfg, Filename, {file, LocalFile}) ->
    Fun = fun(Pid) ->
        {Directory, Basename} = split_filename(to_bin(Filename)),
        case ensure_directory(Pid, Directory) of
            ok ->
                case ftp:send_chunk_start(Pid, to_list(Basename)) of
                    ok ->
                        case send_file_data(Pid, {file, LocalFile}) of
                            ok ->
                                ftp:send_chunk_end(Pid);
                            {error, _} = Error ->
                                Error
                        end;
                    {error, _} = Error ->
                        Error
                end;
            {error, _} = Error ->
                Error
        end
    end,
    do_ftp(Cfg, Fun).

-spec mkdir(Config, Directory) -> Result when
    Config :: config(),
    Directory :: binary() | string(),
    Result :: ok | {error, term()}.
mkdir(Cfg, Directory) ->
    Fun = fun(Pid) ->
        case binary:split(to_bin(Directory), <<"/">>, [ global, trim_all ]) of
            [] ->
                ok;
            DirList ->
                ensure_directory(Pid, DirList)
        end
    end,
    do_ftp(Cfg, Fun).

-spec download(Config, Filename) -> Result when
    Config :: config(),
    Filename :: binary() | string(),
    Result :: {ok, binary()} | {error, term()}.
download(Cfg, Filename) ->
    Fun = fun(Pid) ->
        {Directory, Basename} = split_filename(to_bin(Filename)),
        Path = join(Directory ++ [ Basename ]),
        ftp:recv_bin(Pid, to_list(Path))
    end,
    do_ftp(Cfg, Fun).

-spec stream(Config, Filename, StreamFun) -> Result when
    Config :: config(),
    Filename :: binary() | string(),
    StreamFun :: ftpfilez:stream_fun() | {any(), pid()},
    Result :: ok | {error, term()}.
stream(Cfg, Filename, StreamFun) ->
    Fun = fun(Pid) ->
        {Directory, Basename} = split_filename(to_bin(Filename)),
        Path = join(Directory ++ [ Basename ]),
        case ftp:recv_chunk_start(Pid, to_list(Path)) of
            ok ->
                start_fun(StreamFun),
                stream_loop(Pid, StreamFun);
            {error, _} = Error ->
                Error
        end
    end,
    case do_ftp(Cfg, Fun) of
        ok ->
            ok;
        {error, _} = Error ->
            error_fun(StreamFun, Error)
    end.

-spec delete(Config, Filename) -> Result when
    Config :: config(),
    Filename :: binary() | string(),
    Result :: ok | {error, term()}.
delete(Cfg, Filename) ->
    Fun = fun(Pid) ->
        {Directory, Basename} = split_filename(to_bin(Filename)),
        Path = join(Directory ++ [ Basename ]),
        ftp:delete(Pid, to_list(Path))
    end,
    do_ftp(Cfg, Fun).

join(L) ->
    iolist_to_binary(lists:join($/, L)).

ensure_directory(_Pid, []) ->
    ok;
ensure_directory(Pid, DirList) ->
    Directory = iolist_to_binary(lists:join($/, DirList)),
    case ftp:cd(Pid, unicode:characters_to_list(Directory)) of
        ok ->
            ok;
        {error, epath} ->
            recursive_mkdir(Pid, DirList);
        {error, _} = Error ->
            Error
    end.

recursive_mkdir(_Pid, []) ->
    ok;
recursive_mkdir(Pid, [Dir|Rest]) ->
    Dir1 = unicode:characters_to_list(Dir),
    case ftp:cd(Pid, Dir1) of
        ok ->
            recursive_mkdir(Pid, Rest);
        {error, epath} ->
            case ftp:mkdir(Pid, Dir1) of
                ok ->
                    ok = ftp:cd(Pid, Dir1),
                    recursive_mkdir(Pid, Rest);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

send_file_data(Pid, PD) ->
    case read_file_data(PD) of
        {ok, Data, PD1} ->
            case ftp:send_chunk(Pid, Data) of
                ok ->
                    send_file_data(Pid, PD1);
                {error, _} = Error ->
                    Error
            end;
        eof ->
            ok
    end.

read_file_data({file, Filename}) ->
    case file:open(Filename, [read,binary]) of
        {ok, FD} ->
            read_file_data({fd, FD});
        {error, _} = Error ->
            Error
    end;
read_file_data({fd, FD}) ->
    case file:read(FD, ?BLOCK_SIZE) of
        eof ->
            file:close(FD),
            eof;
        {ok, Data} ->
            {ok, Data, {fd, FD}}
    end.

do_ftp(#{ host := Host } =  Cfg, Fun) ->
    Port = case maps:get(port, Cfg, 21) of
        undefined -> 21;
        P when is_integer(P) -> P
    end,
    Username = to_list(maps:get(username, Cfg, "anonymous")),
    Password = to_list(maps:get(password, Cfg, "")),
    Options = [
        % {verbose, true},
        {mode, passive},
        {port, Port},
        {tls, vsftpd_tls()},
        {tls_ctrl_session_reuse, true},
        {tls_sec_method, case Port of 990 -> ftps; _ -> ftpes end}
    ],
    case ftp:open(to_list(Host), Options) of
        {ok, Pid} ->
            case ftp:user(Pid, Username, Password) of
                ok ->
                    Result = Fun(Pid),
                    ftp:close(Pid),
                    Result;
                {error, Reason} = Error ->
                    ftp:close(Pid),
                    ?LOG_ERROR(#{
                        text => <<"FTP user login gave error">>,
                        in => ftpfilez,
                        result => error,
                        reason => Reason,
                        username => Username,
                        host => Host
                    }),
                    Error
            end;
        {error, Reason} = Error ->
            ?LOG_ERROR(#{
                text => <<"FTP connect gave error">>,
                in => ftpfilez,
                result => error,
                reason => Reason,
                host => Host
            }),
            Error
    end.


stream_loop(Pid, Fun) ->
    case ftp:recv_chunk(Pid) of
        ok ->
            eof_fun(Fun),
            ok;
        {ok, Bin} ->
            call_fun(Fun, Bin),
            stream_loop(Pid, Fun);
        {error, _} = Error ->
            Error
    end.


start_fun({Ref, Pid}) when is_pid(Pid) ->
    Pid ! {ftp, {Ref, stream_start, []}};
start_fun(_Fun) ->
    ok.

call_fun({M,F,A}, Arg) ->
    erlang:apply(M,F,A++[Arg]);
call_fun(Fun, Arg) when is_function(Fun) ->
    Fun(Arg);
call_fun(Pid, Arg) when is_pid(Pid) ->
    Pid ! {ftp, Arg};
call_fun({Ref, Pid}, Arg) when is_pid(Pid) ->
    Pid ! {ftp, {Ref, stream, Arg}}.

eof_fun({M,F,A}) ->
    erlang:apply(M,F,A++[eof]);
eof_fun(Fun) when is_function(Fun) ->
    Fun(eof);
eof_fun(Pid) when is_pid(Pid) ->
    Pid ! {ftp, eof};
eof_fun({Ref, Pid}) when is_pid(Pid) ->
    Pid ! {ftp, {Ref, stream_end, []}}.


error_fun({M,F,A}, Error) ->
    erlang:apply(M,F,A++[Error]);
error_fun(Fun, Error) when is_function(Fun) ->
    Fun(Error);
error_fun(Pid, Error) when is_pid(Pid) ->
    Pid ! {ftp, Error};
error_fun({Ref, Pid}, Error) when is_pid(Pid) ->
    Pid ! {ftp, {Ref, Error}}.


parse_dir({ok, L}) ->
    Lines = binary:split(unicode:characters_to_binary(L), [<<13>>, <<10>>], [global, trim_all]),
    {ok, Lines -- [ <<".">>, <<"..">> ]};
parse_dir({error, _} = E) ->
    E.

split_filename(Filename) ->
    Parts = binary:split(Filename, <<"/">>, [ global, trim_all ]),
    Basename = lists:last(Parts),
    Directory = lists:reverse(tl(lists:reverse(Parts))),
    {Directory, Basename}.

vsftpd_tls() ->
    %% Workaround for interoperability issues with vsftpd =< 3.0.2:
    %%
    %% vsftpd =< 3.0.2 does not support ECDHE ciphers and the ssl application
    %% removed ciphers with RSA key exchange from its default cipher list.
    %% To allow interoperability with old versions of vsftpd, cipher suites
    %% with RSA key exchange are appended to the default cipher list.
    All = ssl:cipher_suites(all, 'tlsv1.2'),
    Default = ssl:cipher_suites(default, 'tlsv1.2'),
    RSASuites = ssl:filter_cipher_suites(All, [
            {key_exchange, fun(rsa) -> true; (_) -> false end}
        ]),
    Suites = ssl:append_cipher_suites(RSASuites, Default),
    [
        {ciphers, Suites},
        {reuse_sessions, true},
        %% vsftpd =< 3.0.3 gets upset with anything later than tlsv1.2
        {versions,['tlsv1.2']}
    ].

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(undefined) -> "".

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(undefined) -> "".
