{ M3 step S8 tests (design m3-transport.md 1.3, 1.11, 2.2.4 DV-5, 2.7, 3.7),
  over real sockets through TServer. They check outcomes (bytes a client
  receives, fds, exit times), not hyper's write sizes or event order.

  TTestSendFile: file bodies (BodyFile, sendfile): a known-length file
  response equals the memory response with the same content; file
  responses pipelined between memory responses, the first one a file
  (decision 8), with and without pipeline_flush; file frames in a chunked
  body equal memory frames; a 32 MiB file to a client that reads late
  (sendfile meets EAGAIN and resumes); the fd is closed after the last byte
  when CloseAfter, kept open otherwise, and closed when the connection dies
  in the middle of the file. The io-level tests (partial sendfile, EAGAIN
  with a clamped SO_SNDBUF, file entry between memory entries) are in
  test_h1_io.
  TTestUpgradeS8: TUpgraded.Detach with leftover bytes (the fd is blocking,
  out of the loop, served by another thread); an Upgraded handler that
  raises without taking the stream: the stream is closed (HS6-3).
  TTestServerStop: stop under load (every request the server received gets
  its full response; resets or EOFs only for requests it never received;
  new connections are refused afterwards; the loops exit long before the
  deadline), the deadline aborts a call that never answers, Wait shuts the
  worker pool down, amSharedExclusive (4 loops, one listening socket), and
  RunUntilSignal in a child process that gets SIGTERM.
  Run: test_server --all --format=plain }
program test_server;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, StrUtils, fpcunit, testregistry, consoletestrunner, Sockets, BaseUnix,
  process, ctypes, bearings.rt.sys, bearings.rt.buf, bearings.rt.loop, bearings.rt.net, bearings.rt.stream, bearings.http.headers,
  bearings.http.exchange, bearings.http1.config, bearings.server;

const
  CRLF = #13#10;
  BIG_LEN = 32 * 1024 * 1024;
  O_CLOEXEC = $80000;

type
  { ---- the service: one call object per request ---- }
  TS8Service = class;

  TS8Call = class(TServiceCall)
  public
    Svc: TS8Service;
    Path: RawByteString;
    Timer: TWakeTimer;
    function Poll(Ex: TExchange): TCallPoll; override;
    procedure Drop(Ex: TExchange; Completed: Boolean); override;
  end;

  TS8Service = class(THttpService)
  public
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  { frames of a chunked body: memory and file ranges (unknown length) }
  TFrameSource = class(TBodySource)
  public
    Frames: array of TBodyData;
    Next: Integer;
    function PollFrame(Ex: TExchange; out Data: TBodyData;
      out Trailers: THttpHeaders): TFramePoll; override;
    procedure Done(Ex: TExchange); override;
  end;

  TS8App = class
  public
    function NewService(Loop: TLoop): THttpService;
  end;

var
  { shared test state (written on loop threads, read by the test thread after
    the response arrived or the server stopped) }
  SmallPath, BigPath: string;
  Content, BigContent: RawByteString;
  KeepFd: cint = -1;                 { an fd the application owns (CloseAfter False) }
  LastFileFd: cint = -1;             { the fd of the last /file or /big response }
  LastFileIno: QWord;
  Calls, Answered, Dropped: LongInt;
  App: TS8App;

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

function FileIno(Fd: cint; out Ino: QWord): Boolean;
var
  St: Stat;
begin
  Result := FpFStat(Fd, St) = 0;
  if Result then
    Ino := St.st_ino
  else
    Ino := 0;
end;

{ True while Fd still refers to the file with inode Ino }
function FdIsFile(Fd: cint; Ino: QWord): Boolean;
var
  I: QWord;
begin
  Result := FileIno(Fd, I) and (I = Ino);
end;

function OpenForResponse(const Path: string): cint;
begin
  Result := FpOpen(Path, O_RDONLY or O_CLOEXEC);
  if Result < 0 then
    raise Exception.Create('cannot open ' + Path);
  FileIno(Result, LastFileIno);
  LastFileFd := Result;
end;

function TFrameSource.PollFrame(Ex: TExchange; out Data: TBodyData;
  out Trailers: THttpHeaders): TFramePoll;
begin
  Trailers := nil;
  if Next >= Length(Frames) then
  begin
    Data := BodyEmpty;
    Exit(fpEnd);
  end;
  Data := Frames[Next];
  Frames[Next] := BodyEmpty;
  Inc(Next);
  Result := fpData;
end;

