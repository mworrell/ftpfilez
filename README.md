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

**NOTA BENE** This client only supports FTPS, you really shouldn't use plain FTP anymore.

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
2> Cfg = {<<"anonymous">>, <<"test@example.com">>}.
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

Requests can be queued. They will be placed in a supervisor and scheduled using https://github.com/uwiger/jobs
The current scheduler restricts the number of parallel S3 requests. The default maximum is 8.

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

