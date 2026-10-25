{ Operations features of bearings.server, over real sockets through TServer.

  TTestUnixSocket: a listener on a Unix domain socket (TListenSpec.UnixPath):
  requests, pipelining and sendfile over it; the peer record of a Unix
  connection (Family = AF_UNIX, SockAddrToStr = ''); a stale socket file is
  replaced and a regular file at the path is not; the file's mode
  (UnixMode, default &660) and group (UnixGroup; an unknown group fails
  Start and leaves no file); four loops share one socket (amReusePort is
  mapped to amSharedExclusive); Stop removes the file.
  TTestSystemd (bearings.rt.sd): a child process started with a listening
  socket as descriptor 3 and LISTEN_PID / LISTEN_FDS set serves on it
  (ApplySdListenFds, TListenSpec.InheritedFd); LISTEN_FDS of another pid
  is ignored and the variables are removed; a descriptor that is not a
  listening socket fails Start; an inherited socket plus a Unix socket in
  AlsoListen, served by every loop; READY=1 and STOPPING=1 on a path and
  on an abstract NOTIFY_SOCKET; the watchdog heartbeat (WATCHDOG_USEC),
  which stops while a loop is blocked in a handler and resumes after.
  TTestConnLimit (TServerConfig.MaxConnections): with a limit of two the
  third connection waits in the accept queue and is served when one closes;
  four loops at the limit resume their listeners when connections close on
  another loop; an upgraded connection holds its slot until its stream
  closes; the count is zero after Stop.
  TTestAccessLog (TServerConfig.AccessLog): JSON lines for a normal, an
  error, a HEAD and an HTTP/1.0 request (fields, escapes, the query); the
  response's X-Request-ID in the JSON line; the Combined format; a sink that sleeps does not slow the loop, lines are
  dropped and counted. TTestMetrics (TServerConfig.Metrics): counts after a
  known sequence (requests, status classes, bytes, the histogram, closed
  connections by outcome including a parse error, in flight during a slow
  request); the latency buckets; the Prometheus text for a known snapshot
  (exact) and from a running server.
  Run: test_server_ops --all --format=plain }
program test_server_ops;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, StrUtils, fpcunit, testregistry, consoletestrunner, Sockets, BaseUnix,
  ctypes, bearings.rt.sys, bearings.rt.buf, bearings.rt.loop, bearings.rt.net, bearings.rt.sd, bearings.rt.stream, bearings.http.headers,
  bearings.http.exchange, bearings.http1.config, bearings.http.error, bearings.server, bearings.server.metrics,
  bearings.server.accesslog;

const
  CRLF = #13#10;
  O_CLOEXEC = $80000;

type
  { ---- the service: one call object per request ---- }
  TOpsCall = class(TServiceCall)
  public
    Path: RawByteString;
    Timer: TWakeTimer;
    function Poll(Ex: TExchange): TCallPoll; override;
    procedure Drop(Ex: TExchange; Completed: Boolean); override;
  end;

  TOpsService = class(THttpService)
  public
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TOpsApp = class
  public
    function NewService(Loop: TLoop): THttpService;
  end;

var
  FilePath: string;
  Content: RawByteString;
  Calls, Answered: LongInt;
  App: TOpsApp;

function PatternBytes(N: Integer; Seed: Integer): RawByteString;
var
  I: Integer;
begin
  SetLength(Result, N);
  for I := 1 to N do
    Result[I] := AnsiChar(Ord('a') + ((I * 7 + Seed) mod 26));
end;

procedure WriteFileBytes(const Path: string; const S: RawByteString);
var
  Fd: cint;
begin
  Fd := FpOpen(Path, O_WRONLY or O_CREAT or O_TRUNC, &600);
  if Fd < 0 then
    raise Exception.Create('cannot create ' + Path);
  if FpWrite(Fd, S[1], Length(S)) <> Length(S) then
    raise Exception.Create('cannot write ' + Path);
  FpClose(Fd);
end;

function TOpsCall.Poll(Ex: TExchange): TCallPoll;
var
  Fd: cint;
begin
  if Path = '/slow' then
  begin
    if not Timer.Fired then
    begin
      if Timer.Target = nil then
        Timer.Arm(Ex, 100);
      Exit(cpPending);
    end;
    Ex.Respond(BodyString('slow'));
  end
  else if Path = '/small' then
    Ex.Respond(BodyString('small'))
  else if Path = '/rid' then
  begin
    { the request ID an application sends back, with a byte to escape }
    Ex.ResponseHeaders.Add('X-Request-ID', 'abc-"1"');
    Ex.Respond(BodyString('rid'));
  end
  else if Path = '/file' then
  begin
    Fd := FpOpen(FilePath, O_RDONLY or O_CLOEXEC);
    Ex.Respond(BodyFile(Fd, 0, Length(Content), True));
  end
  else if Path = '/block' then
  begin
    { blocks the loop thread on purpose (the watchdog test) }
    Sleep(1500);
    Ex.Respond(BodyString('blocked'));
  end
  else if Path = '/peer' then
    { the peer record as text: family and address }
    Ex.Respond(BodyString(IntToStr(Ex.PeerAddr^.Family) + ':' + SockAddrToStr(Ex.PeerAddr^)))
  else
  begin
    Ex.Status := 404;
    Ex.Respond(BodyEmpty);
  end;
  InterLockedIncrement(Answered);
  Result := cpReady;
end;

procedure TOpsCall.Drop(Ex: TExchange; Completed: Boolean);
begin
  Timer.Cancel(Ex);
  Free;
end;

function TOpsService.Call(Ex: TExchange): TServiceCall;
var
  C: TOpsCall;
  P: TByteSlice;
begin
  InterLockedIncrement(Calls);
  C := TOpsCall.Create;
  P := Ex.Path;
  SetString(C.Path, PAnsiChar(P.P), P.Len);
  Result := C;
end;

function TOpsApp.NewService(Loop: TLoop): THttpService;
begin
  Result := TOpsService.Create;
end;

{ ---- client helpers ---- }

function TryConnect(Port: Word; out Fd: cint): cint;
var
  A: TInetSockAddr;
