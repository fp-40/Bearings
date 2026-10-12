{ M3 S5: dispatcher micro-benchmark (docs/design.md section 9): the dispatcher
  over TMockTransport, ns per request for depth 1 and depth 16 pipelines;
  budget: prototype cost + 420 ns.

  Both sides run over the same in-memory transport (one batch of Depth TFB
  plaintext requests per read, then -EAGAIN; writes accept everything), so
  the difference is CPU in user space, without syscalls:

  proto     the per-request work of the raw-loop prototype (bench/rawsrv.pas,
            itself beproto on the M3 runtime): read into a pooled block,
            ServerParse each buffered request, three response headers
            (THttpHeaders.Add), ServerEncode (TByteVec overload) and
            TEncoder.Encode of the 13-byte body, one write per batch, the
            idle block release. No state machine, no service layer.
  dispatch  TH1Dispatcher.Run (the whole engine: dispatcher, conn, io,
            exchange, the inline service of bench/plaintext.pas) with the
            benchmark configuration (pipeline_flush, no timer, no date
            change during the run), one Run per batch as an epoll event
            would call it.

  Usage: [CONNS=n] [MT=1] bench_dispatch [requests (default 4000000)] [runs (default 5)]
                        [only: proto | dispatch, one depth (16) - for profiling]
  Prints ns/request per mode and depth (median of the runs) and the
  difference dispatch - proto at depth 16 against the 420 ns budget.
  Exit status 1 when the budget is exceeded. }
program bench_dispatch;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, ctypes, bearings.rt.sys, bearings.rt.clock, bearings.rt.buf, bearings.rt.loop, bearings.rt.net, bearings.http.headers,
  bearings.http1.parser, bearings.http1.encode, bearings.http1.role, bearings.http.error, bearings.http.exchange,
  bearings.http1.config, bearings.http1.dispatch, bearings.server, bearings.http.date;

const
  REQ: RawByteString = 'GET /plaintext HTTP/1.1'#13#10'Host: tfb-server'#13#10 +
    'Accept: text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7'#13#10 +
    'Connection: keep-alive'#13#10#13#10;
  HELLO: array[0..12] of AnsiChar = 'Hello, world!';
  HN_SERVER: array[0..5] of AnsiChar = 'server';
  HV_SERVER: array[0..4] of AnsiChar = 'wd-40';
  HN_CTYPE: array[0..11] of AnsiChar = 'content-type';
  HV_TEXT: array[0..9] of AnsiChar = 'text/plain';
  HN_CLEN: array[0..13] of AnsiChar = 'content-length';
  HV_13: array[0..1] of AnsiChar = '13';
  PATH_PLAINTEXT: array[0..9] of AnsiChar = '/plaintext';
  BUDGET_NS = 420.0;

var
  { CONNS=n: requests round-robin over n connections (cache footprint); default 1 }
  Conns: Integer = 1;

type
  TMemTransport = class(TTransport)
  public
    Batch: RawByteString;
    Pos: SizeInt;
    Armed: Boolean;
    Written: QWord;
    Writes: QWord;
    function Read(Buf: PByte; Len: SizeInt): SizeInt; override;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; override;
    function WriteV(Iov: PIoSlice; Count: Integer): SizeInt; override;
    function ShutdownWrite: SizeInt; override;
    procedure Close; override;
  end;

  TPlaintextCall = class(TServiceCall)
  public
    function Poll(Ex: TExchange): TCallPoll; override;
  end;
  TPlaintextService = class(THttpService)
  public
    FCall: TPlaintextCall;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

function TMemTransport.Read(Buf: PByte; Len: SizeInt): SizeInt;
begin
  if not Armed then
    Exit(-ESysEAGAIN);
  Result := Length(Batch) - Pos;
  if Result > Len then
    Result := Len;
  Move(Batch[Pos + 1], Buf^, Result);
  Inc(Pos, Result);
  if Pos >= Length(Batch) then
  begin
    Armed := False;
    Pos := 0;
  end;
end;

function TMemTransport.Write(Buf: PByte; Len: SizeInt): SizeInt;
begin
  Inc(Written, QWord(Len));
  Inc(Writes);
  Result := Len;