procedure TFrameSource.Done(Ex: TExchange);
var
  I: Integer;
begin
  for I := Next to High(Frames) do
    ReleaseBody(Frames[I]);
  Free;
end;

function FrameSource(UseFile: Boolean): TFrameSource;
begin
  { 'AAAA', bytes 100..3099 of the file, 'BB', bytes 5000..11999 }
  Result := TFrameSource.Create;
  SetLength(Result.Frames, 4);
  Result.Frames[0] := BodyString('AAAA');
  Result.Frames[2] := BodyString('BB');
  if UseFile then
  begin
    Result.Frames[1] := BodyFile(KeepFd, 100, 3000, False);
    Result.Frames[3] := BodyFile(KeepFd, 5000, 7000, False);
  end
  else
  begin
    Result.Frames[1] := BodyString(Copy(Content, 101, 3000));
    Result.Frames[3] := BodyString(Copy(Content, 5001, 7000));
  end;
end;

function TS8Call.Poll(Ex: TExchange): TCallPoll;
begin
  if Path = '/slow' then
  begin
    if not Timer.Fired then
    begin
      if Timer.Target = nil then
        Timer.Arm(Ex, 100);
      Exit(cpPending);
    end;
    if Ex.Respond(BodyString('slow')) then
      InterLockedIncrement(Answered);
    Exit(cpReady);
  end;
  if Path = '/never' then
    Exit(cpPending);                 { nothing wakes it: only the stop deadline ends it }
  if Path = '/mem' then
    Ex.Respond(BodyString(Content))
  else if Path = '/small' then
    Ex.Respond(BodyString('small'))
  else if Path = '/file' then
    Ex.Respond(BodyFile(OpenForResponse(SmallPath), 0, Length(Content), True))
  else if Path = '/file-keep' then
    Ex.Respond(BodyFile(KeepFd, 0, Length(Content), False))
  else if Path = '/big' then
    Ex.Respond(BodyFile(OpenForResponse(BigPath), 0, BIG_LEN, True))
  else if Path = '/chunked-file' then
    Ex.RespondStream(FrameSource(True))
  else if Path = '/chunked-mem' then
    Ex.RespondStream(FrameSource(False))
  else
  begin
    Ex.Status := 404;
    Ex.Respond(BodyEmpty);
  end;
  InterLockedIncrement(Answered);
  Result := cpReady;
end;

procedure TS8Call.Drop(Ex: TExchange; Completed: Boolean);
begin
  Timer.Cancel(Ex);
  if not Completed then
    InterLockedIncrement(Dropped);
  Free;
end;

function TS8Service.Call(Ex: TExchange): TServiceCall;
var
  C: TS8Call;
  P: TByteSlice;
begin
  InterLockedIncrement(Calls);
  C := TS8Call.Create;
  C.Svc := Self;
  P := Ex.Path;
  SetString(C.Path, PAnsiChar(P.P), P.Len);
  Result := C;
end;

function TS8App.NewService(Loop: TLoop): THttpService;
begin
  Result := TS8Service.Create;
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

function TestConfig(Loops: Integer): TServerConfig;
begin
  Result := BenchmarkServerConfig;
  Result.Listen.Host := '127.0.0.1';
  Result.Listen.Port := 0;
  Result.Loops := Loops;
  Result.H1.AutoDateHeader := False;
  Result.GraceMs := 5000;
end;

procedure InitFiles;
var
  Dir: string;
begin
  if Content <> '' then
    Exit;
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False));
  SmallPath := Dir + 'be-s8-small-' + IntToStr(FpGetPid);
  BigPath := Dir + 'be-s8-big-' + IntToStr(FpGetPid);
  Content := PatternBytes(20000, 3);
  BigContent := PatternBytes(BIG_LEN, 11);
  WriteFileBytes(SmallPath, Content);
  WriteFileBytes(BigPath, BigContent);
  KeepFd := FpOpen(SmallPath, O_RDONLY or O_CLOEXEC);
end;

procedure DoneFiles;
begin
  if KeepFd >= 0 then
    FpClose(KeepFd);
  KeepFd := -1;
  if SmallPath <> '' then
    DeleteFile(SmallPath);
  if BigPath <> '' then
    DeleteFile(BigPath);
end;

