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
  Run: test_server_ops --all --format=plain }
program test_server_ops;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, StrUtils, fpcunit, testregistry, consoletestrunner, Sockets, BaseUnix,
  ctypes, bearings.rt.sys, bearings.rt.buf, bearings.rt.loop, bearings.rt.net, bearings.rt.sd, bearings.rt.stream, bearings.http.headers,
  bearings.http.exchange, bearings.http1.config, bearings.server;

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
  Args: array[0..2] of PAnsiChar;
  Outp, Got: RawByteString;
  Buf: array[0..255] of AnsiChar;
  N: LongInt;
  T0: QWord;
  Exe: RawByteString;
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
    Args[0] := PAnsiChar(Exe);
    Args[1] := '--sd-child';
    Args[2] := nil;
    { FpExecv would pass the RTL's copy of the environment, taken at start:
      the variables set above would be lost. libc's execv uses libc's. }
    execv(PAnsiChar(Exe), @Args[0]);
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