end;

function TMemTransport.WriteV(Iov: PIoSlice; Count: Integer): SizeInt;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
    Inc(Result, SizeInt(Iov[I].Len));
  Inc(Written, QWord(Result));
  Inc(Writes);
end;

function TMemTransport.ShutdownWrite: SizeInt;
begin
  Result := 0;
end;

procedure TMemTransport.Close;
begin
end;

function TPlaintextCall.Poll(Ex: TExchange): TCallPoll;
var
  P: TByteSlice;
  H: THttpHeaders;
begin
  { bench/plaintext.pas }
  P := Ex.Path;
  H := Ex.ResponseHeaders;
  if (P.Len = 10) and (CompareByte(P.P^, PATH_PLAINTEXT[0], 10) = 0) then
  begin
    H.AddTrusted(@HN_SERVER[0], 6, @HV_SERVER[0], 5);
    H.AddTrusted(@HN_CTYPE[0], 12, @HV_TEXT[0], 10);
    H.AddTrusted(@HN_CLEN[0], 14, @HV_13[0], 2);
    Ex.Respond(BodyStatic(@HELLO[0], 13));
  end
  else
  begin
    Ex.Status := 404;
    Ex.Respond(BodyEmpty);
  end;
  Result := cpReady;
end;

function TPlaintextService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