type
  TServerCase = class(TTestCase)
  protected
    Srv: TServer;
    procedure StartServer(const Cfg: TServerConfig);
    procedure SetUp; override;
    procedure TearDown; override;
  end;

  TTestSendFile = class(TServerCase)
  published
    procedure File_body_equals_memory_body;
    procedure Pipelined_file_responses;
    procedure Pipelined_file_responses_pipeline_flush;
    procedure Chunked_file_frames_equal_memory_frames;
    procedure Big_file_to_a_late_reader;
    procedure Keep_open_fd_stays_open;
    procedure Connection_dies_mid_file_closes_fd;
  end;

  TTestUpgradeS8 = class(TServerCase)
  published
    procedure Detach_with_leftover_bytes;
    procedure Handler_raises_without_taking_stream;
  end;

  TTestServerStop = class(TServerCase)
  published
    procedure Stop_under_load;
    procedure Stop_under_load_shared_exclusive;
    procedure Stop_deadline_aborts_unanswered_call;
    procedure Wait_shuts_worker_pool_down;
    procedure Shared_exclusive_four_loops;
    procedure Run_until_sigterm_in_child;
    procedure Run_until_signal_ends_on_external_stop;
  private
    procedure StopAtStart(Server: TServer);
  end;

procedure TServerCase.StartServer(const Cfg: TServerConfig);
begin
  Srv := TServer.Create(Cfg, @App.NewService);
  Srv.Start;
end;

procedure TServerCase.SetUp;
begin
  InitFiles;
  Calls := 0;
  Answered := 0;
  Dropped := 0;
  LastFileFd := -1;
  Srv := nil;
end;

procedure TServerCase.TearDown;
begin
  if Srv <> nil then
  begin
    Srv.Stop(1000);
    Srv.Wait;
    FreeAndNil(Srv);
  end;
end;

{ ---- sendfile ---- }

procedure TTestSendFile.File_body_equals_memory_body;
var
  Fd: cint;
  A, B: RawByteString;
begin
  StartServer(TestConfig(1));
  Fd := Connect(Srv.Port);
  try
    SendAll(Fd, Get('/mem'));
    A := RecvBytes(Fd, Length(Resp(Content)));
    SendAll(Fd, Get('/file'));
    B := RecvBytes(Fd, Length(Resp(Content)));
  finally
    fpClose(Fd);
  end;
  AssertTrue('memory response', A = Resp(Content));
  AssertTrue('the file response has the same bytes', B = A);
  Sleep(50);
  AssertFalse('CloseAfter: the fd was closed after the last byte', FdIsFile(LastFileFd, LastFileIno));
end;

procedure PipelinedFiles(Srv: TServer);
var
  Fd: cint;
  Want, Got: RawByteString;
begin
  { decision 8: the first response has a file body; 3 or more pipelined }
  Want := Resp(Content) + Resp('small') + Resp(Content) + Resp(Content) + Resp('small')
    + Resp(Content);
  Fd := Connect(Srv.Port);
  try
    SendAll(Fd, Get('/file') + Get('/small') + Get('/file') + Get('/mem') + Get('/small')
      + Get('/file'));
    Got := RecvBytes(Fd, Length(Want));
  finally
    fpClose(Fd);
  end;
  if Got <> Want then
    raise Exception.CreateFmt('pipelined responses differ (got %d of %d bytes)',
      [Length(Got), Length(Want)]);
end;

procedure TTestSendFile.Pipelined_file_responses;
var
  Cfg: TServerConfig;
begin
  Cfg := TestConfig(1);
  Cfg.H1.PipelineFlush := False;
  StartServer(Cfg);
  PipelinedFiles(Srv);
end;

procedure TTestSendFile.Pipelined_file_responses_pipeline_flush;
begin
  StartServer(TestConfig(1));
  PipelinedFiles(Srv);
end;

procedure TTestSendFile.Chunked_file_frames_equal_memory_frames;
var
  Fd: cint;
  A, B: RawByteString;
  Eof: Boolean;
begin
  StartServer(TestConfig(1));
  Fd := Connect(Srv.Port);
  try
    SendAll(Fd, Get('/chunked-mem'));
    A := RecvUntil(Fd, CRLF + '0' + CRLF + CRLF, Eof);
    SendAll(Fd, Get('/chunked-file'));
    B := RecvUntil(Fd, CRLF + '0' + CRLF + CRLF, Eof);
  finally
    fpClose(Fd);
  end;
  AssertTrue('chunked', Pos('transfer-encoding: chunked', A) > 0);
  AssertTrue('frames: ' + IntToStr(Length(A)), Pos(CRLF + 'BB' + CRLF, A) > 0);
  AssertTrue('the file frames have the same bytes', A = B);
  AssertTrue('the application''s fd is open', KeepFd >= 0);
  AssertTrue('CloseAfter False: still open', FpFcntl(KeepFd, F_GETFD) >= 0);
