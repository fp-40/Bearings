{ rawsrv - M3 step S1 raw loop baseline: the wdproto plaintext server
  (bench/wdproto.pas) rebuilt on the M3 runtime (design m3-transport.md
  section 9, S1): TLoop (one per thread), TListener (one SO_REUSEPORT
  listener per loop, TCP_NODELAY, backlog 4096), TIoTask + TTcpTransport
  with tokio's readiness rules, read and write blocks from the loop's
  TBlockPool, the per-loop date cache. No HTTP state machine, no service
  layer.

  Per request it does exactly what wdproto POOL=1 does, so the comparison
  measures the runtime and nothing else: ServerParse into a per-connection
  THttpHeaders (external slices), the same three response headers added to
  a per-connection THttpHeaders, ServerEncode (the M3 TByteVec overload,
  same bytes) and TEncoder.Encode of the 13-byte body; every buffered
  (pipelined) request is answered, then one write (hyper's
  pipeline_flush(true)); request bodies are not supported (the connection
  is closed). An idle connection gives its read and write blocks back to the
  loop pool (wdproto POOL=1). Response bytes equal wdproto's and hyper's
  ("server: hyper" is kept so the bytes are identical).

  Usage: rawsrv [port]     env: THREADS=n (default DefaultLoopCount),
                                PIN=1 (pin loop i to the i-th usable CPU),
                                READSZ (read block, default 8192)
  Build: fpc -Mobjfpc -Sh -O3 -CX -XX -Xs -Fusrc/rt -Fusrc/http1 bench/rawsrv.pas }
program rawsrv;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, ctypes,
  bearings.rt.sys, bearings.rt.cpu, bearings.rt.buf, bearings.rt.loop, bearings.rt.net,
  bearings.http1.parser, bearings.http.headers, bearings.http1.encode, bearings.http1.role, bearings.http.date, bearings.http.uri;

const
  BODY: array[0..12] of AnsiChar = 'Hello, world!';
  HN_SRV: array[0..5] of AnsiChar = 'server';
  HV_SRV: array[0..4] of AnsiChar = 'hyper';
  HN_CT: array[0..11] of AnsiChar = 'content-type';
  HV_CT: array[0..9] of AnsiChar = 'text/plain';
  HN_CL: array[0..13] of AnsiChar = 'content-length';
  HV_CL: array[0..1] of AnsiChar = '13';
  PATH_PT: array[0..9] of AnsiChar = '/plaintext';

type
  PLoopCtx = ^TLoopCtx;
  TLoopCtx = record
    Loop: TLoop;
    Cpu: Integer;
    Ctx: TH1ParseContext;
    Params: TServerEncodeParams;
    Enc: TEncodeContext;
    Listener: TListener;
    Thread: TThreadID;
  end;

  TAcceptor = class
    procedure OnAccept(Loop: TLoop; var Fd: cint; const Peer: TSockAddrStorage);
  end;

  TRawConn = class(TIoTask)
  private
    T: TTcpTransport;
    LC: PLoopCtx;
    RBlock: PBufBlock;
    RLen: SizeInt;
    W: TByteVec;
    WPos: SizeInt;
    ReqHeaders: THttpHeaders;
    RespHeaders: THttpHeaders;
    Enc: TEncoder;
    Head: TResponseHead;
    procedure CloseConn;
    function Flush: Boolean;          { False: closed }
    function Process: Boolean;        { False: closed }
    procedure HandleRequest(Base: PByte; const Msg: TParsedRequestHead);
    procedure ReleaseIfIdle; inline;
  public
    constructor Create(ALoop: TLoop; AFd: cint; ALC: PLoopCtx);
    procedure Run; override;
    procedure Abort; override;
  end;

var
  Port: Word;
  ReadSize: SizeInt = 8192;
  Pin: Boolean;
  Loops: array of TLoopCtx;
  Acceptor: TAcceptor;