{ ---- the prototype's per-request work (bench/rawsrv.pas TRawConn) ---- }

type
  TProtoConn = record
    T: TMemTransport;
    Loop: TLoop;
    RBlock: PBufBlock;
    RLen: SizeInt;
    W: TByteVec;
    ReqHeaders, RespHeaders: THttpHeaders;
    Enc: TEncoder;
    Head: TResponseHead;
    Ctx: TH1ParseContext;
    Params: TServerEncodeParams;
    EncCtx: TEncodeContext;
    procedure Init(ATransport: TMemTransport; ALoop: TLoop);
    procedure Done;
    procedure HandleRequest(Base: PByte; const Msg: TParsedRequestHead);
    procedure Process;
    procedure Run;
  end;

procedure TProtoConn.Init(ATransport: TMemTransport; ALoop: TLoop);
begin
  T := ATransport;
  Loop := ALoop;
  RBlock := nil;
  RLen := 0;
  W := Default(TByteVec);
  ReqHeaders := THttpHeaders.Create(16, 0);
  RespHeaders := THttpHeaders.Create(8, 256);
  Head := DefaultResponseHead;
  Ctx := DefaultParseContext;
  Params := DefaultEncodeParams;
  Params.DateHeader := True;
  EncCtx.Date := LoopDate(Loop);
  EncCtx.Trailers := nil;
end;

procedure TProtoConn.Done;
begin
  if RBlock <> nil then
    Loop.Blocks.Give(RBlock);
  W.Len := 0;
  W.ReleaseIdle(@Loop.Blocks);
  ReqHeaders.Free;
  RespHeaders.Free;
end;

procedure TProtoConn.HandleRequest(Base: PByte; const Msg: TParsedRequestHead);
var
  P: PByte;
  PLen, N: SizeInt;
  EB: TEncodedBuf;
begin
  RespHeaders.Clear;
  Msg.Uri.GetPath(Base, P, PLen);
  if (PLen = 10) and CompareMem(P, @PATH_PLAINTEXT, 10) then
  begin
    RespHeaders.Add(@HN_SERVER, 6, @HV_SERVER, 5);
    RespHeaders.Add(@HN_CTYPE, 12, @HV_TEXT, 10);
    RespHeaders.Add(@HN_CLEN, 14, @HV_13, 2);
    Head.Status := 200;
    Params.Body := blkKnown;
    Params.BodyLen := 13;
  end
  else
  begin
    Head.Status := 404;
    Params.Body := blkNone;
    Params.BodyLen := 0;
  end;
  Head.Version := hv11;
  Head.Headers := RespHeaders;
  Params.KeepAlive := Msg.KeepAlive;
  Params.ReqMethod := Msg.Method;
  ServerEncode(Head, Params, EncCtx, W, @Loop.Blocks, Enc);
  if Params.Body = blkKnown then
  begin
    Enc.Encode(@HELLO, 13, EB);
    N := EB.Remaining;
    W.Reserve(N, @Loop.Blocks);
    EB.CopyTo(W.Data + W.Len);
    Inc(W.Len, N);
  end;
end;

procedure TProtoConn.Process;
var
  Pos: SizeInt;
  St: TServerParseStatus;
  Msg: TParsedRequestHead;
  Buf: PByte;
begin
  Pos := 0;
  Buf := RBlock^.Data;
  while Pos < RLen do
  begin
    St := ServerParse(Buf + Pos, RLen - Pos, Ctx, ReqHeaders, Msg);
    if St <> spsComplete then
      Break;
    HandleRequest(Buf + Pos, Msg);
    Inc(Pos, Msg.HeadLen);
  end;
  if Pos > 0 then
  begin
    if Pos < RLen then
      Move(Buf[Pos], Buf[0], RLen - Pos);
    Dec(RLen, Pos);
  end;
end;

procedure TProtoConn.Run;
var
  N: SizeInt;
begin
  repeat
    if RBlock = nil then
      RBlock := Loop.Blocks.Take(8192);
    N := T.Read(RBlock^.Data + RLen, 8192 - RLen);
    if N > 0 then
    begin
      Inc(RLen, N);
      Process;
      T.Write(W.Data, W.Len);
      W.Len := 0;
    end
    else
    begin
      if (RLen = 0) and (RBlock <> nil) then
      begin
        Loop.Blocks.Give(RBlock);
        RBlock := nil;
        W.ReleaseIdle(@Loop.Blocks);
      end;
      Exit;
    end;
  until False;
end;

function BenchProto(Loop: TLoop; N, Depth: Int64): Double;
var
  T: array of TMemTransport;
  C: array of TProtoConn;
  I, Batches: Int64;
  K: Integer;
  T0: Int64;
  W: QWord;
begin
  SetLength(T, Conns);
  SetLength(C, Conns);
  for K := 0 to Conns - 1 do
  begin
    T[K] := TMemTransport.Create;
    T[K].Batch := '';
    for I := 1 to Depth do
      T[K].Batch := T[K].Batch + REQ;
    C[K].Init(T[K], Loop);
  end;
  Batches := N div Depth;
  K := 0;
  T0 := MonoNowNs;
  for I := 1 to Batches do
  begin
    T[K].Armed := True;
    C[K].Run;
    Inc(K);
    if K = Conns then
      K := 0;
  end;
  Result := (MonoNowNs - T0) / (Batches * Depth);
  W := 0;
  for K := 0 to Conns - 1 do
  begin
    Inc(W, T[K].Writes);
    C[K].Done;
    T[K].Free;
  end;
  if W <> QWord(Batches) then
    raise Exception.CreateFmt('proto: %d writes for %d batches', [W, Batches]);
end;

function BenchDispatch(Loop: TLoop; Svc: THttpService; N, Depth: Int64; out Writes: QWord): Double;
var
  T: array of TMemTransport;
  D: array of TH1Dispatcher;
  Cfg: TH1Config;
  I, Batches: Int64;
  K: Integer;
  T0: Int64;
  Reqs: QWord;
begin
  Cfg := BenchmarkServerConfig.H1;
  SetLength(T, Conns);
  SetLength(D, Conns);
  for K := 0 to Conns - 1 do
  begin
    T[K] := TMemTransport.Create;
    T[K].Batch := '';
    for I := 1 to Depth do
      T[K].Batch := T[K].Batch + REQ;
    D[K] := TH1Dispatcher.Create(Loop, -1);
    D[K].OwnsTransport := False;
    D[K].Setup(T[K], Svc, Cfg, nil, 1, nil);
  end;
  Batches := N div Depth;
  K := 0;
  T0 := MonoNowNs;
  for I := 1 to Batches do
  begin
    T[K].Armed := True;
    D[K].Run;
    Inc(K);
    if K = Conns then
      K := 0;
  end;
  Result := (MonoNowNs - T0) / (Batches * Depth);
  Writes := 0;
  Reqs := 0;
  for K := 0 to Conns - 1 do
  begin
    Inc(Writes, T[K].Writes);
    if D[K].Closed then
      raise Exception.Create('dispatch: connection closed');
    Inc(Reqs, D[K].RequestCount);
    D[K].Abort;
    D[K].Free;
    T[K].Free;
  end;
  if Reqs <> QWord(Batches * Depth) then
    raise Exception.CreateFmt('dispatch: %d requests for %d', [Reqs, Batches * Depth]);
end;

function NopThread(Arg: Pointer): PtrInt;
begin
  Result := 0;
end;

function Median(var A: array of Double): Double;
var
  I, J: Integer;
  X: Double;
begin
  for I := 1 to High(A) do
  begin
    X := A[I];
    J := I - 1;
    while (J >= 0) and (A[J] > X) do
    begin
      A[J + 1] := A[J];
      Dec(J);
    end;
    A[J + 1] := X;
  end;
  Result := A[Length(A) div 2];
end;

var
  Loop: TLoop;
  Pool: TExchangePool;
  Svc: TPlaintextService;
  N: Int64;
  Runs, R, DI: Integer;
  Depths: array[0..1] of Integer = (1, 16);
  P, Dsp: array of Double;
  MP, MD: array[0..1] of Double;
  Writes: QWord;
begin
  N := 4000000;
  Runs := 5;
  if ParamCount >= 1 then N := StrToInt64(ParamStr(1));
  if ParamCount >= 2 then Runs := StrToInt(ParamStr(2));
  { MT=1: start (and join) one thread first, so IsMultiThread is True as in
    the server (locked refcounts, the threaded heap) }
  Conns := StrToIntDef(GetEnvironmentVariable('CONNS'), 1);
  if GetEnvironmentVariable('MT') = '1' then
    WaitForThreadTerminate(BeginThread(@NopThread, nil), 0);
  Loop := TLoop.Create(0);
  Pool := TExchangePool.Create;
  Loop.Exchanges := Pool;
  Svc := TPlaintextService.Create;
  Svc.FCall := TPlaintextCall.Create;
  if ParamCount >= 3 then
  begin
    { profiling: one mode, depth 16 }
    if ParamStr(3) = 'proto' then
      WriteLn(Format('proto depth 16: %.1f ns/req', [BenchProto(Loop, N, 16)]))
    else
      WriteLn(Format('dispatch depth 16: %.1f ns/req', [BenchDispatch(Loop, Svc, N, 16, Writes)]));
    Svc.FCall.Free;
    Svc.Free;
    Loop.Free;
    Pool.Free;
    Halt(0);
  end;
  SetLength(P, Runs);
  SetLength(Dsp, Runs);
  for DI := 0 to 1 do
  begin
    { warm-up }
    BenchProto(Loop, N div 4, Depths[DI]);
    BenchDispatch(Loop, Svc, N div 4, Depths[DI], Writes);
    for R := 0 to Runs - 1 do
    begin
      P[R] := BenchProto(Loop, N, Depths[DI]);
      Dsp[R] := BenchDispatch(Loop, Svc, N, Depths[DI], Writes);
      WriteLn(Format('run %d depth %2d: proto %7.1f ns/req   dispatch %7.1f ns/req   (%d writes)',
        [R + 1, Depths[DI], P[R], Dsp[R], Writes]));
    end;
    MP[DI] := Median(P);
    MD[DI] := Median(Dsp);
  end;
  for DI := 0 to 1 do
    WriteLn(Format('median depth %2d: proto %.1f ns/req, dispatch %.1f ns/req, difference %.1f ns/req',
      [Depths[DI], MP[DI], MD[DI], MD[DI] - MP[DI]]));
  WriteLn(Format('gate (depth 16): dispatch %.1f <= proto %.1f + %.0f = %.1f ns/req: %s',
    [MD[1], MP[1], BUDGET_NS, MP[1] + BUDGET_NS, BoolToStr(MD[1] <= MP[1] + BUDGET_NS, 'PASS', 'FAIL')]));
  Svc.FCall.Free;
  Svc.Free;
  Loop.Free;
  Pool.Free;
  if MD[1] > MP[1] + BUDGET_NS then
    Halt(1);
end.
