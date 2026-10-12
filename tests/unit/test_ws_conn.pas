{ Tests for bearings.ws.conn: a TWebSocket on a TLoop run by the test
  thread, over an in-memory transport (TMemTransport: input bytes, the
  bytes written, a write budget that makes the socket look full, injected
  errors). Covered: OnOpen and echo, the leftover bytes of the hand-off,
  reassembly across frames and reads, ping/pong, the close handshake
  started by either side (with and without a status code), the close
  timeout, protocol errors (1002, 1007, 1009) and the connection end that
  follows, a handler that raises (1011), backpressure (wsFull, reading
  paused, OnWritable), a client that disconnects in the middle of a frame,
  a write error, the idle timeout, periodic pings, and sends posted from
  another thread. Every test checks that the TWebSocket was freed
  (WebSocketsLive); the heaptrc build checks that nothing else leaked.
  Run: test_ws_conn --all --format=plain }
program test_ws_conn;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, ctypes, fpcunit, testregistry, consoletestrunner, bearings.rt.sys,
  bearings.rt.loop, bearings.rt.buf, bearings.rt.net, bearings.rt.stream, bearings.ws.frame,
  bearings.ws.conn, bearings.test.ws;

type
  TMemTransport = class(TTransport)
  public
    Inp: RawByteString;
    InPos: SizeInt;
    Eof: Boolean;
    ReadErr: cint;
    Outp: RawByteString;
    Budget: Int64;                   { bytes the next writes may take; -1 = any }
    WriteErr: cint;
    ShutDown, Closed: Boolean;
    constructor Create;
    function Read(Buf: PByte; Len: SizeInt): SizeInt; override;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; override;
    function WriteV(Iov: PSysIoVec; Count: Integer): SizeInt; override;
    function IsWriteVectored: Boolean; override;
    function ShutdownWrite: SizeInt; override;
    procedure Close; override;
  end;

  TRecHandler = class(TWebSocketHandler)
  public
    Log: RawByteString;
    Echo, RaiseOnText, CloseOnText, AbortOnText: Boolean;
    procedure OnOpen(WS: TWebSocket); override;
    procedure OnText(WS: TWebSocket; P: PByte; Len: SizeInt); override;
    procedure OnBinary(WS: TWebSocket; P: PByte; Len: SizeInt); override;
    procedure OnPong(WS: TWebSocket; P: PByte; Len: SizeInt); override;
    procedure OnWritable(WS: TWebSocket); override;
    procedure OnError(WS: TWebSocket; Code: Word; const Msg: string); override;
    procedure OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString); override;
  end;

  TPostThread = class(TThread)
  public
    WS: TWebSocket;
    Count: Integer;
    procedure Execute; override;
  end;

  TTestWsConn = class(TTestCase)
  private
    L: TLoop;
    T: TMemTransport;
    U: TUpgraded;
    H: TRecHandler;
    WS: TWebSocket;
    Live0: LongInt;
    Dummy: TLoopMsg;
    Pending: RawByteString;          { server bytes not yet turned into frames }
    procedure Open(const Cfg: TWsConfig; const Leftover: RawByteString = '');
    procedure Spin(N: Integer = 4);
    { spins (with short sleeps) until Done or MaxMs passed }
    procedure SpinFor(MaxMs: Integer);
    procedure Send(const S: RawByteString);
    function Frames: RawByteString;
    function Ended: Boolean;
    procedure AssertFreed;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Open_and_echo;
    procedure Leftover_bytes_come_first;
    procedure Reassembly_across_frames_and_reads;
    procedure Ping_is_answered_with_pong;
    procedure Client_close_is_echoed;
    procedure Client_close_without_code;
    procedure Server_close_waits_for_the_client;
    procedure Server_close_times_out;
    procedure Unmasked_frame_fails_with_1002;
    procedure Invalid_utf8_fails_with_1007;
    procedure Too_large_fails_with_1009;
    procedure Handler_exception_fails_with_1011;
    procedure Backpressure;
    procedure Disconnect_mid_frame;
    procedure Write_error_ends_the_connection;
    procedure Idle_timeout_closes_with_1001;
    procedure Periodic_ping;
    procedure Posts_from_another_thread;
    procedure Sends_after_close_are_refused;
    procedure Abort_from_a_callback;
    procedure Abort_with_a_backlog_sends_nothing_more;
    procedure Server_shutdown_closes_with_1001;
    procedure Forced_abort_releases_everything;
    procedure Default_config_pings;
    procedure Prepared_frame_written_at_once;
    procedure Prepared_frames_queued_by_reference;
    procedure Mixed_queue_keeps_order_through_partial_writes;
    procedure Queued_frames_released_at_abort;
    procedure Prepared_frame_backpressure;
    procedure Invalid_prepared_frames_are_refused;
    procedure Prepared_frames_posted_from_another_thread;
  end;

  TFramePostThread = class(TThread)
  public
    WS: TWebSocket;
    F: TWsFrame;
    Count: Integer;
    procedure Execute; override;
  end;