constructor TRawConn.Create(ALoop: TLoop; AFd: cint; ALC: PLoopCtx);
begin
  inherited Create(ALoop, AFd);
  LC := ALC;
  T := NewTcpTransport(@Src);
  W := Default(TByteVec);
  ReqHeaders := THttpHeaders.Create(16, 0);
  RespHeaders := THttpHeaders.Create(8, 256);
  Head := DefaultResponseHead;
  if not ALoop.Register(@Src, EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET) then
    raise Exception.Create('epoll_ctl(ADD) failed');
end;

procedure TRawConn.CloseConn;
begin
  T.Close;
  T.Free;
  T := nil;
  if RBlock <> nil then
    Loop.Blocks.Give(RBlock);
  RBlock := nil;
  W.Len := 0;
  W.ReleaseIdle(@Loop.Blocks);
  ReqHeaders.Free;
  RespHeaders.Free;
  Close;                              { freed after the event batch }
end;

procedure TRawConn.Abort;
begin
  if T <> nil then
    CloseConn;
end;

function TRawConn.Flush: Boolean;
var
  N: SizeInt;
begin
  Result := True;
  while WPos < W.Len do
  begin
    N := T.Write(W.Data + WPos, W.Len - WPos);
    if N > 0 then
      Inc(WPos, N)
    else if N = -ESysEAGAIN then
      Exit                            { wait for the EPOLLOUT edge }
    else
    begin
      CloseConn;
      Exit(False);
    end;
  end;
  WPos := 0;
  W.Len := 0;
end;

procedure TRawConn.HandleRequest(Base: PByte; const Msg: TParsedRequestHead);
var
  P: PByte;
  PLen, N: SizeInt;
  EB: TEncodedBuf;
begin
  RespHeaders.Clear;
  Msg.Uri.GetPath(Base, P, PLen);
  if (PLen = 10) and CompareMem(P, @PATH_PT, 10) then
  begin
    RespHeaders.Add(@HN_SRV, 6, @HV_SRV, 5);
    RespHeaders.Add(@HN_CT, 12, @HV_CT, 10);
    RespHeaders.Add(@HN_CL, 14, @HV_CL, 2);
    Head.Status := 200;
    LC^.Params.Body := blkKnown;
    LC^.Params.BodyLen := 13;
  end
  else
  begin
    RespHeaders.Add(@HN_SRV, 6, @HV_SRV, 5);
    Head.Status := 404;
    LC^.Params.Body := blkNone;
    LC^.Params.BodyLen := 0;
  end;
  Head.Version := hv11;
  Head.Headers := RespHeaders;
  LC^.Params.KeepAlive := Msg.KeepAlive;
  LC^.Params.ReqMethod := Msg.Method;
  ServerEncode(Head, LC^.Params, LC^.Enc, W, @Loop.Blocks, Enc);
  if LC^.Params.Body = blkKnown then
  begin
    Enc.Encode(@BODY, 13, EB);
    N := EB.Remaining;
    W.Reserve(N, @Loop.Blocks);
    EB.CopyTo(W.Data + W.Len);
    Inc(W.Len, N);
  end;
end;

function TRawConn.Process: Boolean;
var
  Pos: SizeInt;
  St: TServerParseStatus;
  Msg: TParsedRequestHead;
  Buf: PByte;
begin
  Result := True;
  Pos := 0;
  Buf := RBlock^.Data;
  while Pos < RLen do
  begin
    St := ServerParse(Buf + Pos, RLen - Pos, LC^.Ctx, ReqHeaders, Msg);
    if St = spsComplete then
    begin
      if Msg.Decode <> DECODED_LENGTH_ZERO then
      begin
        CloseConn;                    { no request bodies here }
        Exit(False);
      end;
      HandleRequest(Buf + Pos, Msg);
      Inc(Pos, Msg.HeadLen);
    end
    else if St = spsPartial then
      Break
    else
    begin
      CloseConn;
      Exit(False);
    end;
  end;
  if Pos > 0 then
  begin
    if Pos < RLen then
      Move(Buf[Pos], Buf[0], RLen - Pos);
    Dec(RLen, Pos);
  end;
end;

procedure TRawConn.ReleaseIfIdle;
begin
  if (RLen = 0) and (W.Len = 0) and (RBlock <> nil) then
  begin
    Loop.Blocks.Give(RBlock);
    RBlock := nil;
    W.ReleaseIdle(@Loop.Blocks);
  end;