end;

procedure TTestSendFile.Big_file_to_a_late_reader;
var
  Fd: cint;
  Want, Got: RawByteString;
begin
  StartServer(TestConfig(1));
  Want := Resp(BigContent);
  Fd := Connect(Srv.Port);
  try
    SendAll(Fd, Get('/big'));
    { the socket buffers fill up: sendfile meets EAGAIN and resumes on EPOLLOUT }
    Sleep(300);
    Got := RecvBytes(Fd, Length(Want));
  finally
    fpClose(Fd);
  end;
  AssertEquals('length', Length(Want), Length(Got));
  AssertTrue('bytes', Got = Want);
  Sleep(50);
  AssertFalse('fd closed after the last byte', FdIsFile(LastFileFd, LastFileIno));
end;

procedure TTestSendFile.Keep_open_fd_stays_open;
var
  Fd: cint;
  Got: RawByteString;
  Ino: QWord;
begin
  StartServer(TestConfig(1));
  FileIno(KeepFd, Ino);
  Fd := Connect(Srv.Port);
  try
    SendAll(Fd, Get('/file-keep') + Get('/file-keep'));
    Got := RecvBytes(Fd, 2 * Length(Resp(Content)));
  finally
    fpClose(Fd);
  end;
  AssertTrue('two responses', Got = Resp(Content) + Resp(Content));
  AssertTrue('CloseAfter False: the fd stays open', FdIsFile(KeepFd, Ino));
end;

procedure TTestSendFile.Connection_dies_mid_file_closes_fd;
var
  Fd: cint;
  Got: RawByteString;
  L: TLinger;
  I: Integer;
begin
  StartServer(TestConfig(1));
  Fd := Connect(Srv.Port);
  SendAll(Fd, Get('/big'));
  Got := RecvBytes(Fd, 65536);
  AssertEquals('a part of the file arrived', 65536, Length(Got));
  AssertTrue('the file is open while it is sent', FdIsFile(LastFileFd, LastFileIno));
  { RST: the server's next sendfile fails }
  L.l_onoff := 1;
  L.l_linger := 0;
  fpSetSockOpt(Fd, SOL_SOCKET, SO_LINGER, @L, SizeOf(L));
  fpClose(Fd);
  I := 0;
  while FdIsFile(LastFileFd, LastFileIno) and (I < 300) do
  begin
    Sleep(10);
    Inc(I);
  end;
  AssertFalse('the fd was closed when the connection died', FdIsFile(LastFileFd, LastFileIno));
end;

{ ---- upgrades ---- }

const
  UPGRADE_REQ = 'GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: foo' + CRLF +
    'Connection: upgrade' + CRLF + CRLF;

type
  TDetachHandler = class(TUpgradeHandler)
  public
    Detached: Boolean;
    Blocking: Boolean;
    Fd: cint;
    Rest: RawByteString;
    Thread: TThreadID;
    Echoed: RawByteString;
    procedure Upgraded(U: TUpgraded); override;
  end;

  TRaiseHandler = class(TUpgradeHandler)
  public
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

{ the detached stream on its own thread, blocking: 'rest=<leftover>;', then
  echo until EOF, then close }
function DetachedThread(Arg: Pointer): PtrInt;
var
  H: TDetachHandler;
  Buf: array[0..4095] of Byte;
  R: ssize_t;
  S: RawByteString;
begin
  H := TDetachHandler(Arg);
  S := 'rest=' + H.Rest + ';';
  fpSend(H.Fd, PAnsiChar(S), Length(S), MSG_NOSIGNAL);
  repeat
    R := fpRecv(H.Fd, @Buf[0], SizeOf(Buf), 0);
    if R > 0 then
    begin
      SetString(S, PAnsiChar(@Buf[0]), R);
      H.Echoed := H.Echoed + S;
      fpSend(H.Fd, @Buf[0], R, MSG_NOSIGNAL);
    end;
  until R <= 0;
  fpClose(H.Fd);
  Result := 0;
end;

procedure TDetachHandler.Upgraded(U: TUpgraded);
var
  Fl: cint;
begin
  Detached := U.Detach(Fd, Rest);
  if not Detached then
    Exit;
  Fl := FpFcntl(Fd, F_GETFL);
  Blocking := (Fl >= 0) and ((Fl and O_NONBLOCK) = 0);
  Thread := BeginThread(@DetachedThread, Pointer(Self));
end;

procedure TRaiseHandler.Upgraded(U: TUpgraded);
begin
  { neither attached, detached nor closed: bearings closes U (HS6-3) }
  raise Exception.Create('upgrade handler failure (test)');
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

function UpgradeConfig: TServerConfig;
begin
  Result := TestConfig(1);
  Result.H1.Mode := cmWithUpgrades;
end;

procedure TTestUpgradeS8.Detach_with_leftover_bytes;
var
  UA: TUpApp;
  H: TDetachHandler;
  Fd: cint;
  Head, Echo, Tail: RawByteString;
  Eof: Boolean;
  L0: LongInt;
begin
  L0 := UpgradeSlotsLive;
  UA := TUpApp.Create;
  H := TDetachHandler.Create;
  UA.Handler := H;
  Srv := TServer.Create(UpgradeConfig, @UA.NewService);
  try
    Srv.Start;
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, UPGRADE_REQ + 'left');
      Head := RecvUntil(Fd, ';', Eof);
      SendAll(Fd, 'ping');
      Echo := RecvBytes(Fd, 4);
      fpShutdown(Fd, SHUT_WR);
      Tail := RecvUntil(Fd, '', Eof);
    finally
      fpClose(Fd);
    end;
    if H.Detached then
    begin
      WaitForThreadTerminate(H.Thread, 0);
      CloseThread(H.Thread);
    end;
    Srv.Stop(1000);
    Srv.Wait;
    AssertTrue('detached', H.Detached);
    AssertTrue('the fd is blocking', H.Blocking);
    AssertTrue('101, then the leftover from the other thread: ' + Head,
      AnsiStartsStr('HTTP/1.1 101 Switching Protocols', Head) and AnsiEndsStr(CRLF + CRLF + 'rest=left;', Head));
    AssertEquals('leftover copied', 'left', H.Rest);
    AssertEquals('blocking echo on the other thread', 'ping', Echo);
    AssertEquals('the thread read the socket, not the leftover again', 'ping', H.Echoed);
    AssertTrue('the thread closed the socket', Eof);
    AssertEquals('nothing more', '', Tail);
    AssertEquals('slot freed', L0, UpgradeSlotsLive);
  finally
    FreeAndNil(Srv);
    H.Free;
    UA.Free;
  end;
