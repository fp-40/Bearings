{ bearings.capi - the server as a C library, for programs written in other
  languages (the Python package under python/ uses it through cffi).

  src/capi/libbearings.pas exports these routines from a shared library
  (libbearings.so) and src/capi/bearings.h declares them for C. Every name
  starts with bearings_; every routine is cdecl and lets no Pascal exception
  out: a failure is a return value.

  The model is the one of examples/worker.pas: every request is handed to
  the worker pool, and a worker calls the application's callback with the
  exchange and the request head. The callback may block (it reads the
  body, it waits for a database); it answers with exactly one of
  bearings_respond, bearings_respond_file or bearings_begin_stream (then
  bearings_write and bearings_finish or bearings_abort_stream) before it
  returns. The exchange pointer is valid only during the callback. A
  callback that returns without answering gets a 500 answer.

  The request head reaches the callback as one buffer of fields, each
  ended by a NUL byte: the method, the path (as received, percent-escapes
  kept), the query (without the '?'; empty when there is none), the
  version ("HTTP/1.1"), the client's address (empty on a Unix socket), the
  client's port (decimal; empty on a Unix socket), then a name and a value
  for each header field, in the order received. The parser refuses NUL in
  every one of them, so the separators are unambiguous. The buffer is
  valid only during the callback.

  Response header lists use the same layout: a name, NUL, a value, NUL,
  for each field. Names and values are validated (bearings.http.headers);
  an invalid one fails the call with BEARINGS_BAD_HEADER and leaves the
  response head empty, so the caller can still answer, for example with
  a 500.

  Threading. bearings_server_new, bearings_server_wait and
  bearings_server_free run on one owning thread; bearings_server_stop on
  any thread. The exchange routines run on the worker that runs the
  callback. Signals: bearings_server_new blocks every signal while it
  starts the server's threads, which inherit that mask, so the process's
  signals go to the threads of the host program (an interpreter that
  handles SIGINT on its main thread keeps doing so). }
unit bearings.capi;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$packrecords c}

interface

uses
  ctypes, bearings.rt.loop, bearings.http.exchange, bearings.server.accesslog, bearings.server;