begin
  Fd := fpSocket(AF_INET, SOCK_STREAM, 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  A.sin_addr.s_addr := htonl($7F000001);
  if fpConnect(Fd, @A, SizeOf(A)) = 0 then
    Exit(0);
  Result := fpgeterrno;
  fpClose(Fd);
  Fd := -1;
end;

function Connect(Port: Word): cint;
begin
  if TryConnect(Port, Result) <> 0 then
    raise Exception.Create('connect failed');
end;

function TryConnectUnix(const Path: RawByteString; out Fd: cint): cint;
var
  A: TSockAddrStorage;
  L: Cardinal;
begin
  Fd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if not MakeUnixSockAddr(Path, A, L) then
    raise Exception.Create('bad unix path');
  if fpConnect(Fd, @A, L) = 0 then
    Exit(0);
  Result := fpgeterrno;
  fpClose(Fd);
  Fd := -1;
end;

function ConnectUnix(const Path: RawByteString): cint;
var
  E: cint;
begin
  E := TryConnectUnix(Path, Result);
  if E <> 0 then
    raise Exception.CreateFmt('connect to %s failed: errno %d', [Path, E]);
end;

procedure SendAll(Fd: cint; const S: RawByteString);
begin
  if fpSend(Fd, PAnsiChar(S), Length(S), MSG_NOSIGNAL) <> Length(S) then
    raise Exception.Create('send failed');
end;

procedure SetRecvTimeout(Fd: cint; Sec: Integer);
var
  TV: TTimeVal;
begin
  TV.tv_sec := Sec;
  TV.tv_usec := 0;
  fpSetSockOpt(Fd, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
end;

{ reads until Marker was seen (Marker = '': until EOF), EOF, an error or 5 s }
function RecvUntil(Fd: cint; const Marker: RawByteString; out Eof: Boolean): RawByteString;
var
  Buf: array[0..65535] of AnsiChar;
  R: ssize_t;
  S: RawByteString;
begin
  Result := '';
  Eof := False;
  SetRecvTimeout(Fd, 5);
  while (Marker = '') or (Pos(Marker, Result) = 0) do
  begin
    R := fpRecv(Fd, @Buf[0], SizeOf(Buf), 0);
    if R <= 0 then
    begin
      Eof := R = 0;
      Exit;
    end;
    SetString(S, PAnsiChar(@Buf[0]), R);
    Result := Result + S;
  end;
end;

{ reads exactly N bytes (fewer on EOF, an error or 10 s) }
function RecvBytes(Fd: cint; N: SizeInt): RawByteString;
var
  Got: SizeInt;
  R: ssize_t;
begin
  SetLength(Result, N);
  Got := 0;
  SetRecvTimeout(Fd, 10);
  while Got < N do
  begin
    R := fpRecv(Fd, @Result[Got + 1], N - Got, 0);
    if R <= 0 then
      Break;
    Inc(Got, R);
  end;
  SetLength(Result, Got);
end;

function Get(const Path: string): RawByteString;
begin
  Result := 'GET ' + Path + ' HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF;
end;

function Resp(const Body: RawByteString): RawByteString;
begin
  Result := 'HTTP/1.1 200 OK' + CRLF + 'content-length: ' + IntToStr(Length(Body)) + CRLF + CRLF
    + Body;
end;

{ one request on an open connection; the whole response (head and body) }
function GetOnce(Fd: cint; const Path: string): RawByteString;
var
  Eof: Boolean;
  HeadEnd, I, Len, Have: Integer;
begin
  SendAll(Fd, Get(Path));
  Result := RecvUntil(Fd, CRLF + CRLF, Eof);
  HeadEnd := Pos(CRLF + CRLF, Result);
  if HeadEnd = 0 then
    Exit;
  I := Pos('content-length: ', Result);
  if (I = 0) or (I > HeadEnd) then
    Exit;
  Len := StrToInt(Copy(Result, I + 16, Pos(CRLF, Copy(Result, I + 16, 20)) - 1));
  Have := Length(Result) - (HeadEnd + 3);
  if Have < Len then
    Result := Result + RecvBytes(Fd, Len - Have);
end;

function TestConfig(Loops: Integer): TServerConfig;
begin
  Result := BenchmarkServerConfig;
  Result.Listen.Host := '127.0.0.1';
  Result.Listen.Port := 0;
  Result.Loops := Loops;
  Result.H1.AutoDateHeader := False;
  Result.GraceMs := 5000;
end;

function SockPath(const Tag: string): RawByteString;
begin
  { under /tmp: a Unix socket path must stay short (UNIX_PATH_MAX) }
  Result := '/tmp/be-ops-' + Tag + '-' + IntToStr(FpGetPid) + '.sock';
end;

function UnixConfig(Loops: Integer; const Path: RawByteString): TServerConfig;
begin
  Result := TestConfig(Loops);
  Result.Listen.UnixPath := Path;
end;

function FileMode(const Path: RawByteString; out Mode: Cardinal; out Gid: Cardinal): Boolean;
var
  St: Stat;
begin
  Result := FpLStat(PAnsiChar(Path), St) = 0;
  if Result then
  begin
    Mode := St.st_mode and &777;
    Gid := St.st_gid;
  end
  else
  begin
    Mode := 0;
    Gid := 0;
  end;
end;

function IsSocketFile(const Path: RawByteString): Boolean;
var
  St: Stat;
begin
  Result := (FpLStat(PAnsiChar(Path), St) = 0) and fpS_ISSOCK(St.st_mode);
end;

{ libc getgrgid: the name of the group Gid (struct group's first field) }
function getgrgid(Gid: Cardinal): PPAnsiChar; cdecl; external 'c';

function GroupName(Gid: Cardinal): RawByteString;
var
  G: PPAnsiChar;
begin
  G := getgrgid(Gid);
  if G = nil then
    Exit('');
  Result := G^;
end;

procedure InitFiles;
begin
  if Content <> '' then
    Exit;
  FilePath := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'be-ops-file-' + IntToStr(FpGetPid);
  Content := PatternBytes(20000, 3);
  WriteFileBytes(FilePath, Content);
end;

procedure DoneFiles;
begin
  if FilePath <> '' then
    DeleteFile(FilePath);
end;

type
  TServerCase = class(TTestCase)
  protected
    Srv: TServer;
    procedure StartServer(const Cfg: TServerConfig);
    procedure StopServer;
    procedure SetUp; override;
    procedure TearDown; override;
  end;

  TTestUnixSocket = class(TServerCase)
  published
    procedure Serves_requests_over_a_unix_socket;
    procedure Stale_socket_file_is_replaced_but_a_regular_file_is_not;
    procedure Socket_file_mode_and_group;
    procedure Four_loops_share_the_socket;
    procedure Stop_removes_the_socket_file;
  end;

  TTestSystemd = class(TServerCase)
  published
    procedure Inherited_socket_from_a_child_process;
    procedure Listen_fds_of_another_process_are_ignored;
    procedure Inherited_descriptor_must_be_a_listening_socket;
    procedure Inherited_socket_in_process_with_also_listen;
    procedure Notify_ready_and_stopping;
    procedure Notify_abstract_socket;
    procedure Watchdog_heartbeat_stops_while_a_loop_is_blocked;
  end;

  TTestConnLimit = class(TServerCase)
  published
    procedure Third_connection_waits_until_one_closes;
    procedure Four_loops_resume_their_listeners;
    procedure Upgraded_connection_counts_until_closed;
    procedure Count_is_zero_after_stop;
  end;

  TTestAccessLog = class(TServerCase)
  published
    procedure Json_lines_for_normal_error_and_head_requests;
    procedure Json_has_the_request_id_of_the_response;
    procedure The_level_is_the_status_one;
    procedure Min_level_drops_the_lines_below_it;
    procedure No_user_agent_or_referer_unless_asked;
    procedure Console_format;
    procedure Console_colors;
    procedure Console_sizes;
    procedure Slow_sink_does_not_block_the_loop;
  end;

  { TH1Config.ProxyProtocol over real sockets, and the lifetime caps }
  TTestProxyAndLifetime = class(TServerCase)
  published
    procedure Proxy_v1_over_tcp_gives_the_client_address;
    procedure Proxy_v2_over_a_unix_socket;
    procedure Connection_without_a_proxy_header_is_closed;
    procedure Max_connection_age_closes_at_the_next_request;
  end;

  TTestMetrics = class(TServerCase)
  published
    procedure Counts_after_a_known_sequence;
    procedure Latency_buckets;
    procedure Prometheus_text_for_a_known_snapshot;
    procedure Prometheus_text_from_a_server;
  end;

procedure TServerCase.StartServer(const Cfg: TServerConfig);
begin
  Srv := TServer.Create(Cfg, @App.NewService);
  Srv.Start;
end;

procedure TServerCase.StopServer;
begin
  if Srv <> nil then
  begin
    Srv.Stop(1000);
    Srv.Wait;
    FreeAndNil(Srv);
  end;
end;

procedure TServerCase.SetUp;
begin
  InitFiles;
  Calls := 0;
  Answered := 0;
  Srv := nil;
end;

procedure TServerCase.TearDown;
begin
  StopServer;
end;

{ ---- Unix domain socket ---- }

procedure TTestUnixSocket.Serves_requests_over_a_unix_socket;
var
  P: RawByteString;
  Fd: cint;
  Got: RawByteString;
  I: Integer;
begin
  P := SockPath('serve');
  StartServer(UnixConfig(1, P));
  AssertEquals('no TCP port', 0, Srv.Port);
  AssertTrue('the socket file exists', IsSocketFile(P));
  Fd := ConnectUnix(P);
  try
    AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
    { the peer record of a Unix connection: AF_UNIX, no address }
    AssertEquals(Resp(IntToStr(AF_UNIX) + ':'), GetOnce(Fd, '/peer'));
    { sendfile over a Unix stream socket }
    AssertEquals(Resp(Content), GetOnce(Fd, '/file'));
    { pipelining }
    SendAll(Fd, Get('/small') + Get('/small') + Get('/small'));
    Got := RecvBytes(Fd, 3 * Length(Resp('small')));
    AssertEquals(Resp('small') + Resp('small') + Resp('small'), Got);
  finally
    fpClose(Fd);
  end;
  { several connections in a row }
  for I := 1 to 20 do
  begin
    Fd := ConnectUnix(P);
    try
      AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
    finally
      fpClose(Fd);
    end;
  end;
  AssertEquals('calls', 26, Calls);
  StopServer;
  AssertFalse('the socket file is gone after Stop', FileExists(P));
  AssertTrue('connect fails after Stop', TryConnectUnix(P, Fd) = ESysENOENT);
end;

procedure TTestUnixSocket.Stale_socket_file_is_replaced_but_a_regular_file_is_not;
var
  P: RawByteString;
  A: TSockAddrStorage;
  L: Cardinal;
  S, Fd: cint;
  Raised: Boolean;
begin
  P := SockPath('stale');
  { a socket file left behind by a process that did not clean up }
  S := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  MakeUnixSockAddr(P, A, L);
  AssertEquals('bind the stale socket', 0, fpBind(S, @A, L));
  fpClose(S);
  AssertTrue('the stale file exists', IsSocketFile(P));
  StartServer(UnixConfig(1, P));
  Fd := ConnectUnix(P);
  try
    AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
  finally
    fpClose(Fd);
  end;
  StopServer;
  AssertFalse(FileExists(P));
  { a regular file at the path is not touched: Start fails with EADDRINUSE }
  WriteFileBytes(P, 'not a socket');
  Raised := False;
  Srv := TServer.Create(UnixConfig(1, P), @App.NewService);
  try
    Srv.Start;
  except
    on E: EServerError do
    begin
      Raised := True;
      AssertTrue('EADDRINUSE: ' + E.Message, Pos('errno ' + IntToStr(ESysEADDRINUSE), E.Message) > 0);
    end;
  end;
  AssertTrue('Start raised', Raised);
  FreeAndNil(Srv);
  AssertTrue('the regular file is still there', FileExists(P) and not IsSocketFile(P));
  DeleteFile(P);
end;

procedure TTestUnixSocket.Socket_file_mode_and_group;
var
  P, G: RawByteString;
  Cfg: TServerConfig;
  Mode, Gid: Cardinal;
  Raised: Boolean;
begin
  P := SockPath('mode');
  { the default mode: owner and group }
  StartServer(UnixConfig(1, P));
  AssertTrue(FileMode(P, Mode, Gid));
  AssertEquals('default mode', &660, Mode);
  StopServer;
  { an explicit mode }
  Cfg := UnixConfig(1, P);
  Cfg.Listen.UnixMode := &600;
  StartServer(Cfg);
  AssertTrue(FileMode(P, Mode, Gid));
  AssertEquals('UnixMode', &600, Mode);
  StopServer;
  { the group: the process's own effective group (always allowed) }
  G := GroupName(fpGetEgid);
  if G <> '' then
  begin
    Cfg := UnixConfig(1, P);
    Cfg.Listen.UnixGroup := G;
    StartServer(Cfg);
    AssertTrue(FileMode(P, Mode, Gid));
    AssertEquals('group ' + G, fpGetEgid, Gid);
    StopServer;
  end;
  { an unknown group: Start fails and leaves no socket file }
  Cfg := UnixConfig(1, P);
  Cfg.Listen.UnixGroup := 'no-such-group-bearings-test';
  Raised := False;
  Srv := TServer.Create(Cfg, @App.NewService);
  try
    Srv.Start;
  except
    on E: EServerError do
    begin
      Raised := True;
      AssertTrue('EINVAL: ' + E.Message, Pos('errno ' + IntToStr(ESysEINVAL), E.Message) > 0);
    end;
  end;
  AssertTrue('Start raised', Raised);
  FreeAndNil(Srv);
  AssertFalse('no socket file', FileExists(P));
end;

procedure TTestUnixSocket.Four_loops_share_the_socket;
var
  P: RawByteString;
  Cfg: TServerConfig;
  Fds: array[0..31] of cint;
  I: Integer;
begin
  P := SockPath('four');
  Cfg := UnixConfig(4, P);
  Cfg.Listen.Mode := amReusePort;    { mapped to amSharedExclusive }
  StartServer(Cfg);
  AssertEquals(4, Srv.LoopCount);
  for I := 0 to 3 do
    AssertTrue('loop ' + IntToStr(I) + ' listens', Srv.Loops[I].Listener <> nil);
  { 32 connections open at once, then one request each }
  for I := 0 to 31 do
    Fds[I] := ConnectUnix(P);
  try
    for I := 0 to 31 do
      AssertEquals(Resp('small'), GetOnce(Fds[I], '/small'));
  finally
    for I := 0 to 31 do
      fpClose(Fds[I]);
  end;
  AssertEquals(32, Calls);
  StopServer;
  AssertFalse('the socket file is gone', FileExists(P));
end;

procedure TTestUnixSocket.Stop_removes_the_socket_file;
var
  P: RawByteString;
begin
  P := SockPath('stop');
  StartServer(UnixConfig(2, P));
  AssertTrue(IsSocketFile(P));
  Srv.Stop(1000);
  Srv.Wait;
  AssertFalse('removed by loop 0 during Stop', FileExists(P));
  FreeAndNil(Srv);
  { Destroy without Stop also removes it }
  StartServer(UnixConfig(2, P));
  AssertTrue(IsSocketFile(P));
  FreeAndNil(Srv);
  AssertFalse('removed by Destroy', FileExists(P));
end;

{ ---- systemd: socket activation, notify, watchdog ---- }

function setenv(Name, Value: PAnsiChar; Overwrite: cint): cint; cdecl; external 'c';
function unsetenv(Name: PAnsiChar): cint; cdecl; external 'c';
function execv(Path: PAnsiChar; Argv: PPAnsiChar): cint; cdecl; external 'c';
function getenv(Name: PAnsiChar): PAnsiChar; cdecl; external 'c';

{ libc's environment (what setenv changed), not the RTL's copy }
function EnvVar(const Name: RawByteString): RawByteString;
var
  P: PAnsiChar;
begin
  P := getenv(PAnsiChar(Name));
  if P = nil then
    Result := ''
  else
    Result := P;
end;

procedure SetEnv(const Name, Value: RawByteString);
begin
  setenv(PAnsiChar(Name), PAnsiChar(Value), 1);
end;

procedure UnsetEnv(const Name: RawByteString);
begin
  unsetenv(PAnsiChar(Name));
end;

{ a Unix datagram socket bound at Path (an abstract name when it starts
  with '@'), and NOTIFY_SOCKET set to it: receives what SdNotify sends }
function OpenNotifySink(const Path: RawByteString): cint;
var
  A: TSockAddrStorage;
  L: Cardinal;
begin
  Result := fpSocket(AF_UNIX, SOCK_DGRAM, 0);
  FillChar(A, SizeOf(A), 0);
  A.Family := AF_UNIX;
  Move(Path[1], A.Data[0], Length(Path));
  L := 2 + Length(Path);
  if Path[1] = '@' then
    A.Data[0] := 0
  else
  begin
    Inc(L);
    FpUnlink(PAnsiChar(Path));
  end;
  if fpBind(Result, @A, L) <> 0 then
    raise Exception.CreateFmt('bind notify sink %s: errno %d', [Path, fpgeterrno]);
  SetEnv('NOTIFY_SOCKET', Path);
end;

procedure CloseNotifySink(Fd: cint; const Path: RawByteString);
begin
  UnsetEnv('NOTIFY_SOCKET');
  fpClose(Fd);
  if Path[1] <> '@' then
    FpUnlink(PAnsiChar(Path));
end;

{ one datagram, or '' after TimeoutMs }
function RecvNotify(Fd: cint; TimeoutMs: Integer): RawByteString;
var
  TV: TTimeVal;
  Buf: array[0..1023] of AnsiChar;
  R: ssize_t;
begin
  TV.tv_sec := TimeoutMs div 1000;
  TV.tv_usec := (TimeoutMs mod 1000) * 1000;
  fpSetSockOpt(Fd, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
  R := fpRecv(Fd, @Buf[0], SizeOf(Buf), 0);
  if R <= 0 then
    Exit('');
  SetString(Result, PAnsiChar(@Buf[0]), R);
end;

{ datagrams received until TimeoutMs of silence; counts those starting with Msg }
function CountNotify(Fd: cint; const Msg: RawByteString; TimeoutMs: Integer): Integer;
var
  S: RawByteString;
begin
  Result := 0;
  repeat
    S := RecvNotify(Fd, TimeoutMs);
    if Pos(Msg, S) = 1 then
      Inc(Result);
  until S = '';
end;

procedure ChildStarted(S: TServer);
begin
  WriteLn('PORT ', S.Port);
  Flush(Output);
end;

{ the child of Inherited_socket_from_a_child_process: the server listens on
  the socket systemd (here: the parent) passed as descriptor 3 }
procedure RunSdChild;
var
  Cfg: TServerConfig;
  S: TServer;
  N: Integer;
begin
  App := TOpsApp.Create;
  Cfg := TestConfig(2);
  N := ApplySdListenFds(Cfg);
  WriteLn('FDS ', N, ' LISTEN_FDS=', EnvVar('LISTEN_FDS'), ' LISTEN_PID=',
    EnvVar('LISTEN_PID'));
  Flush(Output);
  S := TServer.Create(Cfg, @App.NewService);
  S.RunUntilSignalProc(@ChildStarted);   { prints PORT }
  WriteLn('CALLS ', Calls);
  Flush(Output);
  S.Free;
  App.Free;
end;

procedure TTestSystemd.Inherited_socket_from_a_child_process;
var
  Sock, Fd, Status: cint;
  A: TInetSockAddr;
  L: TSockLen;
  P: TFilDes;
  Pid: TPid;
  Args: array[0..3] of PAnsiChar;
  I: Integer;
  Outp, Got: RawByteString;
  Buf: array[0..255] of AnsiChar;
  N: LongInt;
  T0: QWord;
  Exe, Runner: RawByteString;
begin
  { the "systemd" side: a listening socket, passed as descriptor 3 }
  Sock := fpSocket(AF_INET, SOCK_STREAM, 0);
  A.sin_family := AF_INET;
  A.sin_port := 0;
  A.sin_addr.s_addr := htonl($7F000001);
  AssertEquals('bind', 0, fpBind(Sock, @A, SizeOf(A)));
  AssertEquals('listen', 0, fpListen(Sock, 16));
  L := SizeOf(A);
  fpGetSockName(Sock, @A, @L);
  AssertEquals('pipe', 0, FpPipe(P));
  Exe := ParamStr(0);
  Pid := FpFork;
  if Pid = 0 then
  begin
    { the child: descriptor 3 is the socket, stdout the pipe }
    FpDup2(Sock, 3);
    FpDup2(P[1], 1);
    fpClose(P[0]);
    fpClose(P[1]);
    if Sock <> 3 then
      fpClose(Sock);
    SetEnv('LISTEN_PID', IntToStr(FpGetPid));
    SetEnv('LISTEN_FDS', '1');
    SetEnv('LISTEN_FDNAMES', 'http');
    SetEnv('HEAPTRC', 'log=/dev/null');   { a -gh build: the child's heap report must not land in the parent's log or output }
    { under an emulator (TARGET=aarch64 in tests/unit/run_all.sh) the child
      is started through the runner named by BEARINGS_RUNNER; it keeps the
      pid (LISTEN_PID) and descriptor 3 }
    Runner := GetEnvironmentVariable('BEARINGS_RUNNER');
    I := 0;
    if Runner <> '' then
    begin
      Args[I] := PAnsiChar(Runner);
      Inc(I);
    end;
    Args[I] := PAnsiChar(Exe);
    Args[I + 1] := '--sd-child';
    Args[I + 2] := nil;
    { FpExecv would pass the RTL's copy of the environment, taken at start:
      the variables set above would be lost. libc's execv uses libc's. }
    execv(Args[0], @Args[0]);
    FpExit(127);
  end;
  AssertTrue('fork', Pid > 0);
  fpClose(Sock);
  fpClose(P[1]);
  try
    { the child's first two lines: FDS ..., PORT ... }
    Outp := '';
    T0 := GetTickCount64;
    while (Pos('PORT ', Outp) = 0) and (GetTickCount64 - T0 < 10000) do
    begin
      N := fpRead(P[0], Buf[0], SizeOf(Buf));
      if N > 0 then
        Outp := Outp + Copy(Buf, 1, N)
      else
        Break;
    end;
    AssertTrue('the child used the passed socket: ' + Outp,
      Pos('FDS 1 LISTEN_FDS= LISTEN_PID=' + LineEnding, Outp) = 1);
    AssertTrue('the port of the inherited socket: ' + Outp,
      Pos('PORT ' + IntToStr(ntohs(A.sin_port)), Outp) > 0);
    { a client connects to the socket the parent bound }
    Fd := Connect(ntohs(A.sin_port));
    try
      Got := GetOnce(Fd, '/small');
      AssertEquals(Resp('small'), Got);
    finally
      fpClose(Fd);
    end;
    FpKill(Pid, SIGTERM);
    T0 := GetTickCount64;
    repeat
      N := fpRead(P[0], Buf[0], SizeOf(Buf));
      if N > 0 then
        Outp := Outp + Copy(Buf, 1, N);
    until (N <= 0) or (GetTickCount64 - T0 > 10000);
    AssertTrue('the child served the request: ' + Outp, Pos('CALLS 1', Outp) > 0);
    Status := 0;
    AssertEquals('waitpid', Pid, FpWaitPid(Pid, @Status, 0));
    AssertTrue('exit status 0: ' + IntToStr(Status), wifexited(Status) and (wexitstatus(Status) = 0));
  finally
    fpClose(P[0]);
  end;
end;

procedure TTestSystemd.Listen_fds_of_another_process_are_ignored;
var
  Fds: TSdFds;
  Names: TSdNames;
begin
  SetEnv('LISTEN_PID', '1');
  SetEnv('LISTEN_FDS', '2');
  AssertEquals('another pid', 0, SdListenFds(Fds, Names));
  AssertEquals('the variables are removed', '', EnvVar('LISTEN_FDS'));
  AssertEquals('', EnvVar('LISTEN_PID'));
  { this process: the descriptors 3 and 4 and their names }
  SetEnv('LISTEN_PID', IntToStr(FpGetPid));
  SetEnv('LISTEN_FDS', '2');
  SetEnv('LISTEN_FDNAMES', 'http:admin');
  AssertEquals(2, SdListenFds(Fds, Names));
  AssertEquals(3, Fds[0]);
  AssertEquals(4, Fds[1]);
  AssertEquals('http', Names[0]);
  AssertEquals('admin', Names[1]);
  AssertEquals('', EnvVar('LISTEN_FDNAMES'));
  { nothing set }
  AssertEquals(0, SdListenFds(Fds, Names));
end;

procedure TTestSystemd.Inherited_descriptor_must_be_a_listening_socket;
var
  Cfg: TServerConfig;
  Raised: Boolean;
  P: TFilDes;
begin
  FpPipe(P);
  Cfg := TestConfig(1);
  Cfg.Listen.InheritedFd := P[0];
  Raised := False;
  Srv := TServer.Create(Cfg, @App.NewService);
  try
    Srv.Start;
  except
    on E: EServerError do
    begin
      Raised := True;
      AssertTrue(E.Message, Pos('not a listening socket', E.Message) > 0);
    end;
  end;
  AssertTrue('Start raised', Raised);
  FreeAndNil(Srv);
  fpClose(P[0]);
  fpClose(P[1]);
end;

procedure TTestSystemd.Inherited_socket_in_process_with_also_listen;
var
  Sock: cint;
  A: TInetSockAddr;
  L: TSockLen;
  Cfg: TServerConfig;
  Fd: cint;
  UPath: RawByteString;
  I: Integer;
begin
  { a listening socket opened by "someone else", plus a Unix socket: every
    loop serves both }
  Sock := fpSocket(AF_INET, SOCK_STREAM, 0);
  A.sin_family := AF_INET;
  A.sin_port := 0;
  A.sin_addr.s_addr := htonl($7F000001);
  AssertEquals(0, fpBind(Sock, @A, SizeOf(A)));
  AssertEquals(0, fpListen(Sock, 16));
  L := SizeOf(A);
  fpGetSockName(Sock, @A, @L);
  UPath := SockPath('also');
  Cfg := TestConfig(3);
  Cfg.Listen.InheritedFd := Sock;
  SetLength(Cfg.AlsoListen, 1);
  Cfg.AlsoListen[0] := UnixConfig(1, UPath).Listen;
  StartServer(Cfg);
  AssertEquals('Port is the inherited socket''s', ntohs(A.sin_port), Srv.Port);
  for I := 0 to 2 do
  begin
    AssertEquals('listeners per loop', 2, Length(Srv.Loops[I].Listeners));
    AssertTrue(Srv.Loops[I].Listeners[0] <> nil);
    AssertTrue(Srv.Loops[I].Listeners[1] <> nil);
  end;
  for I := 1 to 8 do
  begin
    Fd := Connect(Srv.Port);
    try
      AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
    finally
      fpClose(Fd);
    end;
    Fd := ConnectUnix(UPath);
    try
      AssertEquals(Resp(IntToStr(AF_UNIX) + ':'), GetOnce(Fd, '/peer'));
    finally
      fpClose(Fd);
    end;
  end;
  AssertEquals(16, Calls);
  StopServer;
  AssertFalse('the Unix socket file is removed', FileExists(UPath));
  AssertTrue('the inherited socket is closed', FpFcntl(Sock, F_GETFD) < 0);
end;

procedure TTestSystemd.Notify_ready_and_stopping;
var
  Sink: cint;
  Path, Msg: RawByteString;
begin
  Path := SockPath('notify');
  Sink := OpenNotifySink(Path);
  try
    StartServer(TestConfig(2));
    Msg := RecvNotify(Sink, 2000);
    AssertTrue('READY=1 with a status: ' + Msg,
      (Pos('READY=1' + #10, Msg) = 1) and (Pos('STATUS=listening, 2 loop(s)', Msg) > 0));
    AssertFalse('no watchdog without WATCHDOG_USEC', Srv.WatchdogRunning);
    Srv.Stop(1000);
    Msg := RecvNotify(Sink, 2000);
    AssertEquals('STOPPING=1', Msg);
    Srv.Wait;
    FreeAndNil(Srv);
  finally
    CloseNotifySink(Sink, Path);
  end;
end;

procedure TTestSystemd.Notify_abstract_socket;
var
  Sink: cint;
  Path, Msg: RawByteString;
begin
  Path := '@be-ops-notify-' + IntToStr(FpGetPid);
  Sink := OpenNotifySink(Path);
  try
    StartServer(TestConfig(1));
    Msg := RecvNotify(Sink, 2000);
    AssertTrue('READY=1: ' + Msg, Pos('READY=1', Msg) = 1);
  finally
    CloseNotifySink(Sink, Path);
  end;
end;

procedure TTestSystemd.Watchdog_heartbeat_stops_while_a_loop_is_blocked;
var
  Sink: cint;
  Path, Msg: RawByteString;
  Cfg: TServerConfig;
  Fd: cint;
  N: Integer;
  T0: QWord;
  Eof: Boolean;
begin
  Path := SockPath('wd');
  Sink := OpenNotifySink(Path);
  SetEnv('WATCHDOG_USEC', '400000');           { heartbeat every 200 ms }
  try
    { the pid check: another pid means no watchdog }
    SetEnv('WATCHDOG_PID', '1');
    AssertEquals(0, SdWatchdogUsec);
    SetEnv('WATCHDOG_PID', IntToStr(FpGetPid));
    AssertEquals(400000, SdWatchdogUsec);
    Cfg := TestConfig(2);
    Cfg.Watchdog := True;
    StartServer(Cfg);
    AssertTrue('the watchdog thread runs', Srv.WatchdogRunning);
    Msg := RecvNotify(Sink, 2000);
    AssertTrue('READY first: ' + Msg, Pos('READY=1', Msg) = 1);
    { heartbeats while the loops are idle (the ping wakes them) }
    N := 0;
    T0 := GetTickCount64;
    while (N < 3) and (GetTickCount64 - T0 < 3000) do
      if Pos('WATCHDOG=1', RecvNotify(Sink, 1000)) = 1 then
        Inc(N);
    AssertEquals('three heartbeats within 3 s', 3, N);
    { a handler that blocks its loop for 1.5 s: the heartbeat stops }
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, Get('/block'));
      Sleep(500);                              { the pending ping is now unanswered }
      N := CountNotify(Sink, 'WATCHDOG=1', 100);   { drains what was sent before }
      N := 0;
      T0 := GetTickCount64;
      while GetTickCount64 - T0 < 800 do
        if Pos('WATCHDOG=1', RecvNotify(Sink, 200)) = 1 then
          Inc(N);
      AssertEquals('no heartbeat while a loop is blocked', 0, N);
      Msg := RecvUntil(Fd, 'blocked', Eof);
      AssertTrue('the blocked request is answered: ' + Msg, AnsiEndsStr('blocked', Msg));
    finally
      fpClose(Fd);
    end;
    { the loop runs again: the heartbeat resumes }
    N := 0;
    T0 := GetTickCount64;
    while (N < 2) and (GetTickCount64 - T0 < 3000) do
      if Pos('WATCHDOG=1', RecvNotify(Sink, 1000)) = 1 then
        Inc(N);
    AssertEquals('heartbeats resume', 2, N);
    Srv.Stop(1000);
    Srv.Wait;
    AssertFalse('the thread is joined by Wait', Srv.WatchdogRunning);
    FreeAndNil(Srv);
  finally
    UnsetEnv('WATCHDOG_USEC');
    UnsetEnv('WATCHDOG_PID');
    CloseNotifySink(Sink, Path);
  end;
end;
{ ---- connection limit ---- }

{ an upgrade handler that keeps the stream on the loop and closes it when
  the client closes (EOF) }
type
  TEofCloser = class(TRawListener)
  public
    procedure Readable(U: TUpgraded); override;
  end;

  TAttachHandler = class(TUpgradeHandler)
  public
    Closer: TEofCloser;
    procedure Upgraded(U: TUpgraded); override;
  end;

  TUpCall = class(TServiceCall)
  public
    Handler: TUpgradeHandler;
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TUpService = class(THttpService)
  public
    C: TUpCall;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TUpApp = class
  public
    Handler: TUpgradeHandler;
    function NewService(Loop: TLoop): THttpService;
  end;

const
  UPGRADE_REQ = 'GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: foo' + CRLF +
    'Connection: upgrade' + CRLF + CRLF;

procedure TEofCloser.Readable(U: TUpgraded);
var
  B: array[0..255] of Byte;
  R: SizeInt;
begin
  R := U.TryRead(@B[0], SizeOf(B));
  if (R = 0) or ((R < 0) and (R <> -ESysEAGAIN)) then
    U.Close;
end;

procedure TAttachHandler.Upgraded(U: TUpgraded);
begin
  U.Attach(Closer);
end;

function TUpCall.Poll(Ex: TExchange): TCallPoll;
begin
  Ex.OnUpgrade(Handler);
  Ex.Status := 101;
  Ex.ResponseHeaders.Insert('upgrade', 'foo');
  Ex.ResponseHeaders.Insert('connection', 'upgrade');
  Ex.Respond(BodyEmpty);
  Result := cpReady;
end;

destructor TUpService.Destroy;
begin
  C.Free;
  inherited Destroy;
end;

function TUpService.Call(Ex: TExchange): TServiceCall;
begin
  Result := C;
end;

function TUpApp.NewService(Loop: TLoop): THttpService;
var
  S: TUpService;
begin
  S := TUpService.Create;
  S.C := TUpCall.Create;
  S.C.Handler := Handler;
  Result := S;
end;

{ True when Fd has no bytes to read within Ms }
function Silent(Fd: cint; Ms: Integer): Boolean;
var
  TV: TTimeVal;
  B: array[0..15] of Byte;
begin
  TV.tv_sec := Ms div 1000;
  TV.tv_usec := (Ms mod 1000) * 1000;
  fpSetSockOpt(Fd, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
  Result := fpRecv(Fd, @B[0], SizeOf(B), MSG_PEEK) < 0;
end;

{ waits up to 2 s for the server's counted connections to reach N }
function WaitCounted(Srv: TServer; N: Integer): Boolean;
var
  T0: QWord;
begin
  T0 := GetTickCount64;
  while (Srv.CountedConnections <> N) and (GetTickCount64 - T0 < 2000) do
    Sleep(2);
  Result := Srv.CountedConnections = N;
end;

procedure TTestConnLimit.Third_connection_waits_until_one_closes;
var
  Cfg: TServerConfig;
  A, B, C: cint;
  T0: QWord;
begin
  Cfg := TestConfig(1);
  Cfg.MaxConnections := 2;
  StartServer(Cfg);
  A := Connect(Srv.Port);
  B := Connect(Srv.Port);
  AssertEquals(Resp('small'), GetOnce(A, '/small'));
  AssertEquals(Resp('small'), GetOnce(B, '/small'));
  AssertTrue('two counted', WaitCounted(Srv, 2));
  { the third connection is completed by the kernel (it waits in the accept
    queue) but not served }
  C := Connect(Srv.Port);
  SendAll(C, Get('/small'));
  AssertTrue('the third connection gets no answer', Silent(C, 300));
  AssertEquals('still two', 2, Srv.CountedConnections);
  AssertTrue('the listener is paused by the limit', Srv.Loops[0].Listener.LimitPaused);
  fpClose(A);
  { the slot goes back and the listener resumes: C is served; the count is
    at the limit again, so the listener's next accept try pauses it again }
  AssertEquals(Resp('small'), RecvBytes(C, Length(Resp('small'))));
  AssertEquals('two counted again', 2, Srv.CountedConnections);
  AssertEquals('limit pauses counted', 2, Srv.Loops[0].Listener.LimitPauses);
  fpClose(B);
  fpClose(C);
  AssertTrue('none left', WaitCounted(Srv, 0));
  T0 := GetTickCount64;
  while Srv.Loops[0].Listener.LimitPaused and (GetTickCount64 - T0 < 2000) do
    Sleep(2);
  AssertFalse('the listener accepts again', Srv.Loops[0].Listener.LimitPaused);
  AssertEquals(3, Calls);
end;

procedure TTestConnLimit.Four_loops_resume_their_listeners;
var
  Cfg: TServerConfig;
  Held: array[0..3] of cint;
  Waiting: array[0..11] of cint;
  I, Pauses, Served: Integer;
  T0: QWord;
begin
  Cfg := TestConfig(4);
  Cfg.MaxConnections := 4;
  StartServer(Cfg);
  for I := 0 to 3 do
  begin
    Held[I] := Connect(Srv.Port);
    AssertEquals(Resp('small'), GetOnce(Held[I], '/small'));
  end;
  AssertTrue('four counted', WaitCounted(Srv, 4));
  { twelve more wait in the accept queues of the four listeners }
  for I := 0 to 11 do
  begin
    Waiting[I] := Connect(Srv.Port);
    SendAll(Waiting[I], Get('/small'));
  end;
  Sleep(300);
  AssertEquals('none of them was accepted', 4, Calls);
  Pauses := 0;
  for I := 0 to 3 do
    Inc(Pauses, Srv.Loops[I].Listener.LimitPauses);
  AssertTrue('listeners paused by the limit', Pauses > 0);
  { closing the held connections lets the waiting ones through, whichever
    loop they wait on: each close resumes every loop's listener. Only four
    can be served at a time, so each served one is closed as soon as its
    response is read, in whatever order they come }
  for I := 0 to 3 do
    fpClose(Held[I]);
  Served := 0;
  T0 := GetTickCount64;
  while (Served < 12) and (GetTickCount64 - T0 < 10000) do
    for I := 0 to 11 do
      if (Waiting[I] >= 0) and not Silent(Waiting[I], 20) then
      begin
        AssertEquals('waiting connection ' + IntToStr(I), Resp('small'),
          RecvBytes(Waiting[I], Length(Resp('small'))));
        fpClose(Waiting[I]);
        Waiting[I] := -1;
        Inc(Served);
      end;
  AssertEquals('every waiting connection was served', 12, Served);
  AssertEquals(16, Calls);
  AssertTrue('all slots back', WaitCounted(Srv, 0));
  for I := 0 to 3 do
    AssertFalse('loop ' + IntToStr(I) + ' listener resumed', Srv.Loops[I].Listener.LimitPaused);
end;

procedure TTestConnLimit.Upgraded_connection_counts_until_closed;
var
  UA: TUpApp;
  H: TAttachHandler;
  Cfg: TServerConfig;
  A, B: cint;
  Head: RawByteString;
  Eof: Boolean;
begin
  UA := TUpApp.Create;
  H := TAttachHandler.Create;
  H.Closer := TEofCloser.Create;
  UA.Handler := H;
  Cfg := TestConfig(1);
  Cfg.H1.Mode := cmWithUpgrades;
  Cfg.MaxConnections := 1;
  Srv := TServer.Create(Cfg, @UA.NewService);
  try
    Srv.Start;
    A := Connect(Srv.Port);
    SendAll(A, UPGRADE_REQ);
    Head := RecvUntil(A, CRLF + CRLF, Eof);
    AssertTrue('101: ' + Head, AnsiStartsStr('HTTP/1.1 101 Switching Protocols', Head));
    Sleep(50);
    AssertEquals('the upgraded connection holds its slot', 1, Srv.CountedConnections);
    AssertEquals('the HTTP connection list no longer has it', 0, Srv.OpenConnections);
    B := Connect(Srv.Port);
    SendAll(B, UPGRADE_REQ);
    AssertTrue('the second connection waits', Silent(B, 300));
    fpClose(A);                      { EOF: the handler closes the stream, the slot goes back }
    Head := RecvUntil(B, CRLF + CRLF, Eof);
    AssertTrue('the second connection is served: ' + Head, AnsiStartsStr('HTTP/1.1 101', Head));
    fpClose(B);
    AssertTrue(WaitCounted(Srv, 0));
    Srv.Stop(1000);
    Srv.Wait;
  finally
    FreeAndNil(Srv);
    H.Closer.Free;
    H.Free;
    UA.Free;
  end;
end;

procedure TTestConnLimit.Count_is_zero_after_stop;
var
  Cfg: TServerConfig;
  Fds: array[0..2] of cint;
  I: Integer;
  Eof: Boolean;
begin
  Cfg := TestConfig(2);
  Cfg.MaxConnections := 3;
  StartServer(Cfg);
  for I := 0 to 2 do
  begin
    Fds[I] := Connect(Srv.Port);
    AssertEquals(Resp('small'), GetOnce(Fds[I], '/small'));
  end;
  AssertTrue(WaitCounted(Srv, 3));
  { idle keep-alive connections are closed by the stop }
  Srv.Stop(1000);
  Srv.Wait;
  for I := 0 to 2 do
  begin
    RecvUntil(Fds[I], '', Eof);
    AssertTrue('closed by the server', Eof);
    fpClose(Fds[I]);
  end;
  AssertEquals('every slot went back', 0, Srv.CountedConnections);
end;
{ ---- access log and metrics ---- }

type
  { collects the lines; SlowMs > 0 makes every Write take that long }
  TMemSink = class(TLogSink)
  public
    Lock: TRTLCriticalSection;
    Text: RawByteString;
    Writes: Integer;
    SlowMs: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Write(P: PByte; Len: SizeInt); override;
    function Lines: TStringList;     { the caller frees it }
  end;

constructor TMemSink.Create;
begin
  inherited Create;
  InitCriticalSection(Lock);
end;

destructor TMemSink.Destroy;
begin
  DoneCriticalSection(Lock);
  inherited Destroy;
end;

procedure TMemSink.Write(P: PByte; Len: SizeInt);
var
  S: RawByteString;
begin
  if SlowMs > 0 then
    Sleep(SlowMs);
  SetString(S, PAnsiChar(P), Len);
  EnterCriticalSection(Lock);
  Text := Text + S;
  Inc(Writes);
  LeaveCriticalSection(Lock);
end;

function TMemSink.Lines: TStringList;
begin
  Result := TStringList.Create;
  EnterCriticalSection(Lock);
  Result.Text := Text;
  LeaveCriticalSection(Lock);
end;

function LogConfig(Loops: Integer; Sink: TLogSink; Format: TAccessLogFormat): TServerConfig;
begin
  Result := TestConfig(Loops);
  Result.AccessLog.Enabled := True;
  Result.AccessLog.Format := Format;
  Result.AccessLog.Sink := Sink;
  Result.AccessLog.UserAgent := True;
  Result.AccessLog.Referer := True;
  Result.Metrics := True;
end;

{ the value of "key":value in a JSON line (a string without its quotes, or
  a bare number); '' when absent }
function JsonField(const Line, Key: RawByteString): RawByteString;
var
  I, J: Integer;
begin
  I := Pos('"' + Key + '":', Line);
  if I = 0 then
    Exit('');
  I := I + Length(Key) + 3;
  if Line[I] = '"' then
  begin
    J := I + 1;
    while (J <= Length(Line)) and (Line[J] <> '"') do
    begin
      if Line[J] = '\' then
        Inc(J);
      Inc(J);
    end;
    Result := Copy(Line, I + 1, J - I - 1);
  end
  else
  begin
    J := I;
    while (J <= Length(Line)) and (Line[J] in ['0'..'9', '.', '-']) do
      Inc(J);
    Result := Copy(Line, I, J - I);
  end;
end;

procedure TTestAccessLog.Json_lines_for_normal_error_and_head_requests;
var
  Sink: TMemSink;
  Fd: cint;
  Eof: Boolean;
  L: TStringList;
  Got: RawByteString;
begin
  Sink := TMemSink.Create;
  try
    StartServer(LogConfig(1, Sink, alfJson));
    Fd := Connect(Srv.Port);
    try
      AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
      SendAll(Fd, 'GET /nope?x=1&y=2 HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'User-Agent: t"e\st/1.0' + CRLF
        + 'Referer: http://x/from' + CRLF + CRLF);
      Got := RecvUntil(Fd, CRLF + CRLF, Eof);
      AssertTrue('404: ' + Got, AnsiStartsStr('HTTP/1.1 404', Got));
      SendAll(Fd, 'HEAD /small HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
      Got := RecvUntil(Fd, CRLF + CRLF, Eof);
      AssertTrue('HEAD 200: ' + Got, AnsiStartsStr('HTTP/1.1 200', Got) and (Pos('content-length: 5', Got) > 0));
      SendAll(Fd, 'GET /small HTTP/1.0' + CRLF + CRLF);
      Got := RecvUntil(Fd, '', Eof);
      AssertTrue('HTTP/1.0 closes', Eof and AnsiStartsStr('HTTP/1.0 200', Got));
    finally
      fpClose(Fd);
    end;
    StopServer;                      { Wait flushes the last lines }
    L := Sink.Lines;
    try
      AssertEquals('four lines: ' + Sink.Text, 4, L.Count);
      { 1: a normal GET }
      AssertEquals('info', JsonField(L[0], 'level'));
      AssertEquals('bearings', JsonField(L[0], 'logger'));
      AssertEquals('GET /small', JsonField(L[0], 'event'));
      AssertEquals('GET', JsonField(L[0], 'method'));
      AssertEquals('/small', JsonField(L[0], 'path'));
      AssertEquals('', JsonField(L[0], 'query'));
      AssertEquals('200', JsonField(L[0], 'status'));
      AssertEquals('5', JsonField(L[0], 'size'));
      AssertEquals('127.0.0.1', JsonField(L[0], 'client'));
      AssertTrue('timestamp ' + JsonField(L[0], 'timestamp'), (Length(JsonField(L[0], 'timestamp')) = 27)
        and (JsonField(L[0], 'timestamp')[11] = 'T') and (JsonField(L[0], 'timestamp')[27] = 'Z'));
      AssertTrue('duration ' + JsonField(L[0], 'duration'),
        Pos('.', JsonField(L[0], 'duration')) = 2);
      AssertEquals('no user agent field', 0, Pos('user_agent', L[0]));
      AssertEquals('no referer field', 0, Pos('referer', L[0]));
      AssertTrue('starts and ends as an object', (L[0][1] = '{') and (L[0][Length(L[0])] = '}'));
      { 2: an error status, a query, an escaped user agent }
      AssertEquals('404', JsonField(L[1], 'status'));
      AssertEquals('error', JsonField(L[1], 'level'));
      AssertEquals('GET /nope', JsonField(L[1], 'event'));
      AssertEquals('/nope', JsonField(L[1], 'path'));
      AssertEquals('x=1&y=2', JsonField(L[1], 'query'));
      AssertEquals('0', JsonField(L[1], 'size'));
      AssertEquals('t\"e\\st/1.0', JsonField(L[1], 'user_agent'));
      AssertEquals('http://x/from', JsonField(L[1], 'referer'));
      { 3: HEAD: status 200, no body bytes }
      AssertEquals('HEAD', JsonField(L[2], 'method'));
      AssertEquals('200', JsonField(L[2], 'status'));
      AssertEquals('0', JsonField(L[2], 'size'));
      { 4: HTTP/1.0 }
      AssertEquals('200', JsonField(L[3], 'status'));
      AssertEquals('no version field', 0, Pos('version', L[3]));
    finally
      L.Free;
    end;
  finally
    Sink.Free;
  end;
end;

procedure TTestAccessLog.Json_has_the_request_id_of_the_response;
var
  Sink: TMemSink;
  Fd: cint;
  L: TStringList;
begin
  Sink := TMemSink.Create;
  try
    StartServer(LogConfig(1, Sink, alfJson));
    Fd := Connect(Srv.Port);
    try
      GetOnce(Fd, '/rid');
      AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
    finally
      fpClose(Fd);
    end;
    StopServer;
    L := Sink.Lines;
    try
      AssertEquals('two lines: ' + Sink.Text, 2, L.Count);
      AssertEquals('abc-\"1\"', JsonField(L[0], 'request_id'));
      AssertEquals('200', JsonField(L[0], 'status'));
      AssertEquals('no request id field', 0, Pos('request_id', L[1]));
    finally
      L.Free;
    end;
  finally
    Sink.Free;
  end;
end;

procedure TTestAccessLog.The_level_is_the_status_one;
begin
  AssertTrue('200', AccessLevel(200) = llInfo);
  AssertTrue('302', AccessLevel(302) = llInfo);
  AssertTrue('399', AccessLevel(399) = llInfo);
  AssertTrue('400', AccessLevel(400) = llError);
  AssertTrue('404', AccessLevel(404) = llError);
  AssertTrue('499', AccessLevel(499) = llError);
  AssertTrue('500', AccessLevel(500) = llError);
  AssertTrue('503', AccessLevel(503) = llError);
end;

procedure TTestAccessLog.Min_level_drops_the_lines_below_it;
var
  Sink: TMemSink;
  Cfg: TServerConfig;
  Fd: cint;
  Eof: Boolean;
  L: TStringList;
  Got: RawByteString;
begin
  Sink := TMemSink.Create;
  try
    Cfg := LogConfig(1, Sink, alfJson);
    Cfg.AccessLog.MinLevel := llError;
    StartServer(Cfg);
    Fd := Connect(Srv.Port);
    try
      AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
      SendAll(Fd, 'GET /nope HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
      Got := RecvUntil(Fd, CRLF + CRLF, Eof);
      AssertTrue('404: ' + Got, AnsiStartsStr('HTTP/1.1 404', Got));
    finally
      fpClose(Fd);
    end;
    StopServer;
    L := Sink.Lines;
    try
      AssertEquals('only the 404: ' + Sink.Text, 1, L.Count);
      AssertEquals('/nope', JsonField(L[0], 'path'));
      AssertEquals('error', JsonField(L[0], 'level'));
    finally
      L.Free;
    end;
  finally
    Sink.Free;
  end;
end;

procedure TTestAccessLog.No_user_agent_or_referer_unless_asked;
var
  Sink: TMemSink;
  Cfg: TServerConfig;
  Fd: cint;
  L: TStringList;
begin
  Sink := TMemSink.Create;
  try
    Cfg := LogConfig(1, Sink, alfJson);
    Cfg.AccessLog.UserAgent := False;
    Cfg.AccessLog.Referer := False;
    StartServer(Cfg);
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, 'GET /small HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'User-Agent: curl/8' + CRLF
        + 'Referer: http://x/from' + CRLF + CRLF);
      AssertEquals(Resp('small'), RecvBytes(Fd, Length(Resp('small'))));
    finally
      fpClose(Fd);
    end;
    StopServer;
    L := Sink.Lines;
    try
      AssertEquals(1, L.Count);
      AssertEquals('no user agent: ' + L[0], 0, Pos('user_agent', L[0]));
      AssertEquals('no referer: ' + L[0], 0, Pos('referer', L[0]));
    finally
      L.Free;
    end;
  finally
    Sink.Free;
  end;
end;

procedure TTestAccessLog.Console_format;
var
  Sink: TMemSink;
  Fd: cint;
  L: TStringList;
  S: RawByteString;
begin
  Sink := TMemSink.Create;
  try
    StartServer(LogConfig(1, Sink, alfConsole));
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, 'GET /small?q=1 HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'User-Agent: curl/8 (x)' + CRLF
        + 'Referer: http://x/from' + CRLF + CRLF);
      AssertEquals(Resp('small'), RecvBytes(Fd, Length(Resp('small'))));
    finally
      fpClose(Fd);
    end;
    StopServer;
    L := Sink.Lines;
    try
      AssertEquals(1, L.Count);
      S := L[0];
      { the time of day, the level padded to "[error]", the status, the
        request, the duration and the size; no user agent or referer }
      AssertTrue('time: ' + S, (S[3] = ':') and (S[6] = ':') and (S[9] = '.') and (S[16] = 'Z'));
      AssertEquals('head: ' + S, 17, Pos(' [info]  200 GET /small?q=1  (', S));
      AssertTrue('tail: ' + S, AnsiEndsStr('ms; 5 bytes)', S));
      AssertEquals('no agent: ' + S, 0, Pos('curl', S));
      AssertEquals('no referer: ' + S, 0, Pos('from', S));
      AssertEquals('no colors', 0, Pos(#27, S));
    finally
      L.Free;
    end;
  finally
    Sink.Free;
  end;
end;

procedure TTestAccessLog.Console_colors;
var
  Sink: TMemSink;
  Cfg: TServerConfig;
  Fd: cint;
  Eof: Boolean;
  L: TStringList;
  S, Got: RawByteString;
begin
  Sink := TMemSink.Create;
  try
    Cfg := LogConfig(1, Sink, alfConsole);
    Cfg.AccessLog.Colors := True;
    StartServer(Cfg);
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, 'GET /nope HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
      Got := RecvUntil(Fd, CRLF + CRLF, Eof);
      AssertTrue('404: ' + Got, AnsiStartsStr('HTTP/1.1 404', Got));
    finally
      fpClose(Fd);
    end;
    StopServer;
    L := Sink.Lines;
    try
      AssertEquals(1, L.Count);
      S := L[0];
      { only the level has a color: a 4xx is an error, bright red }
      AssertTrue('level: ' + S, Pos('Z ['#27'[31m'#27'[1merror'#27'[0m] 404 GET /nope  (', S) > 0);
      AssertEquals('three escapes, all the level''s: ' + S, 3,
        Length(S) - Length(StringReplace(S, #27, '', [rfReplaceAll])));
    finally
      L.Free;
    end;
  finally
    Sink.Free;
  end;
end;

procedure TTestAccessLog.Console_sizes;
const
  CASES: array[0..13] of record N: QWord; Text: RawByteString; end = (
    (N: 0; Text: '0 bytes'),
    (N: 1; Text: '1 byte'),
    (N: 164; Text: '164 bytes'),
    (N: 1000; Text: '1000 bytes'),
    (N: 1023; Text: '1023 bytes'),
    (N: 1024; Text: '1.00 KB'),
    (N: 1641; Text: '1.60 KB'),
    (N: 16412; Text: '16.03 KB'),
    (N: 164125; Text: '160.28 KB'),
    (N: 1048575; Text: '1.00 MB'),
    (N: 1641252; Text: '1.57 MB'),
    (N: 16412523; Text: '15.65 MB'),
    (N: 164125234; Text: '156.52 MB'),
    (N: 1641252345; Text: '1.53 GB'));
var
  R: TAccessRecord;
  Buf: array[0..255] of Byte;
  N, I: Integer;
  S: RawByteString;
begin
  R := Default(TAccessRecord);
  R.Method := PByte(PAnsiChar('GET'));
  R.MethodLen := 3;
  R.Target := PByte(PAnsiChar('/x'));
  R.TargetLen := 2;
  R.Status := 200;
  R.DurationNs := 412000;
  for I := 0 to High(CASES) do
  begin
    R.BodyBytes := CASES[I].N;
    N := FormatAccessLine(R, alfConsole, False, @Buf[0], SizeOf(Buf));
    SetString(S, PAnsiChar(@Buf[0]), N);
    AssertEquals(IntToStr(CASES[I].N), '00:00:00.000000Z [info]  200 GET /x  (0.412ms; ' + CASES[I].Text
      + ')'#10, S);
  end;
  { a size past 1024 GB stays in GB }
  R.BodyBytes := 1641252345678;
  N := FormatAccessLine(R, alfConsole, False, @Buf[0], SizeOf(Buf));
  SetString(S, PAnsiChar(@Buf[0]), N);
  AssertTrue(S, AnsiEndsStr('(0.412ms; 1528.54 GB)'#10, S));
end;

procedure TTestAccessLog.Slow_sink_does_not_block_the_loop;
var
  Sink: TMemSink;
  Cfg: TServerConfig;
  Fd: cint;
  I: Integer;
  T0: QWord;
  S: TMetricsSnapshot;
begin
  Sink := TMemSink.Create;
  Sink.SlowMs := 1500;
  try
    Cfg := LogConfig(1, Sink, alfJson);
    Cfg.AccessLog.BufferBytes := 4096;   { about 20 lines per buffer }
    Cfg.AccessLog.FlushMs := 20;
    StartServer(Cfg);
    Fd := Connect(Srv.Port);
    try
      T0 := GetTickCount64;
      for I := 1 to 300 do
        AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
      AssertTrue('300 requests answered while the sink sleeps: ' + IntToStr(GetTickCount64 - T0) + ' ms',
        GetTickCount64 - T0 < 1000);
    finally
      fpClose(Fd);
    end;
    Srv.Metrics(S);
    AssertTrue('lines were dropped and counted: ' + IntToStr(S.Total.AccessLogDropped),
      S.Total.AccessLogDropped > 0);
    AssertEquals('every request answered', 300, Int64(S.Total.Requests));
    AssertEquals(Int64(S.Total.AccessLogDropped), Int64(Srv.AccessLog.Dropped));
    StopServer;
    AssertTrue('the sink got some lines', Sink.Writes >= 1);
  finally
    Sink.Free;
  end;
end;

procedure TTestMetrics.Counts_after_a_known_sequence;
var
  Cfg: TServerConfig;
  Fd, Fd2, Fd3: cint;
  Got: RawByteString;
  Eof: Boolean;
  S: TMetricsSnapshot;
  O: TConnOutcome;
  Closed: QWord;
begin
  Cfg := TestConfig(1);
  Cfg.Metrics := True;
  StartServer(Cfg);
  Srv.Metrics(S);
  AssertEquals('nothing yet', 0, Int64(S.Total.Requests));
  AssertEquals(1, S.Loops);
  Fd := Connect(Srv.Port);
  AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
  AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
  SendAll(Fd, Get('/nope'));
  Got := RecvUntil(Fd, CRLF + CRLF, Eof);
  AssertTrue(AnsiStartsStr('HTTP/1.1 404', Got));
  { a client that sends garbage: a parse error, answered with 400 }
  Fd2 := Connect(Srv.Port);
  SendAll(Fd2, 'NOT HTTP' + CRLF + CRLF);
  Got := RecvUntil(Fd2, '', Eof);
  AssertTrue('400: ' + Got, AnsiStartsStr('HTTP/1.1 400', Got) and Eof);
  fpClose(Fd2);
  { a client that connects and leaves without a request }
  Fd3 := Connect(Srv.Port);
  fpClose(Fd3);
  { in flight: a slow request }
  SendAll(Fd, Get('/slow'));
  Sleep(30);
  Srv.Metrics(S);
  AssertEquals('one in flight', 1, Int64(S.Total.RequestsInFlight));
  AssertEquals('one open', 1, Int64(S.Total.OpenConnections));
  AssertEquals(Resp('slow'), RecvBytes(Fd, Length(Resp('slow'))));
  fpClose(Fd);
  Sleep(50);
  Srv.Metrics(S);
  AssertEquals('requests', 4, Int64(S.Total.Requests));
  AssertEquals('2xx', 3, Int64(S.Total.Responses[sc2xx]));
  AssertEquals('4xx', 1, Int64(S.Total.Responses[sc4xx]));
  AssertEquals('latency count', 4, Int64(S.Total.LatencyCount));
  { the slow request's 100 ms timer fires on a millisecond tick: the loop
    clock may show a little less than 100 ms }
  AssertTrue('latency sum >= 90 ms (the slow request): ' + IntToStr(S.Total.LatencySumNs),
    S.Total.LatencySumNs >= 90000000);
  AssertTrue('the slow request is in a bucket of at least 65 ms',
    S.Total.Latency[17] + S.Total.Latency[18] + S.Total.Latency[19] + S.Total.Latency[20] >= 1);
  AssertEquals('request bytes: four heads of known size',
    Int64(2 * Length(Get('/small')) + Length(Get('/nope')) + Length(Get('/slow'))), Int64(S.Total.RequestBytes));
  AssertTrue('response bytes > bodies', S.Total.ResponseBytes > 14);
  AssertEquals('accepted', 3, Int64(S.Total.ConnectionsAccepted));
  AssertEquals('none open', 0, Int64(S.Total.OpenConnections));
  AssertEquals('none in flight', 0, Int64(S.Total.RequestsInFlight));
  Closed := 0;
  for O := Low(TConnOutcome) to High(TConnOutcome) do
    Inc(Closed, S.Total.ConnectionsClosed[O]);
  AssertEquals('three closed', 3, Int64(Closed));
  AssertEquals('one parse error', 1, Int64(S.Total.ConnectionsClosed[coParse]));
  AssertTrue('the normal connections ended ok: ' + IntToStr(S.Total.ConnectionsClosed[coOk]),
    S.Total.ConnectionsClosed[coOk] >= 1);
  { after Stop the snapshot is taken directly }
  StopServer;
end;

procedure TTestMetrics.Latency_buckets;
begin
  AssertEquals(0, LatencyBucket(0));
  AssertEquals(0, LatencyBucket(1));
  AssertEquals(0, LatencyBucket(1000));
  AssertEquals(1, LatencyBucket(1001));
  AssertEquals(1, LatencyBucket(2000));
  AssertEquals(2, LatencyBucket(2001));
  AssertEquals(10, LatencyBucket(1024000));
  AssertEquals(20, LatencyBucket(Int64(1048576) * 1000));
  AssertEquals(21, LatencyBucket(Int64(1048576) * 1000 + 1000));
  AssertEquals(24, LatencyBucket(Int64(20) * 1000000000));   { LATENCY_BUCKETS }
  AssertTrue(StatusClassOf(200) = sc2xx);
  AssertTrue(StatusClassOf(101) = sc1xx);
  AssertTrue(StatusClassOf(599) = sc5xx);
  AssertTrue(StatusClassOf(999) = scOther);
end;

procedure TTestMetrics.Prometheus_text_for_a_known_snapshot;
var
  S: TMetricsSnapshot;
  T, Expected: RawByteString;
  I: Integer;
const
  LE: array[0..23] of RawByteString = ('0.000001', '0.000002', '0.000004', '0.000008', '0.000016',
    '0.000032', '0.000064', '0.000128', '0.000256', '0.000512', '0.001024', '0.002048', '0.004096',
    '0.008192', '0.016384', '0.032768', '0.065536', '0.131072', '0.262144', '0.524288', '1.048576',
    '2.097152', '4.194304', '8.388608');
  CUM: array[0..24] of Integer = (0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3);
begin
  S := Default(TMetricsSnapshot);
  S.Loops := 2;
  S.WorkerQueueLength := 4;
  S.WorkerThreads := 8;
  S.CountedConnections := 7;
  MetricsResponse(S.Total, 200, 1500, 100, 300);           { 2 us: bucket 1 }
  MetricsResponse(S.Total, 404, 3000000, 50, 60);          { 3 ms: bucket 12 }
  MetricsResponse(S.Total, 503, 20000000000, 1, 1);        { 20 s: above the last bucket }
  Inc(S.Total.Requests, 5);
  Inc(S.Total.ConnectionsClosed[coOk], 3);
  Inc(S.Total.ConnectionsClosed[coTimeout], 1);
  S.Total.OpenConnections := 6;
  S.Total.RequestsInFlight := 2;
  S.Total.PooledBufferBytes := 65536;
  S.Total.ConnectionsAccepted := 10;
  S.Total.ListenerErrorPauses := 1;
  S.Total.ListenerLimitPauses := 2;
  S.Total.AccessLogDropped := 9;
  Expected :=
    '# HELP bearings_connections_open HTTP connections open now.'#10
    + '# TYPE bearings_connections_open gauge'#10
    + 'bearings_connections_open 6'#10
    + '# HELP bearings_connections_counted Connections holding a slot of the connection limit (0 without a limit).'#10
    + '# TYPE bearings_connections_counted gauge'#10
    + 'bearings_connections_counted 7'#10
    + '# HELP bearings_connections_accepted_total Connections accepted by the listeners.'#10
    + '# TYPE bearings_connections_accepted_total counter'#10
    + 'bearings_connections_accepted_total 10'#10
    + '# HELP bearings_connections_closed_total Connections closed, by outcome.'#10
    + '# TYPE bearings_connections_closed_total counter'#10
    + 'bearings_connections_closed_total{outcome="ok"} 3'#10
    + 'bearings_connections_closed_total{outcome="timeout"} 1'#10
    + 'bearings_connections_closed_total{outcome="parse_too_large"} 0'#10
    + 'bearings_connections_closed_total{outcome="parse_version_h2"} 0'#10
    + 'bearings_connections_closed_total{outcome="parse"} 0'#10
    + 'bearings_connections_closed_total{outcome="incomplete"} 0'#10
    + 'bearings_connections_closed_total{outcome="user"} 0'#10
    + 'bearings_connections_closed_total{outcome="canceled"} 0'#10
    + 'bearings_connections_closed_total{outcome="closed"} 0'#10
    + 'bearings_connections_closed_total{outcome="body_write_aborted"} 0'#10
    + 'bearings_connections_closed_total{outcome="shutdown"} 0'#10
    + 'bearings_connections_closed_total{outcome="io"} 0'#10
    + 'bearings_connections_closed_total{outcome="other"} 0'#10
    + '# HELP bearings_requests_total Request heads read.'#10
    + '# TYPE bearings_requests_total counter'#10
    + 'bearings_requests_total 5'#10
    + '# HELP bearings_requests_in_flight Requests being handled or answered now.'#10
    + '# TYPE bearings_requests_in_flight gauge'#10
    + 'bearings_requests_in_flight 2'#10
    + '# HELP bearings_responses_total Responses completed, by status class.'#10
    + '# TYPE bearings_responses_total counter'#10
    + 'bearings_responses_total{status="1xx"} 0'#10
    + 'bearings_responses_total{status="2xx"} 1'#10
    + 'bearings_responses_total{status="3xx"} 0'#10
    + 'bearings_responses_total{status="4xx"} 1'#10
    + 'bearings_responses_total{status="5xx"} 1'#10
    + 'bearings_responses_total{status="other"} 0'#10
    + '# HELP bearings_request_bytes_total HTTP bytes received: request heads and bodies.'#10
    + '# TYPE bearings_request_bytes_total counter'#10
    + 'bearings_request_bytes_total 151'#10
    + '# HELP bearings_response_bytes_total HTTP bytes sent: response heads and bodies.'#10
    + '# TYPE bearings_response_bytes_total counter'#10
    + 'bearings_response_bytes_total 361'#10
    + '# HELP bearings_request_duration_seconds Time from the request head to the complete response.'#10
    + '# TYPE bearings_request_duration_seconds histogram'#10;
  for I := 0 to 23 do
    Expected := Expected + 'bearings_request_duration_seconds_bucket{le="' + LE[I] + '"} ' + IntToStr(CUM[I]) + #10;
  Expected := Expected
    + 'bearings_request_duration_seconds_bucket{le="+Inf"} 3'#10
    + 'bearings_request_duration_seconds_sum 20.003001500'#10
    + 'bearings_request_duration_seconds_count 3'#10
    + '# HELP bearings_listener_pauses_total Times a listener left epoll, by reason.'#10
    + '# TYPE bearings_listener_pauses_total counter'#10
    + 'bearings_listener_pauses_total{reason="error"} 1'#10
    + 'bearings_listener_pauses_total{reason="limit"} 2'#10
    + '# HELP bearings_worker_queue_length Work items queued for the worker pool.'#10
    + '# TYPE bearings_worker_queue_length gauge'#10
    + 'bearings_worker_queue_length 4'#10
    + '# HELP bearings_worker_threads Worker threads.'#10
    + '# TYPE bearings_worker_threads gauge'#10
    + 'bearings_worker_threads 8'#10
    + '# HELP bearings_buffer_pool_bytes Bytes held in the loops'' buffer pools.'#10
    + '# TYPE bearings_buffer_pool_bytes gauge'#10
    + 'bearings_buffer_pool_bytes 65536'#10
    + '# HELP bearings_access_log_dropped_total Access log lines dropped because a buffer was full.'#10
    + '# TYPE bearings_access_log_dropped_total counter'#10
    + 'bearings_access_log_dropped_total 9'#10
    + '# HELP bearings_loops Event loops.'#10
    + '# TYPE bearings_loops gauge'#10
    + 'bearings_loops 2'#10;
  T := MetricsToPrometheus(S);
  AssertEquals(Expected, T);
end;

procedure TTestMetrics.Prometheus_text_from_a_server;
var
  Cfg: TServerConfig;
  Fd: cint;
  T: RawByteString;
begin
  Cfg := TestConfig(2);
  Cfg.Metrics := True;
  StartServer(Cfg);
  Fd := Connect(Srv.Port);
  AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
  fpClose(Fd);
  Sleep(30);
  T := Srv.PrometheusText;
  AssertTrue(T, Pos('bearings_requests_total 1'#10, T) > 0);
  AssertTrue(T, Pos('bearings_responses_total{status="2xx"} 1'#10, T) > 0);
  AssertTrue(T, Pos('bearings_loops 2'#10, T) > 0);
  AssertTrue(T, Pos('bearings_request_duration_seconds_count 1'#10, T) > 0);
end;

{ ---- the PROXY protocol and the lifetime caps ---- }

procedure TTestProxyAndLifetime.Proxy_v1_over_tcp_gives_the_client_address;
var
  Cfg: TServerConfig;
  Fd: cint;
  Got: RawByteString;
begin
  Cfg := TestConfig(1);
  Cfg.H1.ProxyProtocol := True;
  StartServer(Cfg);
  Fd := Connect(Srv.Port);
  try
    SendAll(Fd, 'PROXY TCP4 10.1.2.3 127.0.0.1 5555 80' + CRLF + Get('/peer'));
    Got := RecvBytes(Fd, Length(Resp('2:10.1.2.3')));
    AssertEquals(Resp('2:10.1.2.3'), Got);
    { the header is read once per connection: the next request has none }
    AssertEquals(Resp('2:10.1.2.3'), GetOnce(Fd, '/peer'));
    AssertEquals(Resp('small'), GetOnce(Fd, '/small'));
  finally
    fpClose(Fd);
  end;
  { a header without an address keeps the socket's peer }
  Fd := Connect(Srv.Port);
  try
    SendAll(Fd, 'PROXY UNKNOWN' + CRLF + Get('/peer'));
    Got := RecvBytes(Fd, Length(Resp('2:127.0.0.1')));
    AssertEquals(Resp('2:127.0.0.1'), Got);
  finally
    fpClose(Fd);
  end;
  StopServer;
end;

procedure TTestProxyAndLifetime.Proxy_v2_over_a_unix_socket;
var
  Cfg: TServerConfig;
  P, Got: RawByteString;
  Fd: cint;
const
  V2 = #13#10#13#10#0#13#10'QUIT'#10 + #$21#$21#0#36 + #$20#$01#$0D#$B8#0#0#0#0#0#0#0#0#0#0#0#1
    + #0#0#0#0#0#0#0#0#0#0#0#0#0#0#0#1 + #$FF#$FF + #1#$BB;
begin
  P := SockPath('proxy');
  Cfg := UnixConfig(1, P);
  Cfg.H1.ProxyProtocol := True;
  StartServer(Cfg);
  Fd := ConnectUnix(P);
  try
    SendAll(Fd, V2 + Get('/peer'));
    Got := RecvBytes(Fd, Length(Resp('10:2001:db8::1')));
    AssertEquals(Resp('10:2001:db8::1'), Got);
  finally
    fpClose(Fd);
  end;
  StopServer;
end;

procedure TTestProxyAndLifetime.Connection_without_a_proxy_header_is_closed;
var
  Cfg: TServerConfig;
  Fd: cint;
  Got: RawByteString;
  Eof: Boolean;
begin
  Cfg := TestConfig(1);
  Cfg.H1.ProxyProtocol := True;
  StartServer(Cfg);
  Fd := Connect(Srv.Port);
  try
    SendAll(Fd, Get('/small'));
    Got := RecvUntil(Fd, '', Eof);
    AssertEquals('no response', '', Got);
    AssertTrue('closed', Eof);
  finally
    fpClose(Fd);
  end;
  { a connection closed without a byte (a connect check) is fine }
  Fd := Connect(Srv.Port);
  fpClose(Fd);
  Fd := Connect(Srv.Port);
  try
    SendAll(Fd, 'PROXY TCP4 10.1.2.3 127.0.0.1 5555 80' + CRLF + Get('/small'));
    AssertEquals(Resp('small'), RecvBytes(Fd, Length(Resp('small'))));
  finally
    fpClose(Fd);
  end;
  StopServer;
end;

procedure TTestProxyAndLifetime.Max_connection_age_closes_at_the_next_request;
var
  Cfg: TServerConfig;
  Fd: cint;
  Got: RawByteString;
  Eof: Boolean;
begin
  Cfg := TestConfig(1);
  Cfg.H1.MaxConnectionMs := 300;
  StartServer(Cfg);
  Fd := Connect(Srv.Port);
  try
    AssertEquals('within the age: keep-alive', Resp('small'), GetOnce(Fd, '/small'));
    Sleep(400);
    SendAll(Fd, Get('/small'));
    Got := RecvUntil(Fd, '', Eof);
    AssertTrue('the response after the age closes: ' + Got, Pos('connection: close' + CRLF, Got) > 0);
    AssertTrue('its body', Pos(CRLF + CRLF + 'small', Got) > 0);
    AssertTrue('then EOF', Eof);
  finally
    fpClose(Fd);
  end;
  StopServer;
end;

begin
  if ParamStr(1) = '--sd-child' then
  begin
    RunSdChild;
    Halt(0);
  end;
  App := TOpsApp.Create;
  RegisterTest(TTestUnixSocket);
  RegisterTest(TTestSystemd);
  RegisterTest(TTestConnLimit);
  RegisterTest(TTestAccessLog);
  RegisterTest(TTestProxyAndLifetime);
  RegisterTest(TTestMetrics);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
  App.Free;
  DoneFiles;
end.
