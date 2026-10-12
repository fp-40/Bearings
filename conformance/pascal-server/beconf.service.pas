{ beconf.service - SPEC 5 handlers, replies and bodies, the connection
  observer and the byte-counting transport (docs/design.md section 9).
  Test tooling: a thin wrapper, everything on the wire comes from bearings.http1.*.

  TConfService.Call does what the reference server's Svc::call does (in
  recv_msg): assigns req (the connection's request number), emits
  `request`, takes the next reply (test_service), and returns a TConfCall
  whose Drop(Ex, False) emits `handler_dropped` (the reference's DropGuard,
  created in call(), so a call that is never polled still emits it).
  TConfCall.Poll is the reference's handle(): the handler body runs only
  there, and `handler_done` is emitted right before it returns cpReady.

  TScriptBody is the reference's ScriptBody (unknown size, IsEndStream
  False, one frame per item, a delay before an item when it has one, then
  the trailers once, then the end).

  TConfObserver: conn_open at accept (connections numbered 1, 2, ... in
  accept order; an atomic counter, as --loops N accepts on several loops), the TCountingTransport wrapper (the reference's CountIo,
  always present; it emits bytes_read only when the spec asks), conn_close
  with OutcomeOf / ErrorDescription, graceful_shutdown_on_accept (OnStart:
  after the dispatcher is set up, before its first Run), and the
  without_shutdown parts: when the request's reply stored an upgrade with
  on_upgrade false, the upgrade task runs on the returned socket, else the
  socket is closed (the reference's serve_conn).

  --executor worker (docs/design.md section 9): TConfService.Call returns a
  TConfWorkerCall (a TOffloadCall per call). Its first Poll, on the loop,
  does SPEC 5.5 step 3 (upgrade::on is a loop-thread call) and offloads;
  TConfBlockingHandler.Run does the rest on a worker: the body with the
  blocking ReadFrame (TryRead that parks; it reports the trailer frame),
  delays with Sleep (a cancel is seen when it wakes), the answer with
  Respond / Fail / BeginStream, a streamed body with WriteString after each
  item's Sleep, AbortStream for an error item, Finish with the trailers.
  hello_world and unreachable run on the worker too. handler_done is
  emitted only when the worker's terminal call won (3.2.3 rule 5), with the
  event lock held across the call and the line, so no loop-thread event of
  the connection (conn_close) can come between them; handler_dropped is
  emitted by Drop(Ex, False) on the loop only when the cancel won
  (Ex.IsCanceled). Each call emits exactly one of them. The call object is
  shared by the loop (Drop) and the worker (Run) and freed by the last. }
unit beconf.service;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ctypes, bearings.rt.sys, bearings.rt.loop, bearings.rt.net, bearings.rt.buf, bearings.rt.stream, bearings.http.error,
  bearings.http1.encode,
  bearings.http.headers, bearings.http.uri, bearings.http1.role, bearings.http.exchange, bearings.http1.config,
  bearings.http1.dispatch, bearings.rt.workers, beconf.spec, beconf.events, beconf.upgrade;