end;

procedure TTestUpgradeS8.Handler_raises_without_taking_stream;
var
  UA: TUpApp;
  Fd: cint;
  Got: RawByteString;
  Eof: Boolean;
  L0: LongInt;
begin
  L0 := UpgradeSlotsLive;
  UA := TUpApp.Create;
  UA.Handler := TRaiseHandler.Create;
  Srv := TServer.Create(UpgradeConfig, @UA.NewService);
  try
    Srv.Start;
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, UPGRADE_REQ);
      { without the HS6-3 fix the socket stays open: RecvUntil times out
        after 5 s with Eof False }
      Got := RecvUntil(Fd, '', Eof);
    finally
      fpClose(Fd);
    end;
    Srv.Stop(1000);
    Srv.Wait;
    AssertTrue('101: ' + Got, AnsiStartsStr('HTTP/1.1 101 Switching Protocols', Got));
    AssertTrue('the stream nobody took was closed', Eof);
    AssertEquals('slot freed', L0, UpgradeSlotsLive);
  finally
    FreeAndNil(Srv);
    UA.Handler.Free;
    UA.Free;
  end;
end;

{ ---- stop ---- }

type
  { keep-alive client: GET Path on a connection until it closes, then a
    new connection, until a connect is refused }
  TLoadClient = class(TThread)
  public
    Port: Word;
    Path, Body: RawByteString;       { '/slow' (100 ms) or '/small' (at once) }
    Full, Empty, Partial, Refused, OtherConnectErrors: Integer;
    procedure Execute; override;
  end;

procedure TLoadClient.Execute;
var
  Fd: cint;
  E: cint;
  Buf: array[0..4095] of AnsiChar;
  Got, S: RawByteString;
  R: ssize_t;
  HeadEnd, Need: Integer;
  ConnOpen: Boolean;