{ ---- TMemTransport ---- }

constructor TMemTransport.Create;
begin
  inherited Create;
  Budget := -1;
end;

function TMemTransport.Read(Buf: PByte; Len: SizeInt): SizeInt;
begin
  if InPos < Length(Inp) then
  begin
    Result := Length(Inp) - InPos;
    if Result > Len then
      Result := Len;
    Move(Inp[InPos + 1], Buf^, Result);
    Inc(InPos, Result);
    if InPos = Length(Inp) then
    begin
      Inp := '';
      InPos := 0;
    end;
  end
  else if ReadErr <> 0 then
    Result := -ReadErr
  else if Eof then
    Result := 0
  else
    Result := -ESysEAGAIN;
end;

function TMemTransport.Write(Buf: PByte; Len: SizeInt): SizeInt;
var
  S: RawByteString;
begin
  if Closed then
    Exit(-ESysEBADF);
  if WriteErr <> 0 then
    Exit(-WriteErr);
  if Budget = 0 then
    Exit(-ESysEAGAIN);
  Result := Len;
  if (Budget > 0) and (Result > Budget) then
    Result := Budget;
  if Budget > 0 then
    Dec(Budget, Result);
  SetString(S, PAnsiChar(Buf), Result);
  Outp := Outp + S;
end;

function TMemTransport.WriteV(Iov: PSysIoVec; Count: Integer): SizeInt;
var
  I: Integer;
  R: SizeInt;
begin
  Result := 0;
  for I := 0 to Count - 1 do
  begin
    if Iov[I].Len = 0 then
      Continue;
    R := Write(Iov[I].Base, Iov[I].Len);
    if R < 0 then
    begin
      if Result = 0 then
        Result := R;
      Exit;
    end;
    Inc(Result, R);
    if SizeUInt(R) < Iov[I].Len then
      Exit;
  end;
end;

function TMemTransport.IsWriteVectored: Boolean;
begin
  Result := True;
end;

function TMemTransport.ShutdownWrite: SizeInt;
begin
  ShutDown := True;
  Result := 0;
end;

procedure TMemTransport.Close;
begin
  Closed := True;
end;

{ ---- TRecHandler ---- }

procedure TRecHandler.OnOpen(WS: TWebSocket);
begin
  Log := Log + 'open|';
end;

procedure TRecHandler.OnText(WS: TWebSocket; P: PByte; Len: SizeInt);
var
  S: RawByteString;
begin
  SetString(S, PAnsiChar(P), Len);
  if Len > 40 then
    Log := Log + 'text:' + IntToStr(Len) + '#' + Digest(S) + '|'
  else
    Log := Log + 'text:' + S + '|';
  if RaiseOnText then
    raise Exception.Create('handler failed on purpose');
  if CloseOnText then
    WS.CloseWith(4000, 'app');
  if AbortOnText then
    WS.Abort;
  if Echo then
    WS.SendText(P, Len);
end;

procedure TRecHandler.OnBinary(WS: TWebSocket; P: PByte; Len: SizeInt);
var
  S: RawByteString;
begin
  SetString(S, PAnsiChar(P), Len);
  Log := Log + 'bin:' + IntToStr(Len) + '#' + Digest(S) + '|';
  if Echo then
    WS.SendBinary(P, Len);
end;

