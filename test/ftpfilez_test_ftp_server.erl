%% @doc Minimal plain FTP server for end-to-end tests.
%% @private

-module(ftpfilez_test_ftp_server).

-behaviour(gen_server).

-export([
    start_link/0,
    stop/1,
    port/1,
    stats/1,
    close_connections/1,
    set_transfer_delay/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    listen_socket :: gen_tcp:socket(),
    acceptor :: pid(),
    files = #{} :: #{binary() => binary()},
    connections = #{} :: #{pid() => {gen_tcp:socket(), reference()}},
    total_connections = 0 :: non_neg_integer(),
    max_connections = 0 :: non_neg_integer(),
    authentications = [] :: [binary()],
    active_transfers = 0 :: non_neg_integer(),
    max_active_transfers = 0 :: non_neg_integer(),
    total_transfers = 0 :: non_neg_integer(),
    transfer_delay = 0 :: non_neg_integer()
}).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

-spec stop(pid()) -> ok.
stop(Server) ->
    try gen_server:stop(Server) of
        ok -> ok
    catch
        exit:noproc -> ok;
        exit:{noproc, _} -> ok
    end.

-spec port(pid()) -> inet:port_number().
port(Server) ->
    gen_server:call(Server, port).

-spec stats(pid()) -> map().
stats(Server) ->
    gen_server:call(Server, stats).

-spec close_connections(pid()) -> ok.
close_connections(Server) ->
    gen_server:call(Server, close_connections).

-spec set_transfer_delay(pid(), non_neg_integer()) -> ok.
set_transfer_delay(Server, Delay) ->
    gen_server:call(Server, {set_transfer_delay, Delay}).

