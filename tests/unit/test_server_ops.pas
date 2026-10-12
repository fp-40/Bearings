{ Operations features of bearings.server, over real sockets through TServer.

  TTestUnixSocket: a listener on a Unix domain socket (TListenSpec.UnixPath):
  requests, pipelining and sendfile over it; the peer record of a Unix
  connection (Family = AF_UNIX, SockAddrToStr = ''); a stale socket file is
  replaced and a regular file at the path is not; the file's mode
  (UnixMode, default &660) and group (UnixGroup; an unknown group fails
  Start and leaves no file); four loops share one socket (amReusePort is
  mapped to amSharedExclusive); Stop removes the file.
  Run: test_server_ops --all --format=plain }
program test_server_ops;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, StrUtils, fpcunit, testregistry, consoletestrunner, Sockets, BaseUnix,
  ctypes, bearings.rt.sys, bearings.rt.buf, bearings.rt.loop, bearings.rt.net, bearings.http.headers,
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

begin
  App := TOpsApp.Create;
  RegisterTest(TTestUnixSocket);
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