procedure TRecHandler.OnPong(WS: TWebSocket; P: PByte; Len: SizeInt);
var
  S: RawByteString;
begin
  SetString(S, PAnsiChar(P), Len);
  Log := Log + 'pong:' + S + '|';
end;

procedure TRecHandler.OnWritable(WS: TWebSocket);
begin
  Log := Log + 'writable|';
end;

procedure TRecHandler.OnError(WS: TWebSocket; Code: Word; const Msg: string);
begin
  Log := Log + 'error:' + IntToStr(Code) + '|';
end;

procedure TRecHandler.OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString);
begin
  Log := Log + 'close:' + IntToStr(Code) + ':' + Reason + '|';
end;

{ ---- TPostThread ---- }

procedure TPostThread.Execute;
var
  I: Integer;
begin
  I := 0;
  while I < Count do
    case WS.PostText('m' + IntToStr(I)) of
      wsOk: Inc(I);
      wsFull: Sleep(1);
      wsClosed: Break;
    end;
  WS.Release;
end;

procedure TFramePostThread.Execute;
var
  I: Integer;
begin
  I := 0;
  while I < Count do
    case WS.PostFrame(F) of
      wsOk: Inc(I);
      wsFull: Sleep(1);
      wsClosed: Break;
    end;
  WS.Release;
end;

{ ---- the tests ---- }

procedure DummyProc(Loop: TLoop; Arg: Pointer);
begin
end;

procedure SilentError(Loop: TLoop; Task: TLoopTask; E: Exception);
begin
end;

procedure TTestWsConn.SetUp;
begin
  Live0 := WebSocketsLive;
  L := TLoop.Create(0);
  T := TMemTransport.Create;
  H := TRecHandler.Create;
  Dummy.Kind := lmCall;
  Dummy.Proc := @DummyProc;
  Pending := '';
  LoopErrorProc := @SilentError;
end;

procedure TTestWsConn.TearDown;
begin
  { a test that failed early may leave the connection open }
  if (U <> nil) and not Ended then
    U.Close;
  Spin(2);
  U := nil;
  WS := nil;
  L.Free;
  T.Free;
  H.Free;
end;

procedure TTestWsConn.Open(const Cfg: TWsConfig; const Leftover: RawByteString);
var
  V: TBytesView;
begin
  V := Default(TBytesView);
  if Leftover <> '' then
  begin
    V.P := PByte(Leftover);
    V.Len := Length(Leftover);
  end;
  U := TUpgraded.CreateFrom(L, T, V, nil, False);
  WS := TWebSocket.Create(H, Cfg, False);
  WS.Start(U);
  Spin;
end;

procedure TTestWsConn.Spin(N: Integer);
var
  I: Integer;
begin
  for I := 1 to N do
  begin
    L.Post(@Dummy);                  { epoll_wait does not block }
    L.RunIteration;
  end;
end;

procedure TTestWsConn.SpinFor(MaxMs: Integer);
var
  I: Integer;
begin
  for I := 1 to MaxMs div 5 do
  begin
    Spin(2);
    if Ended then
      Exit;
    Sleep(5);
  end;
end;

procedure TTestWsConn.Send(const S: RawByteString);
begin
  T.Inp := T.Inp + S;
  if not Ended then
    U.Wake;                          { what a socket event does }
  Spin;
end;

function TTestWsConn.Frames: RawByteString;
begin
  Pending := Pending + T.Outp;
  T.Outp := '';
  Result := ServerFramesLog(Pending);
end;

function TTestWsConn.Ended: Boolean;
begin
  Result := T.Closed;
end;

procedure TTestWsConn.AssertFreed;
begin
  AssertTrue('transport closed', T.Closed);
  AssertEquals('TWebSocket freed', Live0, WebSocketsLive);
end;

function Cfg0: TWsConfig;
begin
  Result := DefaultWsConfig;
  Result.IdleTimeoutMs := 0;
end;

function CloseP(Code: Word; const Reason: RawByteString): RawByteString;
begin
  Result := AnsiChar(Code shr 8) + AnsiChar(Code and $FF) + Reason;
end;