const
  BEARINGS_OK = 0;
  { the exchange was canceled (the client went away) or already answered }
  BEARINGS_CANCELED = 1;
  BEARINGS_BAD_HEADER = -1;
  { bearings_read: the body could not be read (malformed, too slow, ...) }
  BEARINGS_BAD_BODY = -1;
  { bearings_read: the client disconnected }
  BEARINGS_CLIENT_GONE = -2;
  BEARINGS_ERROR = -3;

  { bearings_ws_send: the connection's output is at its high-water mark }
  BEARINGS_FULL = 2;
  { a topic or pattern that is not valid (bearings.ws.topics) }
  BEARINGS_INVALID = -1;

  { the events of a WebSocket (TBearingsWsCb) }
  BEARINGS_WS_OPENED = 1;
  BEARINGS_WS_TEXT = 2;
  BEARINGS_WS_BINARY = 3;
  BEARINGS_WS_CLOSED = 4;

  BEARINGS_ACCESS_LOG_OFF = 0;
  BEARINGS_ACCESS_LOG_JSON = 1;
  BEARINGS_ACCESS_LOG_COMBINED = 2;

type
  { Zeroed fields take the defaults of ProductionServerConfig. }
  TBearingsConfig = record
    Host: PAnsiChar;               { nil or '' = '0.0.0.0' }
    Port: cint;                    { 0 = a free port (bearings_server_port) }
    UnixPath: PAnsiChar;           { nil or '' = TCP }
    UnixMode: cint;                { 0 = &660 }
    InheritedFd: cint;             { > 0: an open listening socket }
    Loops: cint;                   { 0 = one per CPU }
    Workers: cint;                 { 0 = Min(32, CPUs + 4) }
    WorkerQueueLimit: cint;        { 0 = no limit }
    SaturatedStatus: cint;         { with a queue limit: answered when the queue is full (503) }
    MaxConnections: cint;          { 0 = no limit }
    AccessLog: cint;               { BEARINGS_ACCESS_LOG_* (stdout) }
    Metrics: cint;                 { 1 = keep the counters of bearings_metrics }
    { WebSockets: accepted on this path (nil or '' = none); see the unit header }
    WsPath: PAnsiChar;
    WsOrigins: PAnsiChar;          { the Origin values allowed, one per line }
    WsSameHost: cint;              { 1 = also an Origin whose host[:port] is the Host header }
    WsAnyPort: cint;               { 1 = also any port of the Host header's name (development) }
    WsPingMs: cint;                { 0 = 25 000; -1 = no pings }
    WsIdleMs: cint;                { 0 = 60 000; -1 = no idle timeout }
    WsMaxMessage: cint64;          { 0 = 16 MiB }
    WsSendHighWater: cint64;       { 0 = 1 MiB }
    WsCloseOnBackpressure: cint;   { 1 = a subscriber that is behind is closed, not skipped }
    WsIgnoreText: PAnsiChar;       { a text message equal to this never reaches the callback }
  end;
  PBearingsConfig = ^TBearingsConfig;

  TBearingsRequestCb = procedure(Ctx: Pointer; Ex: TExchange; Head: PAnsiChar;
    Len: csize_t); cdecl;
  { One event of a WebSocket, on a worker thread; the events of one
    connection come one at a time, in order. Data: the handshake's head
    (BEARINGS_WS_OPENED, the layout of the request head), the message, or
    the close code in decimal, NUL and the client's reason (BEARINGS_WS_CLOSED,
    always the last). Valid during the call. }
  TBearingsWsCb = procedure(Ctx: Pointer; Event: cint; Id: cuint64; Data: PAnsiChar;
    Len: csize_t); cdecl;

function bearings_version: PAnsiChar; cdecl;

{ Creates and starts a server. nil on failure, with the reason in Err (at
  most ErrLen bytes, NUL included). }
function bearings_server_new(Cfg: PBearingsConfig; Cb: TBearingsRequestCb;
  WsCb: TBearingsWsCb; Ctx: Pointer; Err: PAnsiChar; ErrLen: csize_t): Pointer; cdecl;
{ The port it listens on (0 on a Unix socket). }
function bearings_server_port(Srv: Pointer): cint; cdecl;
{ Starts the graceful shutdown and returns: the listeners close, the open
  connections finish their requests for at most GraceMs. Any thread. }
procedure bearings_server_stop(Srv: Pointer; GraceMs: cint); cdecl;
{ Blocks until the server stopped and the worker pool finished. }
procedure bearings_server_wait(Srv: Pointer); cdecl;
procedure bearings_server_free(Srv: Pointer); cdecl;
{ The Prometheus text of the counters (Metrics = 1). Returns its length;
  when that is >= Len, nothing was copied and the caller retries with a
  larger buffer. }
function bearings_metrics(Srv: Pointer; Buf: PAnsiChar; Len: csize_t): csize_t; cdecl;

{ Up to Max bytes of the request body into Buf; blocks. 0 at the end of the
  body; BEARINGS_BAD_BODY or BEARINGS_CLIENT_GONE. }
function bearings_read(Ex: TExchange; Buf: PByte; Max: csize_t): PtrInt; cdecl;
{ The text of the last BEARINGS_BAD_BODY; the same length rule as bearings_metrics. }
function bearings_body_error(Ex: TExchange; Buf: PAnsiChar; Len: csize_t): csize_t; cdecl;
function bearings_is_canceled(Ex: TExchange): cint; cdecl;

{ A response with a body of known length; the body is copied. }
function bearings_respond(Ex: TExchange; Status: cint; Headers: PAnsiChar; HLen: csize_t;
  Body: PByte; BLen: csize_t): cint; cdecl;
{ A response whose body is Len bytes of the file Fd from Offset, sent with
  sendfile(2). The server owns Fd from the call on and closes it, even
  when the call fails. }
function bearings_respond_file(Ex: TExchange; Status: cint; Headers: PAnsiChar; HLen: csize_t;
  Fd: cint; Offset, Len: cint64): cint; cdecl;
{ A response whose body follows with bearings_write: chunked, unless the
  headers hold a Content-Length. }
function bearings_begin_stream(Ex: TExchange; Status: cint; Headers: PAnsiChar;
  HLen: csize_t): cint; cdecl;
{ Blocks while the client is behind; BEARINGS_CANCELED when it went away. }
function bearings_write(Ex: TExchange; P: PByte; Len: csize_t): cint; cdecl;
function bearings_finish(Ex: TExchange): cint; cdecl;
{ Ends the stream with an error: the client sees a truncated body. }
procedure bearings_abort_stream(Ex: TExchange; Msg: PAnsiChar); cdecl;

{ ---- WebSockets, by the id BEARINGS_WS_OPENED gave; any thread ---- }

{ BEARINGS_OK, BEARINGS_FULL (nothing was queued), or BEARINGS_CANCELED:
  the connection is closing or gone. }
function bearings_ws_send(Srv: Pointer; Id: cuint64; Data: PByte; Len: csize_t): cint; cdecl;
{ Starts the close handshake; BEARINGS_CANCELED when it is already closing or gone. }
function bearings_ws_close(Srv: Pointer; Id: cuint64; Code: cint; Reason: PAnsiChar): cint; cdecl;
{ Subscribes to a topic or a pattern of topics (bearings.ws.topics: '/'
  levels, '+' and '#' wildcards); BEARINGS_INVALID for one that is not valid. }
function bearings_ws_subscribe(Srv: Pointer; Id: cuint64; Topic: PAnsiChar; Len: csize_t): cint; cdecl;
function bearings_ws_unsubscribe(Srv: Pointer; Id: cuint64; Topic: PAnsiChar; Len: csize_t): cint; cdecl;
{ A text message to every subscriber of Topic, encoded once. BEARINGS_INVALID
  for a topic that is not valid, BEARINGS_CANCELED after the server stopped. }
function bearings_ws_publish(Srv: Pointer; Topic: PAnsiChar; TLen: csize_t; Data: PByte;
  Len: csize_t): cint; cdecl;
{ The WebSockets open. }
function bearings_ws_count(Srv: Pointer): csize_t; cdecl;

implementation

uses
  SysUtils, BaseUnix, SyncObjs, Generics.Collections, bearings.rt.sys, bearings.rt.buf,
  bearings.rt.net, bearings.http.headers, bearings.http1.role, bearings.ws.handshake,
  bearings.ws.conn, bearings.ws.topics, bearings.version;

const
  HEAD_STACK_BYTES = 8192;

type
  THandler = class(TBlockingHandler)
  public
    Cb: TBearingsRequestCb;
    Ctx: Pointer;
    procedure Run(Ex: TExchange); override;
  end;

  TCServer = class;

  { The handshake of a WebSocket, on the loop: the Origin, then the upgrade. }
  TWsCall = class(TServiceCall)
  public
    Owner: TCServer;
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TService = class(THttpService)
  private
    FOwner: TCServer;
    FCall: TOffloadCall;
    FWsCall: TWsCall;
  public
    constructor Create(AOwner: TCServer; ACall: TOffloadCall);
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  { A WebSocket's events, on the worker pool, handed to the callback. }
  TCWsHandler = class(TWsWorkerHandler)
  public
    Owner: TCServer;
    Id: QWord;
    Head: RawByteString;             { the handshake, until OnOpen hands it over }
    procedure OnOpen(WS: TWebSocket); override;
    procedure OnText(WS: TWebSocket; const Msg: RawByteString); override;
    procedure OnBinary(WS: TWebSocket; const Msg: RawByteString); override;
    procedure OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString); override;
  end;

  TSocketMap = specialize TDictionary<QWord, TWebSocket>;

  TCServer = class
  public
    Srv: TServer;
    Handler: THandler;
    SaturatedStatus: Word;
    Ctx: Pointer;
    { WebSockets }
    WsPath: RawByteString;
    WsCb: TBearingsWsCb;
    WsCfg: TWsConfig;
    Origins: array of RawByteString; { lowercase, without a trailing '/' }
    SameHost, AnyPort: Boolean;
    IgnoreText: RawByteString;
    Topics: TWsTopics;
    Stopped: Boolean;                { no publish after the stop }
    Lock: TCriticalSection;
    Sockets: TSocketMap;             { by id; each holds a reference }
    NextId: QWord;
    destructor Destroy; override;
    function NewService(Loop: TLoop): THttpService;
    function OriginAllowed(Ex: TExchange): Boolean;
    function Register(WS: TWebSocket): QWord;
    procedure Unregister(Id: QWord);
    { the connection with a reference the caller releases, or nil }
    function Acquire(Id: QWord): TWebSocket;
  end;

{ ---- the request head buffer ---- }

type
  THeadWriter = record
    P: PByte;
    Len, Cap: SizeInt;
    Heap: Boolean;
    procedure Put(Src: PByte; N: SizeInt);
    procedure PutStr(const S: RawByteString);
  end;

procedure THeadWriter.Put(Src: PByte; N: SizeInt);
var
  NewCap: SizeInt;
  NewP: PByte;
begin
  if Len + N + 1 > Cap then
  begin
    NewCap := 2 * Cap;
    while Len + N + 1 > NewCap do
      NewCap := 2 * NewCap;
    NewP := GetMem(NewCap);
    Move(P^, NewP^, Len);
    if Heap then
      FreeMem(P);
    P := NewP;
    Cap := NewCap;
    Heap := True;
  end;
  if N > 0 then
    Move(Src^, P[Len], N);
  P[Len + N] := 0;
  Inc(Len, N + 1);
end;

procedure THeadWriter.PutStr(const S: RawByteString);
begin
  Put(PByte(S), Length(S));
end;

const
  VERSION_TEXT: array[THttpVersion] of RawByteString =
    ('HTTP/0.9', 'HTTP/1.0', 'HTTP/1.1', 'HTTP/2', 'HTTP/3');

procedure WriteHead(Ex: TExchange; var W: THeadWriter);
var
  S: TByteSlice;
  H: THttpHeaders;
  I: SizeInt;
  Peer: PSockAddrStorage;
begin
  S := Ex.MethodBytes;
  W.Put(S.P, S.Len);
  S := Ex.Path;
  W.Put(S.P, S.Len);
  if Ex.Query(S) then
    W.Put(S.P, S.Len)
  else
    W.Put(nil, 0);
  W.PutStr(VERSION_TEXT[Ex.Version]);
  Peer := Ex.PeerAddr;
  W.PutStr(SockAddrToStr(Peer^));
  if (Peer^.Family = AF_INET) or (Peer^.Family = AF_INET6) then
    W.PutStr(IntToStr(SockAddrPort(Peer^)))
  else
    W.Put(nil, 0);
  H := Ex.Headers;
  for I := 0 to H.Count - 1 do
  begin
    W.Put(H.NamePtr(I), H.NameLen(I));
    W.Put(H.ValuePtr(I), H.ValueLen(I));
  end;
end;

{ The head as a string, for a WebSocket's open event (the exchange is gone by then). }
function HeadString(Ex: TExchange): RawByteString;
var
  Stack: array[0..HEAD_STACK_BYTES - 1] of Byte;
  W: THeadWriter;
begin
  W.P := @Stack[0];
  W.Len := 0;
  W.Cap := HEAD_STACK_BYTES;
  W.Heap := False;
  try
    WriteHead(Ex, W);
    SetString(Result, PAnsiChar(W.P), W.Len);
  finally
    if W.Heap then
      FreeMem(W.P);
  end;
end;

procedure THandler.Run(Ex: TExchange);
var
  Stack: array[0..HEAD_STACK_BYTES - 1] of Byte;
  W: THeadWriter;
begin
  W.P := @Stack[0];
  W.Len := 0;
  W.Cap := HEAD_STACK_BYTES;
  W.Heap := False;
  try
    WriteHead(Ex, W);
    Cb(Ctx, Ex, PAnsiChar(W.P), W.Len);
    if not Ex.Answered then
      Ex.RespondText(500, 'the application gave no response'#10);
  finally
    if W.Heap then
      FreeMem(W.P);
  end;
end;

constructor TService.Create(AOwner: TCServer; ACall: TOffloadCall);
begin
  inherited Create;
  FOwner := AOwner;
  FCall := ACall;
  if AOwner.WsPath <> '' then
  begin
    FWsCall := TWsCall.Create;
    FWsCall.Owner := AOwner;
  end;
end;

destructor TService.Destroy;
begin
  FCall.Free;
  FWsCall.Free;
  inherited Destroy;
end;

function TService.Call(Ex: TExchange): TServiceCall;
begin
  if (FWsCall <> nil) and Ex.WantsUpgrade and PathIs(Ex, FOwner.WsPath) then
    Result := FWsCall
  else
    Result := FCall;
end;

function TWsCall.Poll(Ex: TExchange): TCallPoll;
var
  R: TWsHandshake;
  H: TCWsHandler;
begin
  Result := cpReady;
  if not Owner.OriginAllowed(Ex) then
  begin
    Ex.RespondText(403, 'origin not allowed'#10);
    Exit;
  end;
  R := CheckRequest(Ex, []);
  if not R.Ok then
  begin
    RespondHandshakeError(Ex, R);
    Exit;
  end;
  H := TCWsHandler.Create;
  H.Owner := Owner;
  H.Head := HeadString(Ex);
  AcceptWebSocket(Ex, R, H, Owner.Srv.Workers, Owner.WsCfg);
end;

procedure TCWsHandler.OnOpen(WS: TWebSocket);
var
  H: RawByteString;
begin
  Id := Owner.Register(WS);
  H := Head;
  Head := '';
  Owner.WsCb(Owner.Ctx, BEARINGS_WS_OPENED, Id, PAnsiChar(H), Length(H));
end;

procedure TCWsHandler.OnText(WS: TWebSocket; const Msg: RawByteString);
begin
  if (Owner.IgnoreText <> '') and (Msg = Owner.IgnoreText) then
    Exit;
  Owner.WsCb(Owner.Ctx, BEARINGS_WS_TEXT, Id, PAnsiChar(Msg), Length(Msg));
end;

procedure TCWsHandler.OnBinary(WS: TWebSocket; const Msg: RawByteString);
begin
  Owner.WsCb(Owner.Ctx, BEARINGS_WS_BINARY, Id, PAnsiChar(Msg), Length(Msg));
end;

procedure TCWsHandler.OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString);
var
  S: RawByteString;
begin
  if Id = 0 then
    Exit;                          { it ended before it opened }
  Owner.Unregister(Id);
  S := IntToStr(Code) + #0 + Reason;
  Owner.WsCb(Owner.Ctx, BEARINGS_WS_CLOSED, Id, PAnsiChar(S), Length(S));
end;

destructor TCServer.Destroy;
begin
  Topics.Free;
  Sockets.Free;
  Lock.Free;
  inherited Destroy;
end;

function TCServer.NewService(Loop: TLoop): THttpService;
var
  C: TOffloadCall;
begin
  C := TOffloadCall.Create;
  C.Pool := Srv.Workers;
  C.Handler := Handler;
  C.SaturatedStatus := SaturatedStatus;
  Result := TService.Create(Self, C);
end;

{ The name of host[:port] (an IPv6 address keeps its brackets). }
function HostName(const HostPort: RawByteString): RawByteString;
var
  I: SizeInt;
begin
  if (HostPort <> '') and (HostPort[1] = '[') then
  begin
    I := Pos(']', HostPort);
    if I = 0 then
      Exit('');
    Exit(Copy(HostPort, 1, I));
  end;
  I := Pos(':', HostPort);
  if I = 0 then
    Result := HostPort
  else
    Result := Copy(HostPort, 1, I - 1);
end;

{ Allowed: no Origin (not a browser), one in Origins, and with SameHost one
  whose host[:port] is the Host header, with AnyPort any port of its name.
  More than one Origin field is refused. }
function TCServer.OriginAllowed(Ex: TExchange): Boolean;
var
  H: THttpHeaders;
  I, At: SizeInt;
  Origin, Host, NetLoc: RawByteString;
  V: TByteSlice;
begin
  H := Ex.Headers;
  if H.CountOf('origin') > 1 then
    Exit(False);
  if not Ex.Header('origin', V) then
    Exit(True);
  Origin := LowerCase(Trim(SliceToStr(V)));
  while (Origin <> '') and (Origin[Length(Origin)] = '/') do
    SetLength(Origin, Length(Origin) - 1);
  for I := 0 to High(Origins) do
    if Origin = Origins[I] then
      Exit(True);
  if not (SameHost or AnyPort) then
    Exit(False);
  At := Pos('://', Origin);
  if (At = 0) or not Ex.Header('host', V) then
    Exit(False);
  NetLoc := Copy(Origin, At + 3, MaxInt);
  Host := LowerCase(Trim(SliceToStr(V)));
  if NetLoc = '' then
    Exit(False);
  if SameHost and (NetLoc = Host) then
    Exit(True);
  Result := AnyPort and (HostName(NetLoc) <> '') and (HostName(NetLoc) = HostName(Host));
end;

function TCServer.Register(WS: TWebSocket): QWord;
begin
  WS.AddRef;                       { the worker's job holds one: allowed here }
  Lock.Acquire;
  try
    Inc(NextId);
    Result := NextId;
    Sockets.Add(Result, WS);
  finally
    Lock.Release;
  end;
end;

procedure TCServer.Unregister(Id: QWord);
var
  WS: TWebSocket;
begin
  Lock.Acquire;
  try
    if not Sockets.TryGetValue(Id, WS) then
      Exit;
    Sockets.Remove(Id);
  finally
    Lock.Release;
  end;
  WS.Release;
end;

function TCServer.Acquire(Id: QWord): TWebSocket;
begin
  Lock.Acquire;
  try
    if Sockets.TryGetValue(Id, Result) then
      Result.AddRef                { the map holds a reference meanwhile }
    else
      Result := nil;
  finally
    Lock.Release;
  end;
end;

{ ---- helpers ---- }

procedure CopyOut(const S: RawByteString; Buf: PAnsiChar; Len: csize_t);
var
  N: SizeInt;
begin
  if (Buf = nil) or (Len = 0) then
    Exit;
  N := Length(S);
  if csize_t(N) >= Len then
    N := Len - 1;
  if N > 0 then
    Move(PAnsiChar(S)^, Buf^, N);
  Buf[N] := #0;
end;

{ Fills the response head; False (and an empty header list) on an invalid field. }
function SetHead(Ex: TExchange; Status: cint; Headers: PAnsiChar; HLen: csize_t): Boolean;
var
  RH: THttpHeaders;
  I, NameEnd, ValueEnd, Limit: SizeInt;
begin
  RH := Ex.ResponseHeaders;
  RH.Clear;
  Ex.Status := Word(Status);
  Limit := SizeInt(HLen);
  I := 0;
  while I < Limit do
  begin
    NameEnd := I;
    while (NameEnd < Limit) and (Headers[NameEnd] <> #0) do
      Inc(NameEnd);
    ValueEnd := NameEnd + 1;
    while (ValueEnd < Limit) and (Headers[ValueEnd] <> #0) do
      Inc(ValueEnd);
    if (ValueEnd > Limit) or
      (RH.TryAdd(PByte(Headers + I), NameEnd - I, PByte(Headers + NameEnd + 1),
        ValueEnd - NameEnd - 1) <> hcOk) then
    begin
      RH.Clear;
      Exit(False);
    end;
    I := ValueEnd + 1;
  end;
  Result := True;
end;

function Answer(Accepted: Boolean): cint;
begin
  if Accepted then
    Result := BEARINGS_OK
  else
    Result := BEARINGS_CANCELED;
end;

{ ---- server ---- }

var
  { set once at initialization: C may keep the pointer bearings_version returns }
  VersionText: RawByteString;

function bearings_version: PAnsiChar; cdecl;
begin
  Result := PAnsiChar(VersionText);
end;

{ The WebSocket options of Cfg into C. }
procedure ApplyWsConfig(C: TCServer; Cfg: PBearingsConfig);
var
  List, Line: RawByteString;
  At: SizeInt;
begin
  C.WsPath := Cfg^.WsPath;
  C.WsCfg := DefaultWsConfig;
  if Cfg^.WsPingMs < 0 then
    C.WsCfg.PingIntervalMs := 0
  else if Cfg^.WsPingMs > 0 then
    C.WsCfg.PingIntervalMs := Cfg^.WsPingMs;
  if Cfg^.WsIdleMs < 0 then
    C.WsCfg.IdleTimeoutMs := 0
  else if Cfg^.WsIdleMs > 0 then
    C.WsCfg.IdleTimeoutMs := Cfg^.WsIdleMs;
  if Cfg^.WsMaxMessage > 0 then
    C.WsCfg.MaxMessage := Cfg^.WsMaxMessage;
  if Cfg^.WsSendHighWater > 0 then
    C.WsCfg.SendHighWater := Cfg^.WsSendHighWater;
  C.SameHost := Cfg^.WsSameHost <> 0;
  C.AnyPort := Cfg^.WsAnyPort <> 0;
  if Cfg^.WsIgnoreText <> nil then
    C.IgnoreText := Cfg^.WsIgnoreText;
  List := Cfg^.WsOrigins;           { one per line }
  while List <> '' do
  begin
    At := Pos(#10, List);
    if At = 0 then
      At := Length(List) + 1;
    Line := LowerCase(Trim(Copy(List, 1, At - 1)));
    Delete(List, 1, At);
    while (Line <> '') and (Line[Length(Line)] = '/') do
      SetLength(Line, Length(Line) - 1);
    if Line <> '' then
    begin
      SetLength(C.Origins, Length(C.Origins) + 1);
      C.Origins[High(C.Origins)] := Line;
    end;
  end;
  C.Topics := TWsTopics.Create;
  C.Topics.CloseOnBackpressure := Cfg^.WsCloseOnBackpressure <> 0;
end;

function bearings_server_new(Cfg: PBearingsConfig; Cb: TBearingsRequestCb;
  WsCb: TBearingsWsCb; Ctx: Pointer; Err: PAnsiChar; ErrLen: csize_t): Pointer; cdecl;
var
  SC: TServerConfig;
  C: TCServer;
  All, Old: TSigSet;
begin
  Result := nil;
  C := nil;
  try
    if (Cfg = nil) or (Cb = nil) then
      raise Exception.Create('bearings_server_new: no config or no callback');
    SC := ProductionServerConfig;
    SC.Watchdog := False;          { the host program talks to systemd, if it wants to }
    if (Cfg^.Host <> nil) and (Cfg^.Host^ <> #0) then
      SC.Listen.Host := Cfg^.Host;
    SC.Listen.Port := Word(Cfg^.Port);
    if (Cfg^.UnixPath <> nil) and (Cfg^.UnixPath^ <> #0) then
      SC.Listen.UnixPath := Cfg^.UnixPath;
    SC.Listen.UnixMode := Cardinal(Cfg^.UnixMode);
    SC.Listen.InheritedFd := Cfg^.InheritedFd;
    SC.Loops := Cfg^.Loops;
    if Cfg^.Workers < 0 then
      raise Exception.Create('bearings_server_new: workers must be 0 (the default) or more');
    SC.Workers := Cfg^.Workers;
    SC.WorkerQueueLimit := Cfg^.WorkerQueueLimit;
    SC.MaxConnections := Cfg^.MaxConnections;
    case Cfg^.AccessLog of
      BEARINGS_ACCESS_LOG_OFF: ;
      BEARINGS_ACCESS_LOG_JSON:
        SC.AccessLog.Enabled := True;
      BEARINGS_ACCESS_LOG_COMBINED:
      begin
        SC.AccessLog.Enabled := True;
        SC.AccessLog.Format := alfCombined;
      end;
    else
      raise Exception.Create('bearings_server_new: unknown access log format');
    end;
    SC.Metrics := Cfg^.Metrics <> 0;
    C := TCServer.Create;
    C.Ctx := Ctx;
    C.Lock := TCriticalSection.Create;
    C.Sockets := TSocketMap.Create;
    if (Cfg^.WsPath <> nil) and (Cfg^.WsPath^ <> #0) then
    begin
      if WsCb = nil then
        raise Exception.Create('bearings_server_new: a WebSocket path needs a WebSocket callback');
      C.WsCb := WsCb;
      ApplyWsConfig(C, Cfg);
    end;
    C.SaturatedStatus := Word(Cfg^.SaturatedStatus);
    C.Handler := THandler.Create;
    C.Handler.Cb := Cb;
    C.Handler.Ctx := Ctx;
    C.Srv := TServer.Create(SC, @C.NewService);
    FpSigFillSet(All);
    FpSigProcMask(SIG_BLOCK, @All, @Old);
    try
      C.Srv.Start;
    finally
      FpSigProcMask(SIG_SETMASK, @Old, nil);
    end;
    Result := C;
  except
    on E: Exception do
    begin
      CopyOut(E.Message, Err, ErrLen);
      if C <> nil then
      begin
        C.Srv.Free;
        C.Handler.Free;
        C.Free;
      end;
    end;
  end;
end;

function bearings_server_port(Srv: Pointer): cint; cdecl;
begin
  Result := TCServer(Srv).Srv.Port;
end;

procedure bearings_server_stop(Srv: Pointer; GraceMs: cint); cdecl;
var
  C: TCServer;
begin
  C := TCServer(Srv);
  try
    C.Lock.Acquire;
    C.Stopped := True;             { no publish once the loops may be leaving }
    C.Lock.Release;
    C.Srv.Stop(GraceMs);
  except
    on E: Exception do
      WriteLn(StdErr, 'bearings_server_stop: ', E.Message);
  end;
end;

procedure bearings_server_wait(Srv: Pointer); cdecl;
begin
  try
    TCServer(Srv).Srv.Wait;
  except
    on E: Exception do
      WriteLn(StdErr, 'bearings_server_wait: ', E.Message);
  end;
end;

procedure bearings_server_free(Srv: Pointer); cdecl;
var
  C: TCServer;
begin
  C := TCServer(Srv);
  try
    C.Srv.Free;                    { after this no worker runs the handler }
    C.Handler.Free;
    C.Free;
  except
    on E: Exception do
      WriteLn(StdErr, 'bearings_server_free: ', E.Message);
  end;
end;

function bearings_metrics(Srv: Pointer; Buf: PAnsiChar; Len: csize_t): csize_t; cdecl;
var
  S: RawByteString;
begin
  try
    S := TCServer(Srv).Srv.PrometheusText;
  except
    S := '';
  end;
  Result := Length(S);
  if Result < Len then
    CopyOut(S, Buf, Len);
end;

{ ---- request body ---- }

function bearings_read(Ex: TExchange; Buf: PByte; Max: csize_t): PtrInt; cdecl;
begin
  try
    Result := Ex.Read(Buf, Max);
  except
    on EClientGone do
      Result := BEARINGS_CLIENT_GONE;
    on Exception do
      Result := BEARINGS_BAD_BODY;
  end;
end;

function bearings_body_error(Ex: TExchange; Buf: PAnsiChar; Len: csize_t): csize_t; cdecl;
var
  S: RawByteString;
begin
  try
    S := Ex.BodyErrorMessage;
  except
    S := '';
  end;
  Result := Length(S);
  if Result < Len then
    CopyOut(S, Buf, Len);
end;

function bearings_is_canceled(Ex: TExchange): cint; cdecl;
begin
  Result := Ord(Ex.IsCanceled);
end;

{ ---- response ---- }

function bearings_respond(Ex: TExchange; Status: cint; Headers: PAnsiChar; HLen: csize_t;
  Body: PByte; BLen: csize_t): cint; cdecl;
var
  S: RawByteString;
begin
  try
    if not SetHead(Ex, Status, Headers, HLen) then
      Exit(BEARINGS_BAD_HEADER);
    if BLen = 0 then
      Result := Answer(Ex.Respond(BodyEmpty))
    else
    begin
      SetString(S, PAnsiChar(Body), BLen);
      Result := Answer(Ex.Respond(BodyString(S)));
    end;
  except
    Result := BEARINGS_ERROR;
  end;
end;

function bearings_respond_file(Ex: TExchange; Status: cint; Headers: PAnsiChar; HLen: csize_t;
  Fd: cint; Offset, Len: cint64): cint; cdecl;
begin
  try
    if not SetHead(Ex, Status, Headers, HLen) then
    begin
      FpClose(Fd);
      Exit(BEARINGS_BAD_HEADER);
    end;
    { a refused answer releases the body, which closes Fd }
    Result := Answer(Ex.Respond(BodyFile(Fd, Offset, Len, True)));
  except
    Result := BEARINGS_ERROR;
  end;
end;

function bearings_begin_stream(Ex: TExchange; Status: cint; Headers: PAnsiChar;
  HLen: csize_t): cint; cdecl;
begin
  try
    if not SetHead(Ex, Status, Headers, HLen) then
      Exit(BEARINGS_BAD_HEADER);
    Result := Answer(Ex.BeginStream);
  except
    Result := BEARINGS_ERROR;
  end;
end;

function bearings_write(Ex: TExchange; P: PByte; Len: csize_t): cint; cdecl;
begin
  try
    if Ex.Write(P, Len) = wrOk then
      Result := BEARINGS_OK
    else
      Result := BEARINGS_CANCELED;
  except
    Result := BEARINGS_ERROR;
  end;
end;

function bearings_finish(Ex: TExchange): cint; cdecl;
begin
  try
    Result := Answer(Ex.Finish);
  except
    Result := BEARINGS_ERROR;
  end;
end;

procedure bearings_abort_stream(Ex: TExchange; Msg: PAnsiChar); cdecl;
begin
  try
    Ex.AbortStream(Msg);
  except
  end;
end;

{ ---- WebSockets ---- }

function bearings_ws_send(Srv: Pointer; Id: cuint64; Data: PByte; Len: csize_t): cint; cdecl;
var
  WS: TWebSocket;
  S: RawByteString;
begin
  try
    WS := TCServer(Srv).Acquire(Id);
    if WS = nil then
      Exit(BEARINGS_CANCELED);
    try
      SetString(S, PAnsiChar(Data), Len);
      case WS.PostText(S) of
        wsOk: Result := BEARINGS_OK;
        wsFull: Result := BEARINGS_FULL;
      else
        Result := BEARINGS_CANCELED;
      end;
    finally
      WS.Release;
    end;
  except
    Result := BEARINGS_ERROR;
  end;
end;

function bearings_ws_close(Srv: Pointer; Id: cuint64; Code: cint; Reason: PAnsiChar): cint; cdecl;
var
  WS: TWebSocket;
begin
  try
    WS := TCServer(Srv).Acquire(Id);
    if WS = nil then
      Exit(BEARINGS_CANCELED);
    try
      if WS.PostClose(Word(Code), Reason) then
        Result := BEARINGS_OK
      else
        Result := BEARINGS_CANCELED;
    finally
      WS.Release;
    end;
  except
    Result := BEARINGS_ERROR;
  end;
end;

function Subscription(Srv: Pointer; Id: cuint64; Topic: PAnsiChar; Len: csize_t;
  Subscribe: Boolean): cint;
var
  C: TCServer;
  WS: TWebSocket;
  Pattern: RawByteString;
begin
  try
    C := TCServer(Srv);
    SetString(Pattern, Topic, Len);
    if (C.Topics = nil) or not WsPatternValid(Pattern) then
      Exit(BEARINGS_INVALID);
    WS := C.Acquire(Id);
    if WS = nil then
      Exit(BEARINGS_CANCELED);
    try
      try
        if Subscribe then
          C.Topics.Subscribe(WS, Pattern)
        else
          C.Topics.Unsubscribe(WS, Pattern);
        Result := BEARINGS_OK;
      except
        Result := BEARINGS_CANCELED;   { closing: it can't subscribe }
      end;
    finally
      WS.Release;
    end;
  except
    Result := BEARINGS_ERROR;
  end;
end;

function bearings_ws_subscribe(Srv: Pointer; Id: cuint64; Topic: PAnsiChar; Len: csize_t): cint; cdecl;
begin
  Result := Subscription(Srv, Id, Topic, Len, True);
end;

function bearings_ws_unsubscribe(Srv: Pointer; Id: cuint64; Topic: PAnsiChar; Len: csize_t): cint; cdecl;
begin
  Result := Subscription(Srv, Id, Topic, Len, False);
end;

function bearings_ws_publish(Srv: Pointer; Topic: PAnsiChar; TLen: csize_t; Data: PByte;
  Len: csize_t): cint; cdecl;
var
  C: TCServer;
  T, S: RawByteString;
begin
  try
    C := TCServer(Srv);
    SetString(T, Topic, TLen);
    if (C.Topics = nil) or not WsTopicValid(T) then
      Exit(BEARINGS_INVALID);
    SetString(S, PAnsiChar(Data), Len);
    C.Lock.Acquire;
    try
      if C.Stopped then
        Exit(BEARINGS_CANCELED);
      C.Topics.Publish(T, S);
      Result := BEARINGS_OK;
    finally
      C.Lock.Release;
    end;
  except
    Result := BEARINGS_ERROR;
  end;
end;

function bearings_ws_count(Srv: Pointer): csize_t; cdecl;
var
  C: TCServer;
begin
  C := TCServer(Srv);
  C.Lock.Acquire;
  try
    Result := C.Sockets.Count;
  finally
    C.Lock.Release;
  end;
end;

initialization
  VersionText := bearings.version.BEARINGS_VERSION;  { not the function bearings_version }

end.