type
  { per connection (TConnObserver data) }
  TConnData = class
  public
    Conn: QWord;
    Loop: TLoop;
    PendingUpgrade: TUpgradeSpec;    { reply upgrade with on_upgrade false (without_shutdown) }
  end;

  { the reference's CountIo: counts the bytes the HTTP layer reads; with Emit, a bytes_read
    event after every read that returned data (the bytes are in the read buffer, not parsed
    yet). Everything else is delegated, so the wire is the same. The upgrade hand-off unwraps
    it (TTransport.Wrapped), so upgrade-task reads are not counted. }
  TCountingTransport = class(TTransport)
  private
    FInner: TTransport;
    FOwnsInner: Boolean;
  public
    Conn: QWord;
    Total: QWord;
    Emit: Boolean;
    constructor Create(AInner: TTransport; AConn: QWord; AEmit: Boolean);
    destructor Destroy; override;
    function Read(Buf: PByte; Len: SizeInt): SizeInt; override;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; override;
    function WriteV(Iov: PIoSlice; Count: Integer): SizeInt; override;
    function IsWriteVectored: Boolean; override;
    function SendFile(InFd: cint; var Offset: Int64; Count: SizeInt): SizeInt; override;
    function ShutdownWrite: SizeInt; override;
    procedure Close; override;
    function Wrapped: TTransport; override;
    procedure DisownWrapped; override;
  end;

  TConfObserver = class(TConnObserver)
  private
    FNextConn: Int64;
  public
    Spec: TServerSpec;
    function OnAccept(Loop: TLoop; ConnId: QWord; const Peer: TSockAddrStorage): Pointer; override;
    function WrapTransport(T: TTcpTransport; Data: Pointer): TTransport; override;
    procedure OnStart(ConnId: QWord; Data: Pointer; Task: TLoopTask); override;
    procedure OnConnClose(ConnId: QWord; Data: Pointer; Outcome: TConnOutcome;
      const Detail: string); override;
    procedure OnParts(ConnId: QWord; Data: Pointer; var Parts: TConnParts); override;
  end;

  TConfBlockingHandler = class;

  TConfService = class(THttpService)
  public
    Spec: TServerSpec;
    Pool: TWorkerPool;               { --executor worker: the server's pool; nil = inline }
    Blocking: TConfBlockingHandler;  { owned }
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  { --executor worker: one per call (the request's state lives here, Ex.User on the worker) }
  TConfWorkerCall = class(TOffloadCall)
  private
    FRefs: LongInt;                  { the loop (Drop) and, once offloaded, the worker (Run) }
  public
    Conn: QWord;
    Req: LongWord;
    Data: TConnData;
    Kind: THandlerKind;
    Reply: TReply;
    UpHandler: TConfUpgradeHandler;  { registered with Ex.OnUpgrade (first poll), not owned }
    NoUpgrade: Boolean;              { upgrade::on on a request without one }
    EmitNoUpgrade: Boolean;          { set by the worker (step 8): the loop emits upgrade_error }
    ArmUpgrade: Boolean;             { set by the worker (step 8): the loop sets UpHandler.Armed }
    PendingUpgrade: TUpgradeSpec;    { set by the worker (step 8): the loop sets Data.PendingUpgrade }
    function Poll(Ex: TExchange): TCallPoll; override;
    procedure Drop(Ex: TExchange; Completed: Boolean); override;
    procedure ReleaseRef;
  end;

  TConfBlockingHandler = class(TBlockingHandler)
  private
    procedure TestService(Ex: TExchange; C: TConfWorkerCall);
  public
    procedure Run(Ex: TExchange); override;
  end;

  TCallStep = (csStart, csReadBody, csRelease, csDelay, csRespond);

  TConfCall = class(TServiceCall)
  private
    procedure Done_(Ex: TExchange; const Line: RawByteString);
    procedure Respond_(Ex: TExchange);
  public
    Conn: QWord;
    Req: LongWord;
    Data: TConnData;
    Handler: THandlerKind;
    Reply: TReply;
    Step: TCallStep;
    Finished: Boolean;               { handler_done emitted (the DropGuard is disarmed) }
    Body: RawByteString;
    HasTrailers: Boolean;
    TrailersJson: RawByteString;
    Delay: TWakeTimer;
    UpHandler: TConfUpgradeHandler;  { registered with Ex.OnUpgrade, not owned }
    NoUpgrade: Boolean;              { upgrade::on on a request without one }
    function Poll(Ex: TExchange): TCallPoll; override;
    procedure Drop(Ex: TExchange; Completed: Boolean); override;
  end;

  TScriptBody = class(TBodySource)
  private
    FPos: Integer;
    FSleeping, FSlept, FTrailersSent: Boolean;
    FDelay: TWakeTimer;
    FTrailers: THttpHeaders;
  public
    Spec: ^TBodySpec;
    constructor Create(ASpec: Pointer);
    destructor Destroy; override;
    function PollFrame(Ex: TExchange; out Data: TBodyData;
      out Trailers: THttpHeaders): TFramePoll; override;
    procedure Done(Ex: TExchange); override;
  end;

implementation

const
  HELLO: array[0..4] of AnsiChar = 'hello';

function VersionStr(V: THttpVersion): RawByteString;
begin
  case V of
    hv09: Result := 'HTTP/0.9';
    hv10: Result := 'HTTP/1.0';
    hv11: Result := 'HTTP/1.1';
    hv2: Result := 'HTTP/2.0';
  else
    Result := 'HTTP/3.0';
  end;
end;

function SliceStr(P: PByte; Len: SizeInt): RawByteString;
begin
  SetString(Result, PAnsiChar(P), Len);
end;

{ http::Uri Display: scheme "://" authority path ["?" query] }
function TargetStr(Ex: TExchange): RawByteString;
var
  U: TUriParts;
  Base, P: PByte;
  L: SizeInt;
begin
  U := Ex.Head.Uri;
  Base := Ex.Head.View.P;
  Result := '';
  case U.Scheme of
    usHttp: Result := 'http://';
    usHttps: Result := 'https://';
    usOther: Result := SliceStr(Base + U.SchemeOff, U.SchemeLen) + '://';
  else
  end;
  if U.AuthorityLen > 0 then
    Result := Result + SliceStr(Base + U.AuthorityOff, U.AuthorityLen);
  U.GetPath(Base, P, L);
  Result := Result + SliceStr(P, L);
  if U.GetQuery(Base, P, L) then
    Result := Result + '?' + SliceStr(P, L);
end;

{ ---- TCountingTransport ---- }

constructor TCountingTransport.Create(AInner: TTransport; AConn: QWord; AEmit: Boolean);
begin
  inherited Create;
  FInner := AInner;
  FOwnsInner := True;
  Conn := AConn;
  Emit := AEmit;
end;

destructor TCountingTransport.Destroy;
begin
  if FOwnsInner then
    FInner.Free;
  inherited Destroy;
end;

function TCountingTransport.Read(Buf: PByte; Len: SizeInt): SizeInt;
begin
  Result := FInner.Read(Buf, Len);
  if Result > 0 then
  begin
    Inc(Total, QWord(Result));
    if Emit then
      EmitLine('{"event":"bytes_read","conn":' + JUInt(Conn) + ',"total":' + JUInt(Total) + '}');
  end;
end;

function TCountingTransport.Write(Buf: PByte; Len: SizeInt): SizeInt;
begin
  Result := FInner.Write(Buf, Len);
end;

function TCountingTransport.WriteV(Iov: PIoSlice; Count: Integer): SizeInt;
begin
  Result := FInner.WriteV(Iov, Count);
end;

function TCountingTransport.IsWriteVectored: Boolean;
begin
  Result := FInner.IsWriteVectored;
end;

function TCountingTransport.SendFile(InFd: cint; var Offset: Int64; Count: SizeInt): SizeInt;
begin
  Result := FInner.SendFile(InFd, Offset, Count);
end;

function TCountingTransport.ShutdownWrite: SizeInt;
begin
  Result := FInner.ShutdownWrite;
end;

procedure TCountingTransport.Close;
begin
  FInner.Close;
end;

function TCountingTransport.Wrapped: TTransport;
begin
  Result := FInner;
end;

procedure TCountingTransport.DisownWrapped;
begin
  FOwnsInner := False;
end;

{ ---- TConfObserver ---- }

function TConfObserver.OnAccept(Loop: TLoop; ConnId: QWord; const Peer: TSockAddrStorage): Pointer;
var
  D: TConnData;
begin
  { --loops N: loops accept concurrently }
  D := TConnData.Create;
  D.Conn := QWord(InterLockedIncrement64(FNextConn));
  D.Loop := Loop;
  EmitLine('{"event":"conn_open","conn":' + JUInt(D.Conn) + '}');
  Result := D;
end;

function TConfObserver.WrapTransport(T: TTcpTransport; Data: Pointer): TTransport;
begin
  Result := TCountingTransport.Create(T, TConnData(Data).Conn, Spec.BytesReadEvents);
end;

procedure TConfObserver.OnStart(ConnId: QWord; Data: Pointer; Task: TLoopTask);
begin
  { graceful_shutdown_on_accept: before the first poll (-> closed, outcome ok, nothing written) }
  if Spec.GracefulShutdownOnAccept then
    TH1Dispatcher(Task).GracefulShutdown;
end;

procedure TConfObserver.OnConnClose(ConnId: QWord; Data: Pointer; Outcome: TConnOutcome;
  const Detail: string);
const
  NAMES: array[TConnOutcome] of string = ('ok', 'timeout', 'parse_too_large',
    'parse_version_h2', 'parse', 'incomplete', 'user', 'canceled', 'closed',
    'body_write_aborted', 'shutdown', 'io', 'other');
var
  D: TConnData;
  Line: RawByteString;
begin
  D := TConnData(Data);
  Line := '{"event":"conn_close","conn":' + JUInt(D.Conn) + ',"outcome":"' + NAMES[Outcome] + '"';
  if Outcome <> coOk then
  begin
    Line := Line + ',"detail":' + JText(Detail);
    WriteLn(StdErr, 'beconf: conn ', D.Conn, ' closed: ', NAMES[Outcome], ': ', Detail);
  end;
  EmitLine(Line + '}');
  { without_shutdown and Ok: OnParts follows and frees the data }
  if not ((Spec.Cfg.Mode = cmWithoutShutdown) and (Outcome = coOk)) then
    D.Free;
end;

procedure TConfObserver.OnParts(ConnId: QWord; Data: Pointer; var Parts: TConnParts);
var
  D: TConnData;
  U: TUpgraded;
begin
  D := TConnData(Data);
  try
    if D.PendingUpgrade <> nil then
    begin
      { run_upgrade on parts.io.into_stream() with parts.read_buf; the
        socket's readiness source moves to the stream before the connection
        task is freed }
      U := TUpgraded.CreateFrom(D.Loop, Parts.Transport, Parts.Rest, Parts.Src, True);
      Parts.Transport := nil;
      Parts.Rest := Default(TBytesView);
      StartUpgrade(D.Conn, D.PendingUpgrade, U);
    end
    else
      inherited OnParts(ConnId, Data, Parts);   { drop: close(2) }
  finally
    D.Free;
  end;
end;

{ ---- TConfService ---- }

destructor TConfService.Destroy;
begin
  Blocking.Free;
  inherited Destroy;
end;

function NewWorkerCall(S: TConfService; Ex: TExchange; D: TConnData): TConfWorkerCall;
var
  M: TByteSlice;
begin
  Result := TConfWorkerCall.Create;
  Result.Pool := S.Pool;
  Result.Handler := S.Blocking;
  Result.FRefs := 1;
  Result.Data := D;
  Result.Conn := D.Conn;
  Result.Req := Ex.RequestNo;
  Result.Kind := S.Spec.Handler;
  M := Ex.MethodBytes;
  EmitLine('{"event":"request","conn":' + JUInt(Result.Conn) + ',"req":' + JUInt(Result.Req)
    + ',"method":' + JBytesP(M.P, M.Len) + ',"target":' + JBytes(TargetStr(Ex))
    + ',"version":"' + VersionStr(Ex.Version) + '","headers":' + JHeaders(Ex.Headers) + '}');
  if Result.Kind = hkTestService then
    Result.Reply := S.Spec.NextReply;
end;

function TConfService.Call(Ex: TExchange): TServiceCall;
var
  C: TConfCall;
  D: TConnData;
  M: TByteSlice;
begin
  D := TConnData(TH1Dispatcher(Ex.Owner).ObsData);
  if Pool <> nil then
    Exit(NewWorkerCall(Self, Ex, D));
  C := TConfCall.Create;
  C.Data := D;
  C.Conn := D.Conn;
  C.Req := Ex.RequestNo;
  C.Handler := Spec.Handler;
  M := Ex.MethodBytes;
  EmitLine('{"event":"request","conn":' + JUInt(C.Conn) + ',"req":' + JUInt(C.Req)
    + ',"method":' + JBytesP(M.P, M.Len) + ',"target":' + JBytes(TargetStr(Ex))
    + ',"version":"' + VersionStr(Ex.Version) + '","headers":' + JHeaders(Ex.Headers) + '}');
  if C.Handler = hkTestService then
    C.Reply := Spec.NextReply;
  C.Step := csStart;
  Result := C;
end;

{ ---- TConfCall ---- }

procedure TConfCall.Done_(Ex: TExchange; const Line: RawByteString);
begin
  Finished := True;
  EmitLine(Line);
end;

function ErrDone(Conn: QWord; Req: LongWord; const Msg: RawByteString): RawByteString;
begin
  Result := '{"event":"handler_done","conn":' + JUInt(Conn) + ',"req":' + JUInt(Req)
    + ',"result":"error","message":' + JText(Msg) + '}';
end;

function RespDone(Conn: QWord; Req: LongWord; Status: Word): RawByteString;
begin
  Result := '{"event":"handler_done","conn":' + JUInt(Conn) + ',"req":' + JUInt(Req)
    + ',"result":"response","status":' + JUInt(Status) + '}';
end;

procedure TConfCall.Respond_(Ex: TExchange);
var
  I: Integer;
  H: THttpHeaders;
  R: TReply;
begin
  R := Reply;
  Ex.Status := R.Status;
  if R.HasReason then
    Ex.SetReason(PByte(Pointer(R.Reason)), Length(R.Reason));
  if R.HasVersion then
    Ex.ResponseVersion := R.Version;
  H := Ex.ResponseHeaders;
  for I := 0 to High(R.Headers) do
    { ReplyBuilder::header -> HeaderMap::insert }
    H.Insert(R.Headers[I].Name, R.Headers[I].Value);
  case R.Body.Kind of
    bsKnown:
      Ex.Respond(BodyString(R.Body.Known));
    bsStream:
      Ex.RespondStream(TScriptBody.Create(@R.Body));
  else
    Ex.Respond(BodyEmpty);
  end;
  Done_(Ex, RespDone(Conn, Req, R.Status));
end;

function TConfCall.Poll(Ex: TExchange): TCallPoll;
var
  Chunk: TByteSlice;
  S: RawByteString;
begin
  case Handler of
    hkHelloWorld:
      begin
        { tests/server.rs HelloWorld: 200, Full "hello"; never reads the body }
        Ex.Respond(BodyStatic(@HELLO[0], 5));
        Done_(Ex, RespDone(Conn, Req, 200));
        Exit(cpReady);
      end;
    hkUnreachable:
      begin
        Ex.Fail('request shouldn''t be received');
        Done_(Ex, ErrDone(Conn, Req, 'request shouldn''t be received'));
        Exit(cpReady);
      end;
  end;
  { test_service: SPEC 5.5 }
  while True do
    case Step of
      csStart:
        begin
          { 3. upgrade::on before the request is released }
          if (Reply.Upgrade <> nil) and Reply.Upgrade.OnUpgrade then
          begin
            if Ex.UpgradeSlot = nil then
              NoUpgrade := True        { OnUpgrade::none(): Err(no upgrade) when awaited }
            else
            begin
              UpHandler := TConfUpgradeHandler.Create;
              UpHandler.Conn := Conn;
              UpHandler.Spec := Reply.Upgrade;
              UpHandler.Loop := Ex.Loop;
              Ex.OnUpgrade(UpHandler);
            end;
          end;
          if Reply.ReadBody then
            Step := csReadBody
          else
            Step := csRelease;
        end;
      csReadBody:
        case Ex.TryRead(Chunk) of
          brData:
            begin
              SetString(S, PAnsiChar(Chunk.P), Chunk.Len);
              Body := Body + S;
            end;
          brTrailers:
            begin
              HasTrailers := True;
              TrailersJson := JHeaders(Ex.RequestTrailers);
            end;
          brEnd:
            begin
              S := '{"event":"request_body","conn":' + JUInt(Conn) + ',"req":' + JUInt(Req)
                + ',"body":' + JBytes(Body);
              if HasTrailers then
                S := S + ',"trailers":' + TrailersJson;
              EmitLine(S + '}');
              Step := csRelease;
            end;
          brError:
            begin
              case Ex.BodyErrorKind of
                bekUnexpectedEof: S := 'unexpected_eof';
                bekInvalidData: S := 'invalid_data';
                bekInvalidInput: S := 'invalid_input';
                bekIo: S := 'io';
              else
                S := 'other';
              end;
              EmitLine('{"event":"request_body_error","conn":' + JUInt(Conn) + ',"req":'
                + JUInt(Req) + ',"kind":"' + S + '","message":' + JText(Ex.BodyErrorMessage) + '}');
              Ex.Fail('req body error');
              Done_(Ex, ErrDone(Conn, Req, 'req body error'));
              Exit(cpReady);
            end;
        else
          { brPending: the body channel wakes the connection (brCanceled: the
            call is being dropped) }
          Exit(cpPending);
        end;
      csRelease:
        begin
          { 5. drop(req) }
          Ex.ReleaseRequest;
          if Reply.DelayMs > 0 then
          begin
            Delay.Arm(Ex, Int64(Reply.DelayMs));
            Step := csDelay;
            Exit(cpPending);
          end;
          Step := csRespond;
        end;
      csDelay:
        begin
          if not Delay.Fired then
            Exit(cpPending);
          Step := csRespond;
        end;
    else
      begin
        { 7. error }
        if Reply.HasError then
        begin
          Ex.Fail(Reply.Error);
          Done_(Ex, ErrDone(Conn, Req, Reply.Error));
          Exit(cpReady);
        end;
        { 8. upgrade }
        if Reply.Upgrade <> nil then
        begin
          if Reply.Upgrade.OnUpgrade then
          begin
            if UpHandler <> nil then
              UpHandler.Armed := True    { tokio::spawn(on_upgrade.await ...) }
            else if NoUpgrade then
              EmitLater(Ex.Loop, '{"event":"upgrade_error","conn":' + JUInt(Conn)
                + ',"message":"no upgrade available"}');
          end
          else
            Data.PendingUpgrade := Reply.Upgrade;
        end;
        { 9. the response }
        Respond_(Ex);
        Exit(cpReady);
      end;
    end;
end;

procedure TConfCall.Drop(Ex: TExchange; Completed: Boolean);
begin
  if Delay.T.Proc <> nil then
    Delay.Cancel(Ex);
  if not Finished then
    EmitLine('{"event":"handler_dropped","conn":' + JUInt(Conn) + ',"req":' + JUInt(Req) + '}');
  Free;
end;

{ ---- TConfWorkerCall / TConfBlockingHandler (--executor worker) ---- }

function TConfWorkerCall.Poll(Ex: TExchange): TCallPoll;
begin
  if not Ex.Offloaded then
  begin
    { 3. upgrade::on before the request is released (a loop-thread call) }
    if (Kind = hkTestService) and (Reply.Upgrade <> nil) and Reply.Upgrade.OnUpgrade then
    begin
      if Ex.UpgradeSlot = nil then
        NoUpgrade := True
      else
      begin
        UpHandler := TConfUpgradeHandler.Create;
        UpHandler.Conn := Conn;
        UpHandler.Spec := Reply.Upgrade;
        UpHandler.Loop := Ex.Loop;
        Ex.OnUpgrade(UpHandler);
      end;
    end;
    Ex.User := Self;
    { the worker's reference; taken back if Offload raises (the pool is
      shut down: the worker never runs, so it never releases it) }
    InterLockedIncrement(FRefs);
    try
      Result := inherited Poll(Ex);
    except
      InterLockedDecrement(FRefs);
      raise;
    end;
    Exit;
  end;
  Result := inherited Poll(Ex);
  if Result = cpReady then
  begin
    { step 8's writes to loop-owned objects, made here on the loop: the
      worker's flags were written before its terminal call, whose CAS the
      loop saw (Answered). Written by the worker itself, they could reach
      an UpHandler or a TConnData the loop already freed (connection end
      between the worker's ReleaseRequest and step 8) }
    if ArmUpgrade then
      UpHandler.Armed := True;
    if PendingUpgrade <> nil then
      Data.PendingUpgrade := PendingUpgrade;
    if EmitNoUpgrade then
    begin
      EmitNoUpgrade := False;
      EmitLater(Ex.Loop, '{"event":"upgrade_error","conn":' + JUInt(Conn)
        + ',"message":"no upgrade available"}');
    end;
  end;
end;

procedure TConfWorkerCall.Drop(Ex: TExchange; Completed: Boolean);
begin
  { the cancel won the CAS (or the call never ran): the reference's DropGuard }
  if (not Completed) and Ex.IsCanceled then
    EmitLine('{"event":"handler_dropped","conn":' + JUInt(Conn) + ',"req":' + JUInt(Req) + '}');
  ReleaseRef;
end;

procedure TConfWorkerCall.ReleaseRef;
begin
  if InterLockedDecrement(FRefs) = 0 then
    Free;
end;

procedure TConfBlockingHandler.Run(Ex: TExchange);
var
  C: TConfWorkerCall;
begin
  C := TConfWorkerCall(Ex.User);
  try
    case C.Kind of
      hkHelloWorld:
        begin
          { the request is dropped when handle returns, right after the response is made }
          Ex.ReleaseRequest;
          LockEvents;
          try
            if Ex.Respond(BodyStatic(@HELLO[0], 5)) then
              EmitLine(RespDone(C.Conn, C.Req, 200));
          finally
            UnlockEvents;
          end;
        end;
      hkUnreachable:
        begin
          Ex.ReleaseRequest;
          LockEvents;
          try
            if Ex.Fail('request shouldn''t be received') then
              EmitLine(ErrDone(C.Conn, C.Req, 'request shouldn''t be received'));
          finally
            UnlockEvents;
          end;
        end;
    else
      TestService(Ex, C);
    end;
  finally
    C.ReleaseRef;
  end;
end;

procedure SetHead(Ex: TExchange; R: TReply);
var
  I: Integer;
  H: THttpHeaders;
begin
  Ex.Status := R.Status;
  if R.HasReason then
    Ex.SetReason(PByte(Pointer(R.Reason)), Length(R.Reason));
  if R.HasVersion then
    Ex.ResponseVersion := R.Version;
  H := Ex.ResponseHeaders;
  for I := 0 to High(R.Headers) do
    H.Insert(R.Headers[I].Name, R.Headers[I].Value);
end;

procedure TConfBlockingHandler.TestService(Ex: TExchange; C: TConfWorkerCall);
var
  R: TReply;
  Chunk: TByteSlice;
  S, Body, TrailersJson: RawByteString;
  HasTrailers: Boolean;
  I: Integer;
  It: ^TStreamItem;
  Tr: THttpHeaders;
begin
  R := C.Reply;
  { 4. read_body }
  if R.ReadBody then
  begin
    Body := '';
    HasTrailers := False;
    while True do
      case Ex.ReadFrame(Chunk) of
        brData:
          begin
            SetString(S, PAnsiChar(Chunk.P), Chunk.Len);
            Body := Body + S;
          end;
        brTrailers:
          begin
            HasTrailers := True;
            TrailersJson := JHeaders(Ex.RequestTrailers);
          end;
        brEnd:
          begin
            S := '{"event":"request_body","conn":' + JUInt(C.Conn) + ',"req":' + JUInt(C.Req)
              + ',"body":' + JBytes(Body);
            if HasTrailers then
              S := S + ',"trailers":' + TrailersJson;
            EmitLine(S + '}');
            Break;
          end;
        brError:
          begin
            case Ex.BodyErrorKind of
              bekUnexpectedEof: S := 'unexpected_eof';
              bekInvalidData: S := 'invalid_data';
              bekInvalidInput: S := 'invalid_input';
              bekIo: S := 'io';
            else
              S := 'other';
            end;
            EmitLine('{"event":"request_body_error","conn":' + JUInt(C.Conn) + ',"req":'
              + JUInt(C.Req) + ',"kind":"' + S + '","message":' + JText(Ex.BodyErrorMessage) + '}');
            LockEvents;
            try
              if Ex.Fail('req body error') then
                EmitLine(ErrDone(C.Conn, C.Req, 'req body error'));
            finally
              UnlockEvents;
            end;
            Exit;
          end;
      else
        Exit;                              { brCanceled: the loop emitted handler_dropped }
      end;
  end;
  { 5. drop(req) }
  Ex.ReleaseRequest;
  { 6. delay }
  if R.DelayMs > 0 then
  begin
    Sleep(R.DelayMs);
    if Ex.IsCanceled then
      Exit;
  end;
  { 7. error }
  if R.HasError then
  begin
    LockEvents;
    try
      if Ex.Fail(R.Error) then
        EmitLine(ErrDone(C.Conn, C.Req, R.Error));
    finally
      UnlockEvents;
    end;
    Exit;
  end;
  { 8. upgrade }
  if R.Upgrade <> nil then
  begin
    if R.Upgrade.OnUpgrade then
    begin
      { the loop applies these after cpReady (TConfWorkerCall.Poll) }
      if C.UpHandler <> nil then
        C.ArmUpgrade := True
      else if C.NoUpgrade then
        C.EmitNoUpgrade := True
    end
    else
      C.PendingUpgrade := R.Upgrade;
  end;
  { 9. the response }
  SetHead(Ex, R);
  if R.Body.Kind <> bsStream then
  begin
    LockEvents;
    try
      if R.Body.Kind = bsKnown then
      begin
        if Ex.Respond(BodyString(R.Body.Known)) then
          EmitLine(RespDone(C.Conn, C.Req, R.Status));
      end
      else if Ex.Respond(BodyEmpty) then
        EmitLine(RespDone(C.Conn, C.Req, R.Status));
    finally
      UnlockEvents;
    end;
    Exit;
  end;
  LockEvents;
  try
    if not Ex.BeginStream(65536) then
      Exit;
    EmitLine(RespDone(C.Conn, C.Req, R.Status));
  finally
    UnlockEvents;
  end;
  { the body: one frame per item (times expanded by the spec parser), each
    after its delay }
  for I := 0 to High(R.Body.Items) do
  begin
    It := @R.Body.Items[I];
    if It^.DelayMs > 0 then
      Sleep(It^.DelayMs);
    if It^.Kind = siData then
    begin
      if Ex.WriteString(It^.Data) = wrCanceled then
        Exit;
    end
    else
    begin
      Ex.AbortStream(It^.Message);
      Exit;
    end;
  end;
  Tr := nil;
  if R.Body.HasTrailers then
  begin
    Tr := THttpHeaders.Create(4, 256);
    for I := 0 to High(R.Body.Trailers) do
      Tr.Insert(R.Body.Trailers[I].Name, R.Body.Trailers[I].Value);
  end;
  try
    Ex.Finish(Tr);
  finally
    Tr.Free;
  end;
end;

{ ---- TScriptBody ---- }

constructor TScriptBody.Create(ASpec: Pointer);
var
  I: Integer;
  B: ^TBodySpec;
begin
  inherited Create;
  Spec := ASpec;
  B := ASpec;
  if B^.HasTrailers then
  begin
    { StreamBodyWithTrailers gets a HeaderMap built with insert() }
    FTrailers := THttpHeaders.Create(4, 256);
    for I := 0 to High(B^.Trailers) do
      FTrailers.Insert(B^.Trailers[I].Name, B^.Trailers[I].Value);
  end;
end;

destructor TScriptBody.Destroy;
begin
  FTrailers.Free;
  inherited Destroy;
end;

function TScriptBody.PollFrame(Ex: TExchange; out Data: TBodyData;
  out Trailers: THttpHeaders): TFramePoll;
var
  It: ^TStreamItem;
begin
  Data := BodyEmpty;
  Trailers := nil;
  while True do
  begin
    if FSleeping then
    begin
      if not FDelay.Fired then
        Exit(fpPending);
      FSleeping := False;
      FSlept := True;
    end;
    if FPos > High(Spec^.Items) then
    begin
      { Ready(self.trailers.take().map(Frame::trailers)) }
      if (FTrailers <> nil) and not FTrailersSent then
      begin
        FTrailersSent := True;
        Trailers := FTrailers;
        Exit(fpTrailers);
      end;
      Exit(fpEnd);
    end;
    It := @Spec^.Items[FPos];
    if (It^.DelayMs > 0) and not FSlept then
    begin
      FDelay.Arm(Ex, Int64(It^.DelayMs));
      FSleeping := True;
      Continue;
    end;
    FSlept := False;
    Inc(FPos);
    if It^.Kind = siData then
    begin
      Data := BodyString(It^.Data);
      Exit(fpData);
    end;
    Ex.SetBodyErrorText(It^.Message);
    Exit(fpError);
  end;
end;

procedure TScriptBody.Done(Ex: TExchange);
begin
  if FDelay.T.Proc <> nil then
    FDelay.Cancel(Ex);
  Free;
end;

end.