procedure TTestWsConn.Open_and_echo;
begin
  H.Echo := True;
  Open(Cfg0);
  AssertEquals('open|', H.Log);
  Send(CFrame(WS_OP_TEXT, 'hello') + CFrame(WS_OP_BINARY, Pattern(70000)));
  AssertEquals('1:hello|2:70000#' + Digest(Pattern(70000)) + '|', Frames);
  AssertEquals('open|text:hello|bin:70000#' + Digest(Pattern(70000)) + '|', H.Log);
  Send(CFrame(WS_OP_CLOSE, CloseP(1000, '')));
  T.Eof := True;
  U.Wake;
  Spin;
  AssertEquals('8:' + CloseP(1000, '') + '|', Frames);
  AssertFreed;
end;

procedure TTestWsConn.Leftover_bytes_come_first;
var
  Rest: RawByteString;
begin
  H.Echo := True;
  Rest := CFrame(WS_OP_TEXT, 'early');
  UniqueString(Rest);
  T.Inp := CFrame(WS_OP_TEXT, 'later');
  Open(Cfg0, Rest);
  AssertEquals('open|text:early|text:later|', H.Log);
  AssertEquals('1:early|1:later|', Frames);
  T.Eof := True;
  Send('');
  AssertFreed;
end;

procedure TTestWsConn.Reassembly_across_frames_and_reads;
var
  S: RawByteString;
