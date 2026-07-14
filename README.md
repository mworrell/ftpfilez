[![Test](https://github.com/mworrell/ftpfilez/actions/workflows/test.yml/badge.svg)](https://github.com/mworrell/ftpfilez/actions/workflows/test.yml)

[![Hex.pm Version](https://img.shields.io/hexpm/v/ftpfilez.svg)](https://hex.pm/packages/ftpfilez)
[![Hex.pm Downloads](https://img.shields.io/hexpm/dt/ftpfilez.svg)](https://hex.pm/packages/ftpfilez)

ftpfilez
=======

Really simple FTPS client - only put, get and delete.

This client is used in combination with filezcache and zotonic.

Distinction with other FTPS clients is:

 * Only get, put and delete are supported
 * put of files and/or binaries
 * get with optional streaming function, to be able to stream to the filezcache
 * simple jobs queue, using the 'jobs' scheduler
 * missing directories in the target path are automatically created
 * persistent, health-checked connections with a maximum of four per server

**NOTA BENE** FTPS is enabled by default, because you really shouldn't use plain FTP anymore. Plain FTP can be
enabled explicitly with `tls => false`, primarily for local testing.

Example
-------

```erlang
rebar3 shell
===> Verifying dependencies...
===> Analyzing applications...
===> Compiling ftpfilez
Erlang/OTP 23 [erts-11.1] [source] [64-bit] [smp:12:12] [ds:12:12:10] [async-threads:1] [hipe]

Eshell V11.1  (abort with ^G)
1> application:ensure_all_started(ftpfilez).
{ok,[jobs,ftpfilez]}
2> Cfg = #{ username => <<"anonymous">>, password => <<"test@example.com">> }.
{<<"anonymous">>, <<"test@example.com">>}
3> ftpfilez:put(Cfg, <<"ftps://ftp.example.com/LICENSE">>, {filename, "LICENSE"}).
ok
4> ftpfilez:stream(Cfg, <<"ftps://ftp.example.com/LICENSE">>, fun(X) -> io:format("!! ~p~n", [X]) end).
!! stream_start
!! <<"\n    Apache License\n", ...>>
!! eof
5> ftpfilez:delete(Cfg, <<"ftps://ftp.example.com/LICENSE">>).
ok
```

Request Queue
-------------

Requests use a shared pool of persistent FTP connections. The pool keeps at most four connections open per server
and queues requests while all four connections for that server are busy. Connections are matched by username and
the other connection settings. When a different username needs a connection, the least recently used idle connection
for that server is selected. The pool first tries to authenticate the existing connection with the new username, so
the TCP/TLS connection remains open when the server supports switching users. If that fails, the connection is closed
and reopened with the new credentials. If all existing connections are busy, the pool opens another connection up to
the per-server limit.

The pool monitors request callers. If a caller stops while its request is queued, that request is removed immediately.
Caller monitors are removed when requests finish.

Connections are checked before and after use. If a server closes an idle connection, its worker reconnects when the
next request needs it. A connection or login failure is returned directly to the caller, and a short
backoff prevents a queued burst from repeatedly attempting the same failing connection.

Idle connections are closed after five minutes. The pool manager performs the close synchronously before processing
another checkout, avoiding a race between idle expiry and connection reuse. The timeout can be configured with the
`connection_idle_timeout_ms` application setting. A synchronous close is limited to five seconds; an unresponsive
connection owner is killed. This limit can be configured with `connection_close_timeout_ms`.

The `get`, `put` and `delete` requests can be queued. A function or pid can be given as a callback for the job result.
The `stream` command can’t be queued: it is already running asynchronously.

Example:

```erlang
6> {ok, ReqId, JobPid} = ftpfilez:queue_put(Cfg, <<"ftps://ftp.example.com/LICENSE">>, {filename, "LICENSE"}, fun(ReqId,Result) -> io:format("!! ~p~n", [ Result ]) end).
{ok,#Ref<0.0.0.3684>,<0.854.0>}
```

The returned `JobPid` is the pid of the process in the ftpfilez queue supervisor.
The callback can be a function (arity 2), `{M,F,A}` or a pid.

If the callback is a pid then it will receive the message `{ftpfilez_done, ReqId, Result}`.

Pool Status
-----------

`ftpfilez:status/0` returns a sanitized snapshot of all connection workers, including their `idle`, `busy`, or
`disconnected` state, host, port, username and TLS mode. It also reports the number of waiting and in-flight requests.
Passwords and TLS options are not included.
