{ The C interface (bearings.capi), over real sockets: the routines a
  program in another language calls, called here from Pascal with cdecl
  callbacks, as the Python package (python/) calls them through cffi.

  TTestCapiHttp: the request head buffer, a body read in pieces, a known
  body, a stream, an aborted stream (the client sees what came before the
  error), a file (sendfile), an invalid response header (refused, and the
  caller answers instead), a callback that answers nothing (500), the
  metrics, the version, and the failures of bearings_server_new.
  TTestCapiWs: a WebSocket's events in order (open with the handshake, text,
  binary, close with the code and reason), sends by id, topics, the close
  from the server, the Origin rules, the ignored text, the WebSockets open,
  and the calls with an id that no connection has; threads that send,
  subscribe, publish and close by id while connections end under them
  (also run under drd by run_all.sh, with WD_ITER=20).
  Run: test_capi --all --format=plain }
program test_capi;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WD_DRD}cmem,{$ENDIF}            { the C heap: drd sees the blocks (as test_ws_echo) }
  Classes, SysUtils, SyncObjs, fpcunit, testregistry, consoletestrunner, Sockets, BaseUnix,
  ctypes, bearings.version, bearings.rt.sync, bearings.http.exchange, bearings.ws.frame, bearings.test.ws,
  bearings.capi;

const
  CRLF = #13#10;

{ ---- what the callbacks saw, read by the tests under Lock ---- }

var
  Lock: TCriticalSection;
  LastHead: RawByteString;           { the last request head buffer }
  BadHeaderResult: cint;             { what bearings_respond answered to /bad }
  WsEvents: TStringList;             { 'open <id> <path>', 'text <id> <msg>', ... }
  WsLastId: cuint64;
  TheServer: Pointer;                { for the WebSocket callback: set before any connection }
  FilePath: string;

procedure Log(const S: string);
begin
  Lock.Acquire;
  WsEvents.Add(S);
  Lock.Release;
end;

{ the field I (0 = method) of a head buffer }
function HeadField(const Head: RawByteString; I: Integer): RawByteString;
var
  P, Start, N: Integer;
begin
  Result := '';
  P := 1;
  N := 0;
  Start := 1;
  while P <= Length(Head) do
  begin
    if Head[P] = #0 then
    begin
      if N = I then
        Exit(Copy(Head, Start, P - Start));
      Inc(N);
      Start := P + 1;
    end;
    Inc(P);
  end;
end;

procedure Respond(Ex: TExchange; Status: cint; const Headers, Body: RawByteString);
begin
  bearings_respond(Ex, Status, PAnsiChar(Headers), Length(Headers), PByte(PAnsiChar(Body)),
    Length(Body));
end;

procedure OnRequest(Ctx: Pointer; Ex: TExchange; Head: PAnsiChar; Len: csize_t); cdecl;
var
  H, Path, Body, Chunk: RawByteString;
  Buf: array[0..2] of Byte;            { small: the body comes in pieces }
  N: PtrInt;
  Fd: cint;