end;

procedure TRawConn.Run;
var
  N, Space: SizeInt;
begin
  if WPos < W.Len then
  begin
    if not Flush then
      Exit;
    if WPos < W.Len then
      Exit;                           { still blocked: no reading (backpressure) }
  end;
  repeat
    if RBlock = nil then
      RBlock := Loop.Blocks.Take(ReadSize);
    Space := ReadSize - RLen;
    if Space = 0 then
    begin
      CloseConn;                      { head larger than the buffer }
      Exit;
    end;
    N := T.Read(RBlock^.Data + RLen, Space);
    if N > 0 then
    begin
      Inc(RLen, N);
      if not Process then
        Exit;
      if not Flush then
        Exit;
      if WPos < W.Len then
        Exit;                         { output blocked: stop reading }
    end
    else if N = -ESysEAGAIN then
    begin
      ReleaseIfIdle;
      Exit;                           { a short read cleared rdRead: no syscall was made }
    end
    else
    begin
      CloseConn;                      { EOF or error }
      Exit;
    end;
  until False;
end;

procedure TAcceptor.OnAccept(Loop: TLoop; var Fd: cint; const Peer: TSockAddrStorage);
var
  F: cint;
begin
  { the connection owns the fd from its constructor on (a raising
    constructor closes it in TIoTask.Destroy) }
  F := Fd;
  Fd := -1;
  TRawConn.Create(Loop, F, @Loops[Loop.Index]);
end;

function LoopMain(Arg: Pointer): PtrInt;
var
  LC: PLoopCtx;
begin
  LC := Arg;
  if Pin then
    PinCurrentThread(LC^.Cpu);
  LC^.Loop.Run;
  Result := 0;
end;

var
  Cpus: TCpuList;
  NThreads, I: Integer;
  Spec: TListenSpec;
  Fd: cint;
  Bound: Word;
  E: cint;
  S: string;
begin
  Port := StrToIntDef(ParamStr(1), 8080);
  Cpus := UsableCpus;
  NThreads := StrToIntDef(GetEnvironmentVariable('THREADS'), DefaultLoopCount);
  Pin := GetEnvironmentVariable('PIN') = '1';
  ReadSize := StrToIntDef(GetEnvironmentVariable('READSZ'), 8192);
  S := '';
  for I := 0 to High(Cpus) do
    S := S + IntToStr(Cpus[I]) + ' ';
  WriteLn(StdErr, 'rawsrv: ', NThreads, ' loops, cpus [', S, '] pin=', Pin, ' port ', Port);
  IgnoreSigPipe;
  Acceptor := TAcceptor.Create;
  Spec.Host := '0.0.0.0';
  Spec.Port := Port;
  Spec.Backlog := 4096;
  Spec.Mode := amReusePort;
  Spec.NoDelay := True;
  SetLength(Loops, NThreads);
  for I := 0 to NThreads - 1 do
  begin
    FillChar(Loops[I], SizeOf(TLoopCtx), 0);
    Loops[I].Loop := TLoop.Create(I);
    if Length(Cpus) > 0 then
      Loops[I].Cpu := Cpus[I mod Length(Cpus)];
    Loops[I].Ctx := DefaultParseContext;
    Loops[I].Params := DefaultEncodeParams;
    Loops[I].Params.DateHeader := True;
    Loops[I].Enc.Date := LoopDate(Loops[I].Loop);
    Loops[I].Enc.Trailers := nil;
    if not OpenListener(Spec, True, Fd, Bound, E) then
    begin
      WriteLn(StdErr, 'rawsrv: listen failed: errno ', E);
      Halt(1);
    end;
    if Spec.Port = 0 then
      Spec.Port := Bound;               { the first loop binds port 0, the others that port }
    Loops[I].Listener := TListener.Create(Loops[I].Loop, Fd, @Acceptor.OnAccept);
  end;
  for I := 0 to NThreads - 1 do
    Loops[I].Thread := BeginThread(@LoopMain, @Loops[I]);
  repeat
    Sleep(1000);
  until False;
end.