begin
  while not Terminated do
  begin
    E := TryConnect(Port, Fd);
    if E <> 0 then
    begin
      if E = ESysECONNREFUSED then
        Inc(Refused)
      else
        Inc(OtherConnectErrors);
      Exit;
    end;
    SetRecvTimeout(Fd, 10);
    ConnOpen := True;
    while ConnOpen do
    begin
      S := Get(Path);
      if fpSend(Fd, PAnsiChar(S), Length(S), MSG_NOSIGNAL) <> Length(S) then
      begin
        Inc(Empty);
        Break;
      end;
      Got := '';
      Need := -1;
      repeat
        R := fpRecv(Fd, @Buf[0], SizeOf(Buf), 0);
        if R > 0 then
        begin
          SetString(S, PAnsiChar(@Buf[0]), R);
          Got := Got + S;
          HeadEnd := Pos(CRLF + CRLF, Got);
          if (Need < 0) and (HeadEnd > 0) then
            Need := HeadEnd + 3 + Length(Body);
        end;
      until (R <= 0) or ((Need > 0) and (Length(Got) >= Need));
      if (Need > 0) and (Length(Got) = Need) and AnsiStartsStr('HTTP/1.1 200 OK', Got)
        and AnsiEndsStr(CRLF + CRLF + Body, Got) then
      begin
        Inc(Full);
        if Pos('connection: close', Got) > 0 then
          ConnOpen := False;
      end
      else if Got = '' then
      begin
        Inc(Empty);
        ConnOpen := False;
      end
      else
      begin
        Inc(Partial);
        ConnOpen := False;
      end;
    end;
    fpClose(Fd);
  end;
end;

procedure StopUnderLoad(TC: TServerCase; Cfg: TServerConfig);
const
  N = 8;
var
  Clients: array[0..N - 1] of TLoadClient;
  I, Full, Empty, Partial, Refused, Other: Integer;
  T0, Took: QWord;
  Fd: cint;
begin
  TC.Srv := TServer.Create(Cfg, @App.NewService);
  TC.Srv.Start;
  for I := 0 to N - 1 do
  begin
    Clients[I] := TLoadClient.Create(True);
    Clients[I].Port := TC.Srv.Port;
    { half wait 100 ms for their answer (in flight at the stop), half
      send requests as fast as they are answered (idle keep-alive
      connections and new connections at the stop) }
    if Odd(I) then
    begin
      Clients[I].Path := '/small';
      Clients[I].Body := 'small';
    end
    else
    begin
      Clients[I].Path := '/slow';
      Clients[I].Body := 'slow';
    end;
    Clients[I].Start;
  end;
  { requests in flight on every client when the stop comes }
  T0 := GetTickCount64;
  while (Calls < 2000) and (GetTickCount64 - T0 < 10000) do
    Sleep(5);
  T0 := GetTickCount64;
  TC.Srv.Stop(Cfg.GraceMs);
  TC.Srv.Wait;
  Took := GetTickCount64 - T0;
  Full := 0; Empty := 0; Partial := 0; Refused := 0; Other := 0;
  for I := 0 to N - 1 do
  begin
    Clients[I].WaitFor;
    Inc(Full, Clients[I].Full);
    Inc(Empty, Clients[I].Empty);
    Inc(Partial, Clients[I].Partial);
    Inc(Refused, Clients[I].Refused);
    Inc(Other, Clients[I].OtherConnectErrors);
    Clients[I].Free;
  end;
  TC.AssertTrue('the loops left long before the deadline (' + IntToStr(Took) + ' ms)',
    Took < 3000);
  TC.AssertTrue('requests were made', Calls >= 2000);
  TC.AssertEquals('no response cut short', 0, Partial);
  TC.AssertEquals('no call dropped before the deadline', 0, Dropped);
  TC.AssertEquals('every request the server received was answered', Calls, Answered);
  TC.AssertEquals('every answer arrived complete', Answered, Full);
  TC.AssertEquals('every client ended at a refused connect', N, Refused);
  TC.AssertEquals('no other connect error', 0, Other);
  TC.AssertTrue('new connections are refused', TryConnect(TC.Srv.Port, Fd) = ESysECONNREFUSED);
  { Empty: connections the server closed before it read a request (idle
    keep-alive connections at GracefulShutdown, connections the drain
    accepted, connections reset in the accept window): their requests were
    never received, so they do not count in Calls }
  WriteLn(StdErr, 'stop under load: ', Calls, ' calls, ', Full, ' full responses, ', Empty,
    ' closed before a request was read, stop took ', Took, ' ms');
end;

procedure TTestServerStop.Stop_under_load;
begin
  StopUnderLoad(Self, TestConfig(2));
end;

procedure TTestServerStop.Stop_under_load_shared_exclusive;
var
  Cfg: TServerConfig;
begin
  Cfg := TestConfig(4);
  Cfg.Listen.Mode := amSharedExclusive;
  StopUnderLoad(Self, Cfg);