begin
  SetString(H, Head, Len);
  Lock.Acquire;
  LastHead := H;
  Lock.Release;
  Path := HeadField(H, 1);
  if Path = '/hello' then
    Respond(Ex, 200, 'content-type'#0'text/plain'#0, 'hello')
  else if Path = '/echo' then
  begin
    Body := '';
    repeat
      N := bearings_read(Ex, @Buf[0], SizeOf(Buf));
      if N > 0 then
      begin
        SetString(Chunk, PAnsiChar(@Buf[0]), N);
        Body := Body + Chunk;
      end;
    until N <= 0;
    Respond(Ex, 200, '', Body);
  end
  else if (Path = '/stream') or (Path = '/abort') then
  begin
    bearings_begin_stream(Ex, 200, nil, 0);
    bearings_write(Ex, PByte(PAnsiChar('ab')), 2);
    bearings_write(Ex, PByte(PAnsiChar('cd')), 2);
    if Path = '/stream' then
      bearings_finish(Ex)
    else
      bearings_abort_stream(Ex, 'gave up');
  end
  else if Path = '/file' then
  begin
    Fd := FpOpen(FilePath, O_RDONLY);
    bearings_respond_file(Ex, 200, nil, 0, Fd, 2, 5);
  end
  else if Path = '/bad' then
  begin
    Lock.Acquire;
    BadHeaderResult := bearings_respond(Ex, 200, 'x-bad'#0'a'#13#10'b'#0, 13, nil, 0);
    Lock.Release;
    Respond(Ex, 500, '', 'refused');
  end;
  { /none: nothing; the server answers 500 }
end;

procedure OnWs(Ctx: Pointer; Event: cint; Id: cuint64; Data: PAnsiChar; Len: csize_t); cdecl;
var
  S, Reply: RawByteString;
  Srv: Pointer;
begin
  SetString(S, Data, Len);
  { set before the first connection; drd cannot see that order through the socket }
  HappensAfter(@TheServer);
  Srv := TheServer;
  case Event of
    BEARINGS_WS_OPENED:
      begin
        Lock.Acquire;
        WsLastId := Id;
        Lock.Release;
        Log('open ' + HeadField(S, 1) + '?' + HeadField(S, 2));
      end;
    BEARINGS_WS_TEXT:
      begin
        Log('text ' + S);
        if S = 'close me' then
          bearings_ws_close(Srv, Id, 4000, 'as asked')
        else
        begin
          Reply := 'echo:' + S;
          bearings_ws_send(Srv, Id, PByte(PAnsiChar(Reply)), Length(Reply));
        end;
      end;
    BEARINGS_WS_BINARY:
      Log('binary ' + IntToStr(Len));
    BEARINGS_WS_CLOSED:
      Log('closed ' + HeadField(S + #0, 0) + ' ' + HeadField(S + #0, 1));
  end;
end;

{ ---- client side ---- }

function Connect(Port: Word): cint;
var
  A: TInetSockAddr;
  TV: TTimeVal;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  A.sin_addr.s_addr := htonl($7F000001);
  if fpConnect(Result, @A, SizeOf(A)) <> 0 then
    raise Exception.Create('connect failed');
  TV.tv_sec := 5;
  TV.tv_usec := 0;
  fpSetSockOpt(Result, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
end;

procedure SendAll(Fd: cint; const S: RawByteString);
begin
  if fpSend(Fd, PAnsiChar(S), Length(S), MSG_NOSIGNAL) <> Length(S) then
    raise Exception.Create('send failed');
end;

{ everything until EOF (or 5 s) }
function RecvAll(Fd: cint): RawByteString;
var
  Buf: array[0..65535] of AnsiChar;
  R: ssize_t;
  S: RawByteString;
begin
  Result := '';
  repeat
    R := fpRecv(Fd, @Buf[0], SizeOf(Buf), 0);
    if R > 0 then
    begin
      SetString(S, PAnsiChar(@Buf[0]), R);
      Result := Result + S;
    end;
  until R <= 0;
end;

{ one request on a connection of its own, and the whole answer }
function Ask(Port: Word; const Request: RawByteString): RawByteString;
var
  Fd: cint;
begin
  Fd := Connect(Port);
  try
    SendAll(Fd, Request);
    Result := RecvAll(Fd);
  finally
    fpClose(Fd);
  end;
end;

function Get(const Path: string): RawByteString;
begin
  Result := 'GET ' + Path + ' HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: close' + CRLF
    + CRLF;
end;

type
  TWsClient = class
    Fd: cint;
    Status: Integer;
    Buf: RawByteString;
    constructor Create(Port: Word; const Path: string; const Extra: RawByteString = '');
    destructor Destroy; override;
    procedure Send(Op: Byte; const Payload: RawByteString);
    { the next frame that is not a ping; opcode 0 on EOF }
    function Next: TServerFrame;
  end;

constructor TWsClient.Create(Port: Word; const Path: string; const Extra: RawByteString);
var
  C: array[0..0] of AnsiChar;
  Head: RawByteString;
begin
  Fd := Connect(Port);
  SendAll(Fd, 'GET ' + Path + ' HTTP/1.1' + CRLF + 'Host: 127.0.0.1:' + IntToStr(Port) + CRLF
    + 'Upgrade: websocket' + CRLF + 'Connection: Upgrade' + CRLF
    + 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' + CRLF + 'Sec-WebSocket-Version: 13' + CRLF
    + Extra + CRLF);
  Head := '';
  while Pos(CRLF + CRLF, Head) = 0 do
  begin
    if fpRecv(Fd, @C[0], 1, 0) <> 1 then
      Break;
    Head := Head + C[0];
  end;
  Status := StrToIntDef(Copy(Head, 10, 3), 0);
end;

destructor TWsClient.Destroy;
begin
  fpClose(Fd);
  inherited Destroy;
end;

procedure TWsClient.Send(Op: Byte; const Payload: RawByteString);
begin
  SendAll(Fd, CFrame(Op, Payload));
end;

function TWsClient.Next: TServerFrame;
var
  Chunk: array[0..65535] of AnsiChar;
  R: ssize_t;
  S: RawByteString;
begin
  while True do
  begin
    while TakeServerFrame(Buf, Result) do
      if Result.Opcode <> WS_OP_PING then
        Exit;
    R := fpRecv(Fd, @Chunk[0], SizeOf(Chunk), 0);
    if R <= 0 then
    begin
      Result := Default(TServerFrame);
      Exit;
    end;
    SetString(S, PAnsiChar(@Chunk[0]), R);
    Buf := Buf + S;
  end;
end;

function CloseCode(const F: TServerFrame): Integer;
begin
  Result := (Ord(F.Payload[1]) shl 8) or Ord(F.Payload[2]);
end;

{ waits up to 5 s for the event log to have Line }
function WaitEvent(const Line: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to 500 do
  begin
    Lock.Acquire;
    Result := WsEvents.IndexOf(Line) >= 0;
    Lock.Release;
    if Result then
      Exit;
    Sleep(10);
  end;
end;

{ ---- the server ---- }

type
  TCapiCase = class(TTestCase)
  protected
    Srv: Pointer;
    Port: Word;
    procedure StartServer(WithWs: Boolean);
    procedure SetUp; override;
    procedure TearDown; override;
  end;

  TTestCapiHttp = class(TCapiCase)
  protected
    procedure SetUp; override;
  published
    procedure The_head_buffer;
    procedure A_body_read_in_pieces;
    procedure A_known_body;
    procedure A_stream;
    procedure An_aborted_stream_sends_what_came_before;
    procedure A_file;
    procedure An_invalid_header_is_refused;
    procedure No_answer_is_a_500;
    procedure The_metrics;
    procedure The_version;
    procedure A_taken_port_fails_with_the_reason;
    procedure Bad_configs_fail;
  end;

  TTestCapiWs = class(TCapiCase)
  protected
    procedure SetUp; override;
  published
    procedure The_events_in_order;
    procedure Topics;
    procedure The_server_closes;
    procedure Origins;
    procedure The_ignored_text;
    procedure Unknown_ids;
    procedure Calls_by_id_while_connections_end;
    procedure Stop_with_websockets_open;
  end;

  { sends, subscribes, publishes and closes by id, over and over }
  THammer = class(TThread)
  public
    Srv: Pointer;
    MaxId, Rounds, Seed: Integer;
    procedure Execute; override;
  end;

procedure TCapiCase.StartServer(WithWs: Boolean);
var
  Cfg: TBearingsConfig;
  Err: array[0..255] of AnsiChar;
  WsCb: TBearingsWsCb;
begin
  Cfg := Default(TBearingsConfig);
  Cfg.Host := '127.0.0.1';
  Cfg.Loops := 1;
  Cfg.Workers := 2;
  Cfg.Metrics := 1;
  WsCb := nil;
  if WithWs then
  begin
    Cfg.WsPath := '/ws';
    Cfg.WsOrigins := 'https://listed.example'#10'  HTTPS://Other.Example/  ';
    Cfg.WsSameHost := 1;
    Cfg.WsIgnoreText := 'PONG';
    WsCb := @OnWs;
  end;
  Srv := bearings_server_new(@Cfg, @OnRequest, WsCb, nil, @Err[0], SizeOf(Err));
  AssertTrue('started: ' + Err, Srv <> nil);
  TheServer := Srv;
  HappensBefore(@TheServer);
  Port := bearings_server_port(Srv);
end;

procedure TCapiCase.SetUp;
begin
  Lock.Acquire;
  LastHead := '';
  WsEvents.Clear;
  Lock.Release;
end;

procedure TCapiCase.TearDown;
begin
  if Srv <> nil then
  begin
    bearings_server_stop(Srv, 1000);
    bearings_server_wait(Srv);
    bearings_server_free(Srv);
    Srv := nil;
  end;
end;

procedure TTestCapiHttp.SetUp;
begin
  inherited SetUp;
  StartServer(False);
end;

procedure TTestCapiWs.SetUp;
begin
  inherited SetUp;
  StartServer(True);
end;

{ ---- HTTP ---- }

procedure TTestCapiHttp.The_head_buffer;
var
  H: RawByteString;
begin
  Ask(Port, 'GET /hello?a=1&b=%20 HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'X-One: 1' + CRLF
    + 'Connection: close' + CRLF + CRLF);
  Lock.Acquire;
  H := LastHead;
  Lock.Release;
  AssertEquals('method', 'GET', HeadField(H, 0));
  AssertEquals('path', '/hello', HeadField(H, 1));
  AssertEquals('query', 'a=1&b=%20', HeadField(H, 2));
  AssertEquals('version', 'HTTP/1.1', HeadField(H, 3));
  AssertEquals('peer', '127.0.0.1', HeadField(H, 4));
  AssertTrue('peer port', StrToIntDef(HeadField(H, 5), 0) > 0);
  AssertEquals('first header', 'Host', HeadField(H, 6));
  AssertEquals('its value', 'x', HeadField(H, 7));
  AssertEquals('second header', 'X-One', HeadField(H, 8));
  AssertEquals('its value', '1', HeadField(H, 9));
end;

procedure TTestCapiHttp.A_body_read_in_pieces;
var
  A: RawByteString;
begin
  A := Ask(Port, 'POST /echo HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 11' + CRLF
    + 'Connection: close' + CRLF + CRLF + 'hello world');
  AssertTrue(A, Pos('HTTP/1.1 200 OK', A) = 1);
  AssertTrue(A, Copy(A, Length(A) - 10, 11) = 'hello world');
end;

procedure TTestCapiHttp.A_known_body;
var
  A: RawByteString;
begin
  A := Ask(Port, Get('/hello'));
  AssertTrue(A, Pos('content-type: text/plain', A) > 0);
  AssertTrue(A, Pos('content-length: 5', A) > 0);
  AssertTrue(A, Copy(A, Length(A) - 4, 5) = 'hello');
end;

procedure TTestCapiHttp.A_stream;
var
  A: RawByteString;
begin
  A := Ask(Port, Get('/stream'));
  AssertTrue(A, Pos('transfer-encoding: chunked', A) > 0);
  AssertTrue(A, Pos('2' + CRLF + 'ab' + CRLF + '2' + CRLF + 'cd' + CRLF + '0' + CRLF + CRLF, A) > 0);
end;

procedure TTestCapiHttp.An_aborted_stream_sends_what_came_before;
var
  A: RawByteString;
begin
  A := Ask(Port, Get('/abort'));
  AssertTrue(A, Pos('HTTP/1.1 200 OK', A) = 1);
  AssertTrue(A, Pos('2' + CRLF + 'ab' + CRLF + '2' + CRLF + 'cd' + CRLF, A) > 0);
  AssertTrue('no last chunk', Pos('0' + CRLF + CRLF, A) = 0);
end;

procedure TTestCapiHttp.A_file;
var
  A: RawByteString;
begin
  A := Ask(Port, Get('/file'));
  AssertTrue(A, Pos('content-length: 5', A) > 0);
  AssertTrue(A, Copy(A, Length(A) - 4, 5) = '23456');
end;

procedure TTestCapiHttp.An_invalid_header_is_refused;
var
  A: RawByteString;
  R: cint;
begin
  A := Ask(Port, Get('/bad'));
  Lock.Acquire;
  R := BadHeaderResult;
  Lock.Release;
  AssertEquals('refused', BEARINGS_BAD_HEADER, R);
  AssertTrue(A, Pos('HTTP/1.1 500', A) = 1);
  AssertTrue('the bad header never went out', Pos('x-bad', A) = 0);
end;

procedure TTestCapiHttp.No_answer_is_a_500;
var
  A: RawByteString;
begin
  A := Ask(Port, Get('/none'));
  AssertTrue(A, Pos('HTTP/1.1 500', A) = 1);
  AssertTrue(A, Pos('the application gave no response', A) > 0);
end;

procedure TTestCapiHttp.The_metrics;
var
  Buf: array[0..65535] of AnsiChar;
  N: csize_t;
  Text: RawByteString;
begin
  Ask(Port, Get('/hello'));
  AssertTrue('the length when the buffer is too small', bearings_metrics(Srv, nil, 0) > 0);
  N := bearings_metrics(Srv, @Buf[0], SizeOf(Buf));
  SetString(Text, PAnsiChar(@Buf[0]), N);
  AssertTrue(Text, Pos('bearings_requests_total 1', Text) > 0);
end;

procedure TTestCapiHttp.The_version;
begin
  AssertEquals(BEARINGS_VERSION, StrPas(bearings_version));
end;

procedure TTestCapiHttp.A_taken_port_fails_with_the_reason;
var
  Cfg: TBearingsConfig;
  Err: array[0..255] of AnsiChar;
  Fd: cint;
  A: TInetSockAddr;
  L: TSockLen;
  Other: Pointer;
begin
  { taken by a socket without SO_REUSEPORT (another server of this kind
    would share the port) }
  Fd := fpSocket(AF_INET, SOCK_STREAM, 0);
  A := Default(TInetSockAddr);
  A.sin_family := AF_INET;
  A.sin_addr.s_addr := htonl($7F000001);
  AssertEquals(0, fpBind(Fd, @A, SizeOf(A)));
  AssertEquals(0, fpListen(Fd, 1));
  L := SizeOf(A);
  fpGetSockName(Fd, @A, @L);
  try
    Cfg := Default(TBearingsConfig);
    Cfg.Host := '127.0.0.1';
    Cfg.Port := ntohs(A.sin_port);
    Cfg.Loops := 1;
    Other := bearings_server_new(@Cfg, @OnRequest, nil, nil, @Err[0], SizeOf(Err));
    if Other <> nil then
      bearings_server_free(Other);
    AssertTrue('refused', Other = nil);
    AssertTrue(StrPas(@Err[0]), Pos('errno 98', StrPas(@Err[0])) > 0);
  finally
    fpClose(Fd);
  end;
end;

procedure TTestCapiHttp.Bad_configs_fail;
var
  Cfg: TBearingsConfig;
  Err: array[0..255] of AnsiChar;
begin
  Cfg := Default(TBearingsConfig);
  AssertTrue('no callback', bearings_server_new(@Cfg, nil, nil, nil, @Err[0], SizeOf(Err)) = nil);
  AssertTrue(StrPas(@Err[0]), Pos('no callback', StrPas(@Err[0])) > 0);
  Cfg.Workers := -1;
  AssertTrue(bearings_server_new(@Cfg, @OnRequest, nil, nil, @Err[0], SizeOf(Err)) = nil);
  AssertTrue(StrPas(@Err[0]), Pos('workers', StrPas(@Err[0])) > 0);
  Cfg.Workers := 0;
  Cfg.AccessLog := 9;
  AssertTrue(bearings_server_new(@Cfg, @OnRequest, nil, nil, @Err[0], SizeOf(Err)) = nil);
  AssertTrue(StrPas(@Err[0]), Pos('access log', StrPas(@Err[0])) > 0);
  Cfg.AccessLog := 0;
  Cfg.WsPath := '/ws';
  AssertTrue(bearings_server_new(@Cfg, @OnRequest, nil, nil, @Err[0], SizeOf(Err)) = nil);
  AssertTrue(StrPas(@Err[0]), Pos('WebSocket callback', StrPas(@Err[0])) > 0);
end;

{ ---- WebSockets ---- }

procedure TTestCapiWs.The_events_in_order;
var
  C: TWsClient;
  F: TServerFrame;
begin
  C := TWsClient.Create(Port, '/ws?room=1');
  try
    AssertEquals('upgraded', 101, C.Status);
    AssertTrue('opened with its path and query', WaitEvent('open /ws?room=1'));
    AssertEquals('one open', 1, Integer(bearings_ws_count(Srv)));
    C.Send(WS_OP_TEXT, 'hola');
    F := C.Next;
    AssertEquals('echoed', 'echo:hola', F.Payload);
    C.Send(WS_OP_BINARY, #0#1#2);
    AssertTrue(WaitEvent('binary 3'));
    C.Send(WS_OP_CLOSE, #$0F#$A0 + 'bye');     { 4000 }
    F := C.Next;
    AssertEquals('the close echoed', WS_OP_CLOSE, Integer(F.Opcode));
    fpShutdown(C.Fd, SHUT_WR);
    AssertTrue('closed with the code and reason', WaitEvent('closed 4000 bye'));
  finally
    C.Free;
  end;
  Lock.Acquire;
  AssertEquals('in order', 'open /ws?room=1|text hola|binary 3|closed 4000 bye',
    StringReplace(Trim(WsEvents.Text), LineEnding, '|', [rfReplaceAll]));
  Lock.Release;
end;

procedure TTestCapiWs.Topics;
var
  C: TWsClient;
  Id: cuint64;
  Msg: RawByteString;
begin
  C := TWsClient.Create(Port, '/ws');
  try
    AssertTrue(WaitEvent('open /ws?'));
    Lock.Acquire;
    Id := WsLastId;
    Lock.Release;
    AssertEquals('subscribed', BEARINGS_OK, bearings_ws_subscribe(Srv, Id, 'room/+', 6));
    Msg := 'to the room';
    AssertEquals('published', BEARINGS_OK,
      bearings_ws_publish(Srv, 'room/1', 6, PByte(PAnsiChar(Msg)), Length(Msg)));
    AssertEquals(Msg, C.Next.Payload);
    AssertEquals('unsubscribed', BEARINGS_OK, bearings_ws_unsubscribe(Srv, Id, 'room/+', 6));
    bearings_ws_publish(Srv, 'room/1', 6, PByte(PAnsiChar(Msg)), Length(Msg));
    Msg := 'only this';
    bearings_ws_send(Srv, Id, PByte(PAnsiChar(Msg)), Length(Msg));
    AssertEquals('the publish after the unsubscribe missed it', Msg, C.Next.Payload);
    AssertEquals('an invalid pattern', BEARINGS_INVALID,
      bearings_ws_subscribe(Srv, Id, 'a/#/b', 5));
    AssertEquals('an invalid topic', BEARINGS_INVALID,
      bearings_ws_publish(Srv, 'a/+', 3, PByte(PAnsiChar(Msg)), Length(Msg)));
  finally
    C.Free;
  end;
end;

procedure TTestCapiWs.The_server_closes;
var
  C: TWsClient;
  F: TServerFrame;
begin
  C := TWsClient.Create(Port, '/ws');
  try
    C.Send(WS_OP_TEXT, 'close me');
    F := C.Next;
    AssertEquals(WS_OP_CLOSE, Integer(F.Opcode));
    AssertEquals('the code', 4000, CloseCode(F));
    C.Send(WS_OP_CLOSE, F.Payload);
    fpShutdown(C.Fd, SHUT_WR);       { as a browser closes its side }
    AssertTrue(WaitEvent('closed 4000 as asked'));
  finally
    C.Free;
  end;
end;

procedure TTestCapiWs.Stop_with_websockets_open;
var
  C, D: TWsClient;
  F: TServerFrame;
  I: Integer;
begin
  { a stop with two connections open: one answers the close, one does not
    (closed at the deadline). Both get their closed event, the registry
    is empty once the server stopped, and freeing it leaks nothing (the
    heaptrc run of this suite). }
  C := TWsClient.Create(Port, '/ws');
  D := TWsClient.Create(Port, '/ws');
  try
    for I := 1 to 500 do
      if bearings_ws_count(Srv) = 2 then
        Break
      else
        Sleep(10);
    AssertEquals('two open', 2, Integer(bearings_ws_count(Srv)));
    bearings_server_stop(Srv, 300);
    F := C.Next;
    AssertEquals('C: the close', WS_OP_CLOSE, Integer(F.Opcode));
    AssertEquals('C: going away', 1001, CloseCode(F));
    C.Send(WS_OP_CLOSE, F.Payload);
    fpShutdown(C.Fd, SHUT_WR);
    bearings_server_wait(Srv);
    AssertEquals('the registry is empty', 0, Integer(bearings_ws_count(Srv)));
  finally
    C.Free;
    D.Free;
  end;
  AssertTrue('C closed with 1001', WaitEvent('closed 1001 server shutdown'));
  AssertTrue('D closed without a close frame', WaitEvent('closed 1006 '));
  bearings_server_free(Srv);
  Srv := nil;
end;

procedure TTestCapiWs.Origins;

  function StatusWith(const Origin: RawByteString): Integer;
  var
    C: TWsClient;
  begin
    if Origin = '' then
      C := TWsClient.Create(Port, '/ws')
    else
      C := TWsClient.Create(Port, '/ws', 'Origin: ' + Origin + CRLF);
    Result := C.Status;
    C.Free;
  end;

begin
  AssertEquals('no Origin: not a browser', 101, StatusWith(''));
  AssertEquals('listed', 101, StatusWith('https://listed.example'));
  AssertEquals('listed, ignoring case and a final /', 101, StatusWith('https://other.example'));
  AssertEquals('the same host', 101, StatusWith('http://127.0.0.1:' + IntToStr(Port)));
  AssertEquals('another port', 403, StatusWith('http://127.0.0.1:1'));
  AssertEquals('another site', 403, StatusWith('https://evil.example'));
  AssertEquals('not a URL', 403, StatusWith('nonsense'));
  AssertEquals('two of them', 403, StatusWith('https://listed.example' + CRLF
    + 'Origin: https://listed.example'));
end;

procedure TTestCapiWs.The_ignored_text;
var
  C: TWsClient;
begin
  C := TWsClient.Create(Port, '/ws');
  try
    C.Send(WS_OP_TEXT, 'PONG');
    C.Send(WS_OP_TEXT, 'real');
    AssertEquals('echo:real', C.Next.Payload);
    AssertTrue(WaitEvent('text real'));
    Lock.Acquire;
    AssertEquals('PONG never reached the callback', -1, WsEvents.IndexOf('text PONG'));
    Lock.Release;
  finally
    C.Free;
  end;
end;

procedure TTestCapiWs.Unknown_ids;
var
  Msg: RawByteString;
begin
  Msg := 'x';
  AssertEquals(BEARINGS_CANCELED, bearings_ws_send(Srv, 999, PByte(PAnsiChar(Msg)), 1));
  AssertEquals(BEARINGS_CANCELED, bearings_ws_close(Srv, 999, 1000, ''));
  AssertEquals(BEARINGS_CANCELED, bearings_ws_subscribe(Srv, 999, 'a', 1));
  AssertEquals(BEARINGS_CANCELED, bearings_ws_unsubscribe(Srv, 999, 'a', 1));
  AssertEquals(0, Integer(bearings_ws_count(Srv)));
end;

procedure THammer.Execute;
var
  R, Id: Integer;
  Msg: RawByteString;
begin
  Msg := 'x';
  for R := 1 to Rounds do
    for Id := 1 to MaxId do
    begin
      bearings_ws_send(Srv, Id, PByte(PAnsiChar(Msg)), 1);
      bearings_ws_subscribe(Srv, Id, 't', 1);
      bearings_ws_publish(Srv, 't', 1, PByte(PAnsiChar(Msg)), 1);
      bearings_ws_unsubscribe(Srv, Id, 't', 1);
      if (R + Id + Seed) mod 97 = 0 then
        bearings_ws_close(Srv, Id, 1000, '');
      bearings_ws_count(Srv);
    end;
end;

procedure TTestCapiWs.Calls_by_id_while_connections_end;
const
  NC = 16;
  NT = 4;
var
  C: array[0..NC - 1] of TWsClient;
  H: array[0..NT - 1] of THammer;
  I, Pct: Integer;
begin
  Pct := StrToIntDef(GetEnvironmentVariable('WD_ITER'), 100);
  for I := 0 to NC - 1 do
    C[I] := TWsClient.Create(Port, '/ws');
  for I := 1 to 500 do
    if bearings_ws_count(Srv) = NC then
      Break
    else
      Sleep(10);
  AssertEquals('all open', NC, Integer(bearings_ws_count(Srv)));
  for I := 0 to NT - 1 do
  begin
    H[I] := THammer.Create(True);
    H[I].Srv := Srv;
    H[I].MaxId := NC + 4;           { and a few ids no connection has }
    H[I].Rounds := 1 + 200 * Pct div 100;
    H[I].Seed := I;
    H[I].Start;
  end;
  { half of the clients vanish meanwhile }
  for I := 0 to NC div 2 - 1 do
  begin
    Sleep(2);
    FreeAndNil(C[I]);
  end;
  for I := 0 to NT - 1 do
  begin
    H[I].WaitFor;
    H[I].Free;
  end;
  for I := NC div 2 to NC - 1 do
    FreeAndNil(C[I]);
  for I := 1 to 500 do
    if bearings_ws_count(Srv) = 0 then
      Break
    else
      Sleep(10);
  AssertEquals('every connection ended', 0, Integer(bearings_ws_count(Srv)));
end;

procedure WriteFile;
var
  F: TFileStream;
  S: RawByteString;
begin
  FilePath := GetTempDir + 'test_capi_' + IntToStr(GetProcessID) + '.txt';
  S := '0123456789';
  F := TFileStream.Create(FilePath, fmCreate);
  try
    F.WriteBuffer(S[1], Length(S));
  finally
    F.Free;
  end;
end;

begin
  Lock := TCriticalSection.Create;
  WsEvents := TStringList.Create;
  WriteFile;
  RegisterTest(TTestCapiHttp);
  RegisterTest(TTestCapiWs);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
  DeleteFile(FilePath);
  WsEvents.Free;
  Lock.Free;
end.