init([]) ->
    {ok, ListenSocket} = gen_tcp:listen(0, [
        binary,
        {active, false},
        {ip, {127, 0, 0, 1}},
        {reuseaddr, true}
    ]),
    Server = self(),
    Acceptor = spawn(fun() -> accept_loop(ListenSocket, Server) end),
    {ok, #state{listen_socket = ListenSocket, acceptor = Acceptor}}.

handle_call(port, _From, #state{listen_socket = ListenSocket} = State) ->
    {ok, {_Address, Port}} = inet:sockname(ListenSocket),
    {reply, Port, State};
handle_call(stats, _From, State) ->
    Stats = #{
        connections => maps:size(State#state.connections),
        total_connections => State#state.total_connections,
        max_connections => State#state.max_connections,
        authentications => lists:reverse(State#state.authentications),
        active_transfers => State#state.active_transfers,
        max_active_transfers => State#state.max_active_transfers,
        total_transfers => State#state.total_transfers
    },
    {reply, Stats, State};
handle_call(close_connections, _From, #state{connections = Connections} = State) ->
    [gen_tcp:close(Socket) || {_Pid, {Socket, _Monitor}} <- maps:to_list(Connections)],
    {reply, ok, State};
handle_call({set_transfer_delay, Delay}, _From, State)
        when is_integer(Delay), Delay >= 0 ->
    {reply, ok, State#state{transfer_delay = Delay}};
handle_call({put, Path, Data}, _From, #state{files = Files} = State) ->
    {reply, ok, State#state{files = Files#{Path => Data}}};
handle_call({get, Path}, _From, #state{files = Files} = State) ->
    {reply, maps:find(Path, Files), State};
handle_call({delete, Path}, _From, #state{files = Files} = State) ->
    case maps:is_key(Path, Files) of
        true -> {reply, ok, State#state{files = maps:remove(Path, Files)}};
        false -> {reply, {error, enoent}, State}
    end;
handle_call(begin_transfer, _From, State) ->
    Active = State#state.active_transfers + 1,
    MaxActive = max(Active, State#state.max_active_transfers),
    {reply, State#state.transfer_delay, State#state{
        active_transfers = Active,
        max_active_transfers = MaxActive,
        total_transfers = State#state.total_transfers + 1
    }};
handle_call(end_transfer, _From, State) ->
    {reply, ok, State#state{active_transfers = State#state.active_transfers - 1}};
handle_call(Msg, _From, State) ->
    {reply, {error, {unknown_call, Msg}}, State}.

handle_cast({connection_open, Pid, Socket}, #state{connections = Connections} = State) ->
    Monitor = erlang:monitor(process, Pid),
    Count = maps:size(Connections) + 1,
    Connections1 = Connections#{Pid => {Socket, Monitor}},
    {noreply, State#state{
        connections = Connections1,
        total_connections = State#state.total_connections + 1,
        max_connections = max(Count, State#state.max_connections)
    }};
handle_cast({authenticated, Username}, State) ->
    {noreply, State#state{
        authentications = [Username | State#state.authentications]
    }};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Monitor, process, Pid, _Reason},
        #state{connections = Connections} = State) ->
    case maps:find(Pid, Connections) of
        {ok, {_Socket, Monitor}} ->
            {noreply, State#state{connections = maps:remove(Pid, Connections)}};
        _ ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{
        listen_socket = ListenSocket,
        acceptor = Acceptor,
        connections = Connections
    }) ->
    gen_tcp:close(ListenSocket),
    exit(Acceptor, shutdown),
    [gen_tcp:close(Socket) || {_Pid, {Socket, _Monitor}} <- maps:to_list(Connections)],
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

accept_loop(ListenSocket, Server) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            Pid = spawn(fun() -> connection_init(Server) end),
            ok = gen_tcp:controlling_process(Socket, Pid),
            Pid ! {socket, Socket},
            accept_loop(ListenSocket, Server);
        {error, closed} ->
            ok
    end.

connection_init(Server) ->
    receive
        {socket, Socket} ->
            gen_server:cast(Server, {connection_open, self(), Socket}),
            ok = reply(Socket, <<"220 ftpfilez test server ready">>),
            connection_loop(#{
                server => Server,
                socket => Socket,
                buffer => <<>>,
                cwd => <<"/">>,
                passive => undefined,
                pending_user => undefined
            })
    end.

connection_loop(#{socket := Socket, buffer := Buffer} = State) ->
    case recv_command(Socket, Buffer) of
        {ok, Line, Rest} ->
            case handle_command(Line, State#{buffer => Rest}) of
                {continue, State1} -> connection_loop(State1);
                stop -> gen_tcp:close(Socket)
            end;
        {error, closed} ->
            close_passive(State),
            ok;
        {error, _Reason} ->
            close_passive(State),
            gen_tcp:close(Socket)
    end.

recv_command(Socket, Buffer) ->
    case binary:match(Buffer, <<"\r\n">>) of
        {Pos, 2} ->
            <<Line:Pos/binary, _CrLf:2/binary, Rest/binary>> = Buffer,
            {ok, Line, Rest};
        nomatch ->
            case gen_tcp:recv(Socket, 0) of
                {ok, Data} -> recv_command(Socket, <<Buffer/binary, Data/binary>>);
                {error, _} = Error -> Error
            end
    end.

handle_command(Line, #{socket := Socket} = State) ->
    {Command, Argument} = split_command(Line),
    case Command of
        <<"USER">> ->
            ok = reply(Socket, <<"331 Password required">>),
            {continue, State#{pending_user => Argument}};
        <<"PASS">> ->
            Username = maps:get(pending_user, State, <<"anonymous">>),
            gen_server:cast(maps:get(server, State), {authenticated, Username}),
            ok = reply(Socket, <<"230 User logged in">>),
            {continue, State};
        <<"PWD">> ->
            Cwd = maps:get(cwd, State),
            ok = reply(Socket, <<"257 \"", Cwd/binary, "\"">>),
            {continue, State};
        <<"CWD">> ->
            Cwd = resolve_path(maps:get(cwd, State), Argument),
            ok = reply(Socket, <<"250 Directory changed">>),
            {continue, State#{cwd => Cwd}};
        <<"MKD">> ->
            ok = reply(Socket, <<"257 Directory created">>),
            {continue, State};
        <<"EPSV">> ->
            open_passive(epsv, State);
        <<"PASV">> ->
            open_passive(pasv, State);
        <<"STOR">> ->
            store(Argument, State);
        <<"RETR">> ->
            retrieve(Argument, State);
        <<"DELE">> ->
            delete(Argument, State);
        <<"FEAT">> ->
            ok = gen_tcp:send(Socket, <<"211-Features\r\n UTF8\r\n211 End\r\n">>),
            {continue, State};
        <<"SYST">> ->
            ok = reply(Socket, <<"215 UNIX Type: L8">>),
            {continue, State};
        <<"QUIT">> ->
            _ = reply(Socket, <<"221 Goodbye">>),
            stop;
        _ ->
            ok = reply(Socket, <<"200 Command okay">>),
            {continue, State}
    end.

split_command(Line) ->
    case binary:split(Line, <<" ">>) of
        [Command] -> {upper(Command), <<>>};
        [Command, Argument] -> {upper(Command), Argument}
    end.

upper(Bin) ->
    unicode:characters_to_binary(string:uppercase(binary_to_list(Bin))).

open_passive(Mode, #{socket := Socket} = State) ->
    close_passive(State),
    {ok, ListenSocket} = gen_tcp:listen(0, [
        binary,
        {active, false},
        {ip, {127, 0, 0, 1}},
        {reuseaddr, true}
    ]),
    {ok, {_Address, Port}} = inet:sockname(ListenSocket),
    ok = passive_reply(Mode, Socket, Port),
    {continue, State#{passive => ListenSocket}}.

passive_reply(epsv, Socket, Port) ->
    reply(Socket, iolist_to_binary(io_lib:format(
        "229 Entering Extended Passive Mode (|||~B|)", [Port])));
passive_reply(pasv, Socket, Port) ->
    P1 = Port div 256,
    P2 = Port rem 256,
    reply(Socket, iolist_to_binary(io_lib:format(
        "227 Entering Passive Mode (127,0,0,1,~B,~B)", [P1, P2]))).

store(Argument, #{server := Server, socket := Socket, passive := ListenSocket} = State)
        when is_port(ListenSocket) ->
    ok = reply(Socket, <<"150 Opening data connection">>),
    {ok, DataSocket} = gen_tcp:accept(ListenSocket),
    Delay = gen_server:call(Server, begin_transfer),
    try
        {ok, Data} = recv_data(DataSocket, <<>>),
        timer:sleep(Delay),
        Path = resolve_path(maps:get(cwd, State), Argument),
        ok = gen_server:call(Server, {put, Path, Data}),
        gen_tcp:close(DataSocket),
        ok = reply(Socket, <<"226 Transfer complete">>)
    after
        gen_server:call(Server, end_transfer)
    end,
    gen_tcp:close(ListenSocket),
    {continue, State#{passive => undefined}};
store(_Argument, #{socket := Socket} = State) ->
    ok = reply(Socket, <<"425 Use PASV first">>),
    {continue, State}.

retrieve(Argument, #{server := Server, socket := Socket, passive := ListenSocket} = State)
        when is_port(ListenSocket) ->
    Path = resolve_path(maps:get(cwd, State), Argument),
    case gen_server:call(Server, {get, Path}) of
        {ok, Data} ->
            ok = reply(Socket, <<"150 Opening data connection">>),
            {ok, DataSocket} = gen_tcp:accept(ListenSocket),
            Delay = gen_server:call(Server, begin_transfer),
            try
                timer:sleep(Delay),
                ok = gen_tcp:send(DataSocket, Data),
                gen_tcp:close(DataSocket),
                ok = reply(Socket, <<"226 Transfer complete">>)
            after
                gen_server:call(Server, end_transfer)
            end;
        error ->
            ok = reply(Socket, <<"550 File unavailable">>)
    end,
    gen_tcp:close(ListenSocket),
    {continue, State#{passive => undefined}};
retrieve(_Argument, #{socket := Socket} = State) ->
    ok = reply(Socket, <<"425 Use PASV first">>),
    {continue, State}.

delete(Argument, #{server := Server, socket := Socket} = State) ->
    Path = resolve_path(maps:get(cwd, State), Argument),
    case gen_server:call(Server, {delete, Path}) of
        ok -> reply(Socket, <<"250 File deleted">>);
        {error, enoent} -> reply(Socket, <<"550 File unavailable">>)
    end,
    {continue, State}.

recv_data(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} -> recv_data(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} -> {ok, Acc};
        {error, _} = Error -> Error
    end.

resolve_path(_Cwd, <<"/", _/binary>> = Path) ->
    normalize_path(Path);
resolve_path(<<"/">>, Path) ->
    normalize_path(<<"/", Path/binary>>);
resolve_path(Cwd, Path) ->
    normalize_path(<<Cwd/binary, "/", Path/binary>>).

normalize_path(Path) ->
    Parts = binary:split(Path, <<"/">>, [global, trim_all]),
    case Parts of
        [] -> <<"/">>;
        _ -> <<"/", (iolist_to_binary(lists:join(<<"/">>, Parts)))/binary>>
    end.

close_passive(#{passive := ListenSocket}) when is_port(ListenSocket) ->
    gen_tcp:close(ListenSocket);
close_passive(_State) ->
    ok.

reply(Socket, Message) ->
    gen_tcp:send(Socket, [Message, <<"\r\n">>]).