end;

procedure TTestServerStop.Stop_deadline_aborts_unanswered_call;
var
  Fd: cint;
  T0, Took: QWord;
  Got: RawByteString;
  Eof: Boolean;
begin
  StartServer(TestConfig(1));
  Fd := Connect(Srv.Port);
  try
    SendAll(Fd, Get('/never'));
    T0 := GetTickCount64;
    while (Calls < 1) and (GetTickCount64 - T0 < 5000) do
      Sleep(1);
    T0 := GetTickCount64;
    Srv.Stop(300);
    Srv.Wait;
    Took := GetTickCount64 - T0;
    Got := RecvUntil(Fd, '', Eof);
  finally
    fpClose(Fd);
  end;
  AssertTrue('the loop waited for the deadline (' + IntToStr(Took) + ' ms)', Took >= 250);
  AssertTrue('and left at it', Took < 2000);
  AssertEquals('aborted: no response', '', Got);
  AssertEquals('the call was dropped', 1, Dropped);
end;

procedure TTestServerStop.StopAtStart(Server: TServer);
begin
  Server.Stop(0);
end;

procedure TTestServerStop.Run_until_signal_ends_on_external_stop;
var
  T0: QWord;
begin
  { a Stop that is not a signal (here from the Started callback, as a
    handler or another thread would call it) also ends the wait }
  Srv := TServer.Create(TestConfig(1), @App.NewService);
  T0 := GetTickCount64;
  AssertEquals('no signal', 0, Srv.RunUntilSignal(@StopAtStart));
  AssertTrue('returned within the 200 ms check', GetTickCount64 - T0 < 2000);
end;

procedure TTestServerStop.Wait_shuts_worker_pool_down;
var
  Cfg: TServerConfig;
begin
  Cfg := TestConfig(1);
  Cfg.Workers := 2;
  StartServer(Cfg);
  AssertEquals('pool running', 2, Srv.Workers.Alive);
  Srv.Stop(1000);
  Srv.Wait;
  AssertEquals('pool shut down by Wait', 0, Srv.Workers.Alive);
end;

type
  TBurst = class(TThread)
  public
    Port: Word;
    Ok, Bad: Integer;
    procedure Execute; override;
  end;

procedure TBurst.Execute;
var
  I: Integer;
  Fd: cint;
  Got: RawByteString;
  Eof: Boolean;
begin
  for I := 1 to 10 do
  begin
    if TryConnect(Port, Fd) <> 0 then
    begin
      Inc(Bad);
      Continue;
    end;
    try
      SendAll(Fd, 'GET /small HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: close' + CRLF + CRLF);
      Got := RecvUntil(Fd, '', Eof);
      if Eof and AnsiStartsStr('HTTP/1.1 200 OK', Got) and AnsiEndsStr(CRLF + CRLF + 'small', Got) then
        Inc(Ok)
      else
        Inc(Bad);
    finally
      fpClose(Fd);
    end;
  end;
end;

procedure TTestServerStop.Shared_exclusive_four_loops;
const
  N = 12;
var
  Cfg: TServerConfig;
  B: array[0..N - 1] of TBurst;
  I, Ok, Bad: Integer;
  Accepted: QWord;
  Fds: array[0..3] of cint;
  Fd: cint;
begin
  Cfg := TestConfig(4);
  Cfg.Listen.Mode := amSharedExclusive;
  StartServer(Cfg);
  for I := 0 to 3 do
  begin
    AssertTrue('loop ' + IntToStr(I) + ' has a listener', Srv.Loops[I].Listener <> nil);
    Fds[I] := Srv.Loops[I].Listener.Src.Fd;
  end;
  AssertTrue('one fd per loop', (Fds[0] <> Fds[1]) and (Fds[1] <> Fds[2]) and (Fds[2] <> Fds[3]));
  for I := 0 to N - 1 do
  begin
    B[I] := TBurst.Create(True);
    B[I].Port := Srv.Port;
    B[I].Start;
  end;
  Ok := 0;
  Bad := 0;
  for I := 0 to N - 1 do
  begin
    B[I].WaitFor;
    Inc(Ok, B[I].Ok);
    Inc(Bad, B[I].Bad);
    B[I].Free;
  end;
  { the connections were served, so every accept4 was made; Stop drops the listeners }
  Accepted := 0;
  for I := 0 to 3 do
    Inc(Accepted, Srv.Loops[I].Listener.Accepted);
  Srv.Stop(1000);
  Srv.Wait;
  AssertEquals('every request served', N * 10, Ok);
  AssertEquals('no failure', 0, Bad);
  AssertEquals('every connection accepted once, by some loop', N * 10, Accepted);
  AssertTrue('refused after the stop', TryConnect(Srv.Port, Fd) = ESysECONNREFUSED);