begin
  Open(Cfg0);
  S := CFrame(WS_OP_TEXT, 'abc', False) + CFrame(WS_OP_CONT, 'def', False) + CFrame(WS_OP_CONT, 'ghi');
  Send(Copy(S, 1, 5));
  Send(Copy(S, 6, 7));
  Send(Copy(S, 13, MaxInt));
  { one message split across reads but in one frame }
  S := CFrame(WS_OP_BINARY, Pattern(1000));
  Send(Copy(S, 1, 500));
  Send(Copy(S, 501, MaxInt));
  AssertEquals('open|text:abcdefghi|bin:1000#' + Digest(Pattern(1000)) + '|', H.Log);
  T.Eof := True;
  Send('');
  AssertEquals('ended without a close frame', 'open|text:abcdefghi|bin:1000#' + Digest(Pattern(1000))
    + '|close:1006:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Ping_is_answered_with_pong;
begin
  Open(Cfg0);
  Send(CFrame(WS_OP_PING, 'are you there') + CFrame(WS_OP_TEXT, 'x', False) + CFrame(WS_OP_PING, '')
    + CFrame(WS_OP_CONT, 'y') + CFrame(WS_OP_PONG, 'unsolicited'));
  AssertEquals('10:are you there|10:|', Frames);
  AssertEquals('open|text:xy|pong:unsolicited|', H.Log);
  AssertTrue(WS.Ping('p1') = wsOk);
  Spin;
  AssertEquals('9:p1|', Frames);
  T.Eof := True;
  Send('');
  AssertFreed;
end;

procedure TTestWsConn.Client_close_is_echoed;
begin
  Open(Cfg0);
  Send(CFrame(WS_OP_CLOSE, CloseP(1001, 'bye')) + CFrame(WS_OP_TEXT, 'after close'));
  AssertEquals('the same code, no reason', '8:' + CloseP(1001, '') + '|', Frames);
  AssertTrue('write side shut down', T.ShutDown);
  AssertFalse('the socket stays open until the client closes', T.Closed);
  T.Eof := True;
  Send('');
  AssertEquals('open|close:1001:bye|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Client_close_without_code;
begin
  Open(Cfg0);
  Send(CFrame(WS_OP_CLOSE, ''));
  AssertEquals('8:|', Frames);
  T.Eof := True;
  Send('');
  AssertEquals('open|close:1005:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Server_close_waits_for_the_client;
begin
  H.CloseOnText := True;
  H.Echo := True;
  Open(Cfg0);
  Send(CFrame(WS_OP_TEXT, 'one'));
  AssertEquals('the close frame; the echo after it is refused', '8:' + CloseP(4000, 'app') + '|', Frames);
  AssertFalse('no shutdown before the client answers', T.ShutDown);
  Send(CFrame(WS_OP_TEXT, 'two') + CFrame(WS_OP_PING, 'p'));
  AssertEquals('no pong after our close', '', Frames);
  Send(CFrame(WS_OP_CLOSE, CloseP(4000, '')));
  AssertTrue(T.ShutDown);
  T.Eof := True;
  Send('');
  AssertEquals('data after our close is dropped', 'open|text:one|close:4000:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Server_close_times_out;
var
  C: TWsConfig;
begin
  C := Cfg0;
  C.CloseTimeoutMs := 40;
  Open(C);
  AssertTrue(WS.CloseWith(1000, 'done'));
  AssertFalse('a second close', WS.CloseWith(1000, 'again'));
  Spin;
  AssertEquals('8:' + CloseP(1000, 'done') + '|', Frames);
  SpinFor(2000);
  AssertEquals('open|close:1006:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Unmasked_frame_fails_with_1002;
begin
  Open(Cfg0);
  Send(CFrameRaw($81, 'hi', False) + CFrame(WS_OP_TEXT, 'never'));
  AssertEquals('8:' + CloseP(1002, '') + '|', Frames);
  AssertTrue(T.ShutDown);
  T.Eof := True;
  Send('');
  AssertEquals('open|error:1002|close:1006:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Invalid_utf8_fails_with_1007;
begin
  Open(Cfg0);
  Send(CFrame(WS_OP_TEXT, 'ok'#$C0#$80));
  AssertEquals('8:' + CloseP(1007, '') + '|', Frames);
  T.Eof := True;
  Send('');
  AssertEquals('open|error:1007|close:1006:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Too_large_fails_with_1009;
var
  C: TWsConfig;
begin
  C := Cfg0;
  C.MaxMessage := 100;
  Open(C);
  Send(CFrame(WS_OP_BINARY, Pattern(100)));
  Send(CFrame(WS_OP_BINARY, Pattern(60), False) + CFrame(WS_OP_CONT, Pattern(41)));
  AssertEquals('8:' + CloseP(1009, '') + '|', Frames);
  T.Eof := True;
  Send('');
  AssertEquals('open|bin:100#' + Digest(Pattern(100)) + '|error:1009|close:1006:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Handler_exception_fails_with_1011;
begin
  H.RaiseOnText := True;
  Open(Cfg0);
  Send(CFrame(WS_OP_TEXT, 'boom') + CFrame(WS_OP_TEXT, 'not delivered'));
  AssertEquals('8:' + CloseP(1011, '') + '|', Frames);
  T.Eof := True;
  Send('');
  AssertEquals('open|text:boom|error:1011|close:1006:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Backpressure;
var
  C: TWsConfig;
  Big: RawByteString;
begin
  C := Cfg0;
  C.SendHighWater := 1000;
  Open(C);
  T.Budget := 0;                     { the socket takes nothing }
  Big := Pattern(600);
  AssertTrue('queued', WS.SendBinary(Big) = wsOk);
  AssertTrue('below the mark: queued', WS.SendBinary(Big) = wsOk);
  AssertTrue('over the mark: refused', WS.SendBinary(Big) = wsFull);
  AssertEquals(2 * (600 + 4), WS.Queued);
  { reading stops while the queue is over the mark }
  Send(CFrame(WS_OP_TEXT, 'waiting'));
  AssertEquals('open|', H.Log);
  { the socket drains: OnWritable, then the input is read }
  T.Budget := -1;
  U.Wake;
  Spin;
  AssertEquals(0, WS.Queued);
  AssertEquals('open|writable|text:waiting|', H.Log);
  AssertEquals('2:600#' + Digest(Big) + '|2:600#' + Digest(Big) + '|', Frames);
  { a partial write leaves the rest queued, in order }
  T.Budget := 3;
  AssertTrue(WS.SendText('0123456789') = wsOk);
  AssertTrue(WS.SendText('abc') = wsOk);
  T.Budget := -1;
  U.Wake;
  Spin;
  AssertEquals('1:0123456789|1:abc|', Frames);
  T.Eof := True;
  Send('');
  AssertFreed;
end;

procedure TTestWsConn.Disconnect_mid_frame;
var
  S: RawByteString;
begin
  Open(Cfg0);
  S := CFrame(WS_OP_BINARY, Pattern(200000));
  T.Eof := True;
  Send(Copy(S, 1, 100000));
  AssertEquals('open|close:1006:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Write_error_ends_the_connection;
begin
  H.Echo := True;
  Open(Cfg0);
  T.WriteErr := ESysEPIPE;
  Send(CFrame(WS_OP_TEXT, 'hi'));
  AssertEquals('open|text:hi|error:1006|close:1006:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Idle_timeout_closes_with_1001;
var
  C: TWsConfig;
  I: Integer;
  F: RawByteString;
begin
  C := Cfg0;
  C.IdleTimeoutMs := 30;
  Open(C);
  F := '';
  for I := 1 to 200 do
  begin
    Spin(2);
    F := F + Frames;
    if F <> '' then
      Break;
    Sleep(5);
  end;
  AssertEquals('8:' + CloseP(1001, 'idle timeout') + '|', F);
  Send(CFrame(WS_OP_CLOSE, CloseP(1001, '')));
  T.Eof := True;
  Send('');
  AssertEquals('open|close:1001:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Periodic_ping;
var
  C: TWsConfig;
  I: Integer;
  F: RawByteString;
begin
  C := Cfg0;
  C.PingIntervalMs := 20;
  Open(C);
  F := '';
  for I := 1 to 400 do
  begin
    Spin(2);
    F := F + Frames;
    if Length(F) >= Length('9:|9:|') then
      Break;
    Sleep(5);
  end;
  AssertEquals('9:|9:|', F);
  T.Eof := True;
  Send('');
  AssertFreed;
end;

procedure TTestWsConn.Posts_from_another_thread;
var
  Th: TPostThread;
  F, Want: RawByteString;
  I: Integer;
begin
  Open(Cfg0);
  Th := TPostThread.Create(True);
  Th.WS := WS;
  Th.Count := 500;
  WS.AddRef;                         { the thread's reference }
  Th.Start;
  F := '';
  for I := 1 to 2000 do
  begin
    Spin(1);
    F := F + Frames;
    if Th.Finished and (Pos('1:m499|', F) > 0) then
      Break;
    Sleep(1);
  end;
  Th.WaitFor;
  Th.Free;
  Spin;
  F := F + Frames;
  Want := '';
  for I := 0 to 499 do
    Want := Want + '1:m' + IntToStr(I) + '|';
  AssertEquals(Want, F);
  T.Eof := True;
  Send('');
  AssertEquals('closed after the thread released its reference', 'open|close:1006:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Sends_after_close_are_refused;
begin
  Open(Cfg0);
  WS.AddRef;                         { keep the object to call it after the end }
  try
    Send(CFrame(WS_OP_CLOSE, CloseP(1000, '')));
    AssertTrue(WS.SendText('late') = wsClosed);
    T.Eof := True;
    Send('');
    AssertTrue(WS.Closing);
    AssertTrue(WS.SendText('later') = wsClosed);
    AssertTrue(WS.PostText('from elsewhere') = wsClosed);
    AssertEquals('8:' + CloseP(1000, '') + '|', Frames);
  finally
    WS.Release;
  end;
  AssertFreed;
end;

procedure TTestWsConn.Abort_from_a_callback;
begin
  H.AbortOnText := True;
  H.Echo := True;
  Open(Cfg0);
  Send(CFrame(WS_OP_TEXT, 'stop') + CFrame(WS_OP_TEXT, 'never'));
  AssertEquals('no echo, no close frame', '', Frames);
  AssertFalse('no shutdown: no close handshake', T.ShutDown);
  AssertEquals('open|text:stop|close:1006:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Abort_with_a_backlog_sends_nothing_more;
begin
  Open(Cfg0);
  T.Budget := 0;
  AssertTrue(WS.SendBinary(Pattern(5000)) = wsOk);
  AssertTrue(WS.Queued > 0);
  WS.Abort;
  AssertTrue('refused after Abort', WS.SendText('x') = wsClosed);
  AssertTrue(WS.Closing);
  T.Budget := -1;
  Spin;
  AssertEquals('the backlog was dropped', '', T.Outp);
  AssertEquals('open|close:1006:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Server_shutdown_closes_with_1001;
begin
  Open(Cfg0);
  U.Shutdown;                        { what bearings.server does at a graceful stop }
  Spin;
  AssertEquals('8:' + CloseP(1001, 'server shutdown') + '|', Frames);
  Send(CFrame(WS_OP_CLOSE, CloseP(1001, '')));
  AssertTrue(T.ShutDown);
  T.Eof := True;
  Send('');
  AssertEquals('open|close:1001:|', H.Log);
  AssertFreed;
end;

procedure TTestWsConn.Forced_abort_releases_everything;
begin
  Open(Cfg0);
  Send(CFrame(WS_OP_TEXT, 'abc', False));   { a message in the reassembly buffer }
  T.Budget := 0;
  WS.SendBinary(Pattern(3000));           { and a queued send }
  U.Abort;                                { what the stop deadline does }
  AssertEquals('open|close:1006:|', H.Log);
  AssertFreed;
  Spin;
end;

procedure TTestWsConn.Default_config_pings;
var
  C: TWsConfig;
begin
  C := DefaultWsConfig;
  AssertEquals(25000, C.PingIntervalMs);
  AssertEquals(60000, C.IdleTimeoutMs);
  AssertTrue('a ping comes well before the idle timeout', 2 * C.PingIntervalMs <= C.IdleTimeoutMs);
end;

procedure TTestWsConn.Prepared_frame_written_at_once;
var
  F: TWsFrame;
begin
  Open(Cfg0);
  F := WsTextFrame('to everyone');
  AssertTrue(WS.SendFrame(F) = wsOk);
  AssertTrue(WS.SendFrame(F) = wsOk);
  AssertEquals(0, WS.Queued);
  AssertEquals('nothing kept', 1, StringRefCount(F));
  AssertEquals('1:to everyone|1:to everyone|', Frames);
  T.Eof := True;
  Send('');
  AssertFreed;
end;

procedure TTestWsConn.Prepared_frames_queued_by_reference;
var
  Big, Small: TWsFrame;
begin
  Open(Cfg0);
  Big := WsBinaryFrame(Pattern(5000));
  Small := WsTextFrame('tiny');
  T.Budget := 0;
  AssertTrue(WS.SendFrame(Big) = wsOk);
  AssertEquals('the queue holds a reference', 2, StringRefCount(Big));
  AssertTrue(WS.SendFrame(Big) = wsOk);
  AssertEquals('two queued sends, two references', 3, StringRefCount(Big));
  AssertTrue(WS.SendFrame(Small) = wsOk);
  AssertEquals('a small frame is copied', 1, StringRefCount(Small));
  AssertEquals(2 * Length(Big) + Length(Small), WS.Queued);
  T.Budget := -1;
  U.Wake;
  Spin;
  AssertEquals(0, WS.Queued);
  AssertEquals('released once written', 1, StringRefCount(Big));
  AssertEquals('2:5000#' + Digest(Pattern(5000)) + '|2:5000#' + Digest(Pattern(5000)) + '|1:tiny|', Frames);
  T.Eof := True;
  Send('');
  AssertFreed;
end;

procedure TTestWsConn.Mixed_queue_keeps_order_through_partial_writes;
var
  A, B: TWsFrame;
  Want: RawByteString;
  I: Integer;
begin
  Open(Cfg0);
  A := WsBinaryFrame(Pattern(3000));
  B := WsBinaryFrame(Pattern(200));
  { a partial direct write: the rest of A is queued by reference, from the middle }
  T.Budget := 100;
  AssertTrue(WS.SendFrame(A) = wsOk);
  AssertEquals(Length(A) - 100, WS.Queued);
  AssertTrue(WS.SendText('one') = wsOk);
  AssertTrue(WS.SendFrame(B) = wsOk);
  AssertTrue(WS.SendText('two') = wsOk);
  AssertTrue(WS.SendFrame(A) = wsOk);
  AssertTrue(WS.SendBinary(Pattern(2000)) = wsOk);
  for I := 1 to 100 do
    WS.SendText('m' + IntToStr(I));  { many segments: more than one writev }
  { the socket takes 777 bytes per run }
  for I := 1 to 400 do
  begin
    if WS.Queued = 0 then
      Break;
    T.Budget := 777;
    U.Wake;
    Spin(1);
  end;
  AssertEquals(0, WS.Queued);
  Want := '2:3000#' + Digest(Pattern(3000)) + '|1:one|2:200#' + Digest(Pattern(200)) + '|1:two|2:3000#'
    + Digest(Pattern(3000)) + '|2:2000#' + Digest(Pattern(2000)) + '|';
  for I := 1 to 100 do
    Want := Want + '1:m' + IntToStr(I) + '|';
  AssertEquals(Want, Frames);
  AssertEquals(1, StringRefCount(A));
  T.Budget := -1;
  T.Eof := True;
  Send('');
  AssertFreed;
end;

procedure TTestWsConn.Queued_frames_released_at_abort;
var
  F: TWsFrame;
begin
  Open(Cfg0);
  F := WsBinaryFrame(Pattern(4000));
  T.Budget := 0;
  WS.SendFrame(F);
  WS.SendFrame(F);
  AssertEquals(3, StringRefCount(F));
  WS.Abort;
  Spin;
  AssertEquals('the queue let go', 1, StringRefCount(F));
  AssertEquals('', T.Outp);
  AssertFreed;
end;

procedure TTestWsConn.Prepared_frame_backpressure;
var
  C: TWsConfig;
  F: TWsFrame;
begin
  C := Cfg0;
  C.SendHighWater := 5000;
  Open(C);
  F := WsBinaryFrame(Pattern(3000));
  T.Budget := 0;
  AssertTrue(WS.SendFrame(F) = wsOk);
  AssertTrue(WS.SendFrame(F) = wsOk);
  AssertTrue('at the mark', WS.SendFrame(F) = wsFull);
  AssertTrue('a ping still goes', WS.SendFrame(WsMakeFrame(WS_OP_PING, nil, 0)) = wsOk);
  T.Budget := -1;
  U.Wake;
  Spin;
  AssertEquals('open|writable|', H.Log);
  AssertEquals('2:3000#' + Digest(Pattern(3000)) + '|2:3000#' + Digest(Pattern(3000)) + '|9:|', Frames);
  T.Eof := True;
  Send('');
  AssertFreed;
end;

procedure TTestWsConn.Invalid_prepared_frames_are_refused;
var
  Raised: Boolean;

  procedure Try1(const F: RawByteString);
  begin
    Raised := False;
    try
      WS.SendFrame(F);
    except
      on EArgumentException do
        Raised := True;
    end;
  end;

begin
  Open(Cfg0);
  Try1('not a frame');
  AssertTrue('garbage', Raised);
  Try1(WsMakeFrame(WS_OP_CLOSE, nil, 0));
  AssertTrue('close frames go through CloseWith', Raised);
  Try1(CFrame(WS_OP_TEXT, 'masked'));
  AssertTrue('a masked (client) frame', Raised);
  AssertEquals('', Frames);
  T.Eof := True;
  Send('');
  AssertFreed;
end;

procedure TTestWsConn.Prepared_frames_posted_from_another_thread;
var
  Th: TFramePostThread;
  F, Want: RawByteString;
  I: Integer;
begin
  Open(Cfg0);
  Th := TFramePostThread.Create(True);
  Th.WS := WS;
  Th.F := WsBinaryFrame(Pattern(2000));
  Th.Count := 300;
  WS.AddRef;
  Th.Start;
  F := '';
  for I := 1 to 3000 do
  begin
    Spin(1);
    F := F + Frames;
    if Th.Finished and (WS.Queued = 0) and (Length(F) >= 300 * Length('2:2000#' + Digest(Pattern(2000)) + '|')) then
      Break;
    Sleep(1);
  end;
  Th.WaitFor;
  Want := '';
  for I := 1 to 300 do
    Want := Want + '2:2000#' + Digest(Pattern(2000)) + '|';
  AssertEquals(Want, F);
  AssertEquals('only the thread''s own reference is left', 1, StringRefCount(Th.F));
  Th.Free;
  T.Eof := True;
  Send('');
  AssertFreed;
end;

begin
  RegisterTest(TTestWsConn);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
end.