end;

{ ---- RunUntilSignal in a child process ---- }

type
  TChildMain = class
    procedure Started(S: TServer);
  end;

procedure TChildMain.Started(S: TServer);
begin
  WriteLn('PORT ', S.Port);
  Flush(Output);
end;

procedure RunSigChild;
var
  Cfg: TServerConfig;
  S: TServer;
  M: TChildMain;
  Sig: cint;
begin
  InitFiles;
  App := TS8App.Create;
  M := TChildMain.Create;
  Cfg := TestConfig(2);
  Cfg.GraceMs := 5000;
  S := TServer.Create(Cfg, @App.NewService);
  Sig := S.RunUntilSignal(@M.Started);
  WriteLn('SIGNAL ', Sig, ' CALLS ', Calls, ' ANSWERED ', Answered);
  Flush(Output);
  S.Free;
  M.Free;
  App.Free;
  DoneFiles;
end;

procedure TTestServerStop.Run_until_sigterm_in_child;
var
  P: TProcess;
  Line, Outp, Got: RawByteString;
  Buf: array[0..255] of AnsiChar;
  N: LongInt;
  Port: Word;
  Fd, Fd2: cint;
  T0: QWord;
  I: Integer;
  Eof: Boolean;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := ParamStr(0);
    P.Parameters.Add('--sig-child');
    P.Options := [poUsePipes, poStderrToOutPut];
    { the child must not write the parent's heaptrc log }
    for I := 0 to GetEnvironmentVariableCount - 1 do
      if not AnsiStartsStr('HEAPTRC=', GetEnvironmentString(I)) then
        P.Environment.Add(GetEnvironmentString(I));
    P.Execute;
    Outp := '';
    T0 := GetTickCount64;
    while (Pos(#10, Outp) = 0) and (GetTickCount64 - T0 < 10000) do
    begin
      if P.Output.NumBytesAvailable > 0 then
      begin
        N := P.Output.Read(Buf[0], SizeOf(Buf));
        if N > 0 then
          Outp := Outp + Copy(Buf, 1, N);
      end
      else
        Sleep(5);
    end;
    Line := Copy(Outp, 1, Pos(#10, Outp) - 1);
    AssertTrue('child printed its port: ' + Outp, AnsiStartsStr('PORT ', Line));
    Port := StrToInt(Copy(Line, 6, MaxInt));
    Fd := Connect(Port);
    try
      SendAll(Fd, Get('/slow'));
      Sleep(30);                     { the request is in flight (100 ms timer) }
      FpKill(P.ProcessID, SIGTERM);
      Got := RecvUntil(Fd, '', Eof);
    finally
      fpClose(Fd);
    end;
    T0 := GetTickCount64;
    while P.Running and (GetTickCount64 - T0 < 5000) do
      Sleep(10);
    if P.Running then
    begin
      P.Terminate(1);
      Fail('the child did not exit after SIGTERM');
    end;
    while P.Output.NumBytesAvailable > 0 do
    begin
      N := P.Output.Read(Buf[0], SizeOf(Buf));
      if N <= 0 then
        Break;
      Outp := Outp + Copy(Buf, 1, N);
    end;
    AssertTrue('the request in flight got its full response: ' + Got,
      AnsiStartsStr('HTTP/1.1 200 OK', Got) and AnsiEndsStr(CRLF + CRLF + 'slow', Got));
    AssertTrue('connection: close after the stop', Pos('connection: close', Got) > 0);
    AssertTrue('the server closed the connection', Eof);
    AssertEquals('exit status', 0, P.ExitStatus);
    AssertTrue('stopped by SIGTERM: ' + Outp, Pos('SIGNAL 15 CALLS 1 ANSWERED 1', Outp) > 0);
    AssertTrue('the port is closed', TryConnect(Port, Fd2) = ESysECONNREFUSED);
  finally
    P.Free;
  end;
end;

begin
  if ParamStr(1) = '--sig-child' then
  begin
    RunSigChild;
    Halt(0);
  end;
  App := TS8App.Create;
  RegisterTest(TTestSendFile);
  RegisterTest(TTestUpgradeS8);
  RegisterTest(TTestServerStop);
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
