{ wdproto - M3 performance prototype: the reactor/connection loop design of
  docs/design/m3-candidates/perf.md, reduced to the TFB plaintext path.

  - one loop thread per allowed CPU (sched_getaffinity), optional pinning
  - LISTEN=reuseport (default): one SO_REUSEPORT listener per loop
    LISTEN=exclusive: one shared listener, EPOLLEXCLUSIVE in every loop
  - connections: edge-triggered EPOLLIN|EPOLLOUT|EPOLLRDHUP, registered once
  - per connection: 8 KiB read buffer, flatten write buffer (TBytes),
    request THttpHeaders (external slices into the read buffer), response
    THttpHeaders reused; parse with bearings.http1.role.ServerParse and encode with
    ServerEncode + TEncoder exactly like the real conn will
  - all buffered (pipelined) requests are answered, then ONE write
    (hyper pipeline_flush(true) behaviour, which the TFB entry enables)
  - Date: per-loop TDateCache, checked once per epoll_wait iteration with
    libc (vDSO) clock_gettime
  Usage: wdproto <port>   env: THREADS=n PIN=1 LISTEN=exclusive READSZ=8192 }
program wdproto;

{$mode objfpc}{$H+}

uses
  cthreads, BaseUnix, Unix, Linux, Sockets, Syscall, SysUtils,
  bearings.http1.parser, bearings.http.headers, bearings.http1.encode, bearings.http1.role,
  bearings.http.date, bearings.http.uri;

const
  SYS_accept4 = 288;
  SYS_epoll_create1 = 291;
  SYS_sched_getaffinity = 204;
  SYS_sched_setaffinity = 203;
  SOCK_NONBLOCK = $800;
  SOCK_CLOEXEC = $80000;
  EPOLLRDHUP = $2000;
  EPOLLEXCLUSIVE = 1 shl 28;
  MAX_EVENTS = 512;

  BODY: array[0..12] of AnsiChar = 'Hello, world!';
  HN_SRV: array[0..5] of AnsiChar = 'server';
  HV_SRV: array[0..4] of AnsiChar = 'hyper';
  HN_CT: array[0..11] of AnsiChar = 'content-type';
  HV_CT: array[0..9] of AnsiChar = 'text/plain';
  HN_CL: array[0..13] of AnsiChar = 'content-length';
  HV_CL: array[0..1] of AnsiChar = '13';
  PATH_PT: array[0..9] of AnsiChar = '/plaintext';

type
  PConn = ^TConn;
  TConn = record
    Fd: cint;
    RBuf: PByte;
    RCap, RLen: SizeInt;
    WBuf: TBytes;
    WLen, WPos: SizeInt;
    ReqHeaders: THttpHeaders;
    RespHeaders: THttpHeaders;
    Enc: TEncoder;
    Head: TResponseHead;
    ReadPending: Boolean;   { edge seen while output was blocked }
  end;

  PLoop = ^TLoop;
  TLoop = record
    Index: Integer;
    Cpu: Integer;
    Ep: cint;
    Lfd: cint;
    Date: TDateCache;
    Ctx: TH1ParseContext;
    Params: TServerEncodeParams;
    Conns: Integer;
    Thread: TThreadID;
    RPool: array of PByte;      { idle-connection buffer pools (POOL=1) }
    RPoolN: Integer;
    WPool: array of Pointer;
    WPoolN: Integer;
  end;

function libc_clock_gettime(clk: cint; tp: ptimespec): cint; cdecl; external 'c' name 'clock_gettime';

var
  Port: Word;
  ReadSize: SizeInt = 8192;
  FlushEach: Boolean;
  BufPool: Boolean;
  Pin: Boolean;
  SharedListen: Boolean;
  SharedLfd: cint = -1;
  Loops: array of TLoop;

function MakeListener(APort: Word): cint;
var
  one: cint;
  addr: TInetSockAddr;
begin
  one := 1;
  Result := fpSocket(AF_INET, SOCK_STREAM or SOCK_NONBLOCK or SOCK_CLOEXEC, 0);
  fpSetSockOpt(Result, SOL_SOCKET, SO_REUSEADDR, @one, SizeOf(one));
  if not SharedListen then
    fpSetSockOpt(Result, SOL_SOCKET, SO_REUSEPORT, @one, SizeOf(one));
  fpSetSockOpt(Result, IPPROTO_TCP, TCP_NODELAY, @one, SizeOf(one));
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_addr.s_addr := 0;
  addr.sin_port := htons(APort);
  if fpBind(Result, @addr, SizeOf(addr)) <> 0 then
  begin
    WriteLn(StdErr, 'bind failed errno=', fpgeterrno);
    Halt(1);
  end;
  fpListen(Result, 4096);
end;

procedure CloseConn(L: PLoop; C: PConn);
begin
  fpClose(C^.Fd);   { close removes it from the epoll set }
  FreeMem(C^.RBuf);
  C^.ReqHeaders.Free;
  C^.RespHeaders.Free;
  Dispose(C);
  Dec(L^.Conns);
end;

{ returns False when the connection was closed }
function Flush(L: PLoop; C: PConn): Boolean;
var
  n: ssize_t;
begin
  Result := True;
  while C^.WPos < C^.WLen do
  begin
    n := fpWrite(C^.Fd, @C^.WBuf[C^.WPos], C^.WLen - C^.WPos);
    if n > 0 then
      Inc(C^.WPos, n)
    else if (n < 0) and (fpgeterrno = ESysEAGAIN) then
      Exit   { wait for EPOLLOUT (already registered, edge-triggered) }
    else
    begin
      CloseConn(L, C);
      Exit(False);
    end;
  end;
  C^.WPos := 0;
  C^.WLen := 0;
end;

procedure HandleRequest(L: PLoop; C: PConn; Base: PByte; const Msg: TParsedRequestHead);
var
  P: PByte;
  PLen: SizeInt;
  EB: TEncodedBuf;
begin
  C^.RespHeaders.Clear;
  Msg.Uri.GetPath(Base, P, PLen);
  if (PLen = 10) and CompareMem(P, @PATH_PT, 10) then
  begin
    C^.RespHeaders.Add(@HN_SRV, 6, @HV_SRV, 5);
    C^.RespHeaders.Add(@HN_CT, 12, @HV_CT, 10);
    C^.RespHeaders.Add(@HN_CL, 14, @HV_CL, 2);
    C^.Head.Status := 200;
    L^.Params.Body := blkKnown;
    L^.Params.BodyLen := 13;
  end
  else
  begin
    C^.RespHeaders.Add(@HN_SRV, 6, @HV_SRV, 5);
    C^.Head.Status := 404;
    L^.Params.Body := blkNone;
    L^.Params.BodyLen := 0;
  end;
  C^.Head.Version := hv11;
  C^.Head.Headers := C^.RespHeaders;
  L^.Params.KeepAlive := Msg.KeepAlive;
  L^.Params.ReqMethod := Msg.Method;
  ServerEncode(C^.Head, L^.Params, C^.WBuf, C^.WLen, C^.Enc);
  if L^.Params.Body = blkKnown then
  begin
    C^.Enc.Encode(@BODY, 13, EB);
    EB.AppendTo(C^.WBuf, C^.WLen);
  end;
end;

{ Parses and answers every complete request in the read buffer.
  Returns False when the connection was closed. }
function Process(L: PLoop; C: PConn): Boolean;
var
  Pos: SizeInt;
  St: TServerParseStatus;
  Msg: TParsedRequestHead;
begin
  Result := True;
  Pos := 0;
  while Pos < C^.RLen do
  begin
    St := ServerParse(C^.RBuf + Pos, C^.RLen - Pos, L^.Ctx, C^.ReqHeaders, Msg);
    if St = spsComplete then
    begin
      if Msg.Decode <> DECODED_LENGTH_ZERO then
      begin
        CloseConn(L, C);   { prototype: no request bodies }
        Exit(False);
      end;
      HandleRequest(L, C, C^.RBuf + Pos, Msg);
      Inc(Pos, Msg.HeadLen);
      if FlushEach then
        if not Flush(L, C) then Exit(False);
    end
    else if St = spsPartial then
      Break
    else
    begin
      CloseConn(L, C);
      Exit(False);
    end;
  end;
  if Pos > 0 then
  begin
    if Pos < C^.RLen then
      Move(C^.RBuf[Pos], C^.RBuf[0], C^.RLen - Pos);
    Dec(C^.RLen, Pos);
  end;
end;

procedure AcquireBuffers(L: PLoop; C: PConn);
begin
  if C^.RBuf = nil then
  begin
    if L^.RPoolN > 0 then
    begin
      Dec(L^.RPoolN);
      C^.RBuf := L^.RPool[L^.RPoolN];
    end
    else
      C^.RBuf := GetMem(ReadSize);
  end;
  if Pointer(C^.WBuf) = nil then
  begin
    if L^.WPoolN > 0 then
    begin
      Dec(L^.WPoolN);
      Pointer(C^.WBuf) := L^.WPool[L^.WPoolN];   { raw move: no refcount traffic }
    end
    else
      SetLength(C^.WBuf, 8192);
  end;
end;

{ idle connection (nothing buffered either way): give both buffers back }
procedure ReleaseIfIdle(L: PLoop; C: PConn);
begin
  if (not BufPool) or (C^.RLen <> 0) or (C^.WLen <> 0) or C^.ReadPending then Exit;
  if L^.RPoolN = Length(L^.RPool) then SetLength(L^.RPool, 2 * L^.RPoolN + 64);
  L^.RPool[L^.RPoolN] := C^.RBuf;
  Inc(L^.RPoolN);
  C^.RBuf := nil;
  if L^.WPoolN = Length(L^.WPool) then SetLength(L^.WPool, 2 * L^.WPoolN + 64);
  L^.WPool[L^.WPoolN] := Pointer(C^.WBuf);
  Inc(L^.WPoolN);
  Pointer(C^.WBuf) := nil;
end;

procedure OnReadable(L: PLoop; C: PConn);
var
  n: ssize_t;
  Space: SizeInt;
begin
  if C^.WPos < C^.WLen then
  begin
    C^.ReadPending := True;   { backpressure: do not read while output is blocked }
    Exit;
  end;
  C^.ReadPending := False;
  AcquireBuffers(L, C);
  repeat
    Space := C^.RCap - C^.RLen;
    if Space = 0 then
    begin
      CloseConn(L, C);   { prototype: head larger than the buffer }
      Exit;
    end;
    n := fpRead(C^.Fd, PChar(C^.RBuf + C^.RLen), Space);
    if n > 0 then
    begin
      Inc(C^.RLen, n);
      if not Process(L, C) then Exit;
      if not Flush(L, C) then Exit;
      if C^.WPos < C^.WLen then
      begin
        C^.ReadPending := True;
        Exit;
      end;
      if n < Space then
      begin
        ReleaseIfIdle(L, C);
        Exit;   { short read: socket drained, the next edge will come }
      end;
    end
    else if n = 0 then
    begin
      CloseConn(L, C);
      Exit;
    end
    else
    begin
      if fpgeterrno <> ESysEAGAIN then
        CloseConn(L, C);
      Exit;
    end;
  until False;
end;

procedure AcceptAll(L: PLoop);
var
  fd: cint;
  C: PConn;
  ev: TEpoll_Event;
begin
  repeat
    fd := do_syscall(SYS_accept4, L^.Lfd, 0, 0, SOCK_NONBLOCK or SOCK_CLOEXEC);
    if fd < 0 then Exit;
    New(C);
    C^.Fd := fd;
    C^.RCap := ReadSize;
    C^.RBuf := nil;
    C^.RLen := 0;
    if not BufPool then
    begin
      C^.RBuf := GetMem(ReadSize);
      SetLength(C^.WBuf, 8192);
    end;
    C^.WLen := 0;
    C^.WPos := 0;
    C^.ReqHeaders := THttpHeaders.Create(16, 0);
    C^.RespHeaders := THttpHeaders.Create(8, 256);
    C^.Head := DefaultResponseHead;
    C^.ReadPending := False;
    Inc(L^.Conns);
    ev.Events := EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET;
    ev.Data.ptr := C;
    epoll_ctl(L^.Ep, EPOLL_CTL_ADD, fd, @ev);
  until False;
end;

function LoopMain(Arg: Pointer): PtrInt;
var
  L: PLoop;
  evs: array[0..MAX_EVENTS - 1] of TEpoll_Event;
  n, i: cint;
  ev: TEpoll_Event;
  ts: TTimeSpec;
  C: PConn;
  mask: array[0..15] of QWord;
begin
  Result := 0;
  L := PLoop(Arg);
  if Pin then
  begin
    FillChar(mask, SizeOf(mask), 0);
    mask[L^.Cpu div 64] := QWord(1) shl (L^.Cpu mod 64);
    do_syscall(SYS_sched_setaffinity, 0, SizeOf(mask), TSysParam(@mask));
  end;
  L^.Ep := do_syscall(SYS_epoll_create1, SOCK_CLOEXEC);
  if SharedListen then
  begin
    L^.Lfd := SharedLfd;
    ev.Events := EPOLLIN or EPOLLEXCLUSIVE;
  end
  else
  begin
    L^.Lfd := MakeListener(Port);
    ev.Events := EPOLLIN;
  end;
  ev.Data.ptr := nil;
  epoll_ctl(L^.Ep, EPOLL_CTL_ADD, L^.Lfd, @ev);
  L^.Ctx := DefaultParseContext;
  L^.Params := DefaultEncodeParams;
  L^.Params.DateHeader := True;
  L^.Date.Init;
  L^.Params.Date := L^.Date.Buffer;
  repeat
    n := epoll_wait(L^.Ep, @evs[0], MAX_EVENTS, 1000);
    libc_clock_gettime(CLOCK_REALTIME, @ts);
    L^.Date.Check(Int64(ts.tv_sec) * 1000000 + ts.tv_nsec div 1000);
    for i := 0 to n - 1 do
    begin
      C := PConn(evs[i].Data.ptr);
      if C = nil then
      begin
        AcceptAll(L);
        Continue;
      end;
      if (evs[i].Events and EPOLLOUT) <> 0 then
      begin
        if C^.WPos < C^.WLen then
        begin
          if not Flush(L, C) then Continue;
          if not C^.ReadPending then ReleaseIfIdle(L, C);
        end;
        if C^.ReadPending and (C^.WPos >= C^.WLen) then
        begin
          OnReadable(L, C);
          Continue;
        end;
      end;
      if (evs[i].Events and (EPOLLIN or EPOLLRDHUP or EPOLLHUP or EPOLLERR)) <> 0 then
        OnReadable(L, C);
    end;
  until False;
end;

function AllowedCpus: TBoundArray;
var
  mask: array[0..15] of QWord;
  r, i, k: Integer;
begin
  FillChar(mask, SizeOf(mask), 0);
  r := do_syscall(SYS_sched_getaffinity, 0, SizeOf(mask), TSysParam(@mask));
  SetLength(Result, 0);
  if r <= 0 then Exit;
  k := 0;
  for i := 0 to 1023 do
    if (mask[i div 64] and (QWord(1) shl (i mod 64))) <> 0 then
    begin
      SetLength(Result, k + 1);
      Result[k] := i;
      Inc(k);
    end;
end;

var
  Cpus: TBoundArray;
  NThreads, i: Integer;
  s: string;
begin
  Port := StrToIntDef(ParamStr(1), 8080);
  Cpus := AllowedCpus;
  NThreads := StrToIntDef(GetEnvironmentVariable('THREADS'), Length(Cpus));
  Pin := GetEnvironmentVariable('PIN') = '1';
  SharedListen := GetEnvironmentVariable('LISTEN') = 'exclusive';
  ReadSize := StrToIntDef(GetEnvironmentVariable('READSZ'), 8192);
  FlushEach := GetEnvironmentVariable('FLUSH_EACH') = '1';
  BufPool := GetEnvironmentVariable('POOL') = '1';
  s := '';
  for i := 0 to High(Cpus) do s := s + IntToStr(Cpus[i]) + ' ';
  WriteLn(StdErr, 'wdproto: ', NThreads, ' loops, cpus [', s, '] pin=', Pin,
    ' listen=', GetEnvironmentVariable('LISTEN'), ' port ', Port,
    ' GetCPUCount=', GetCPUCount);
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  if SharedListen then
    SharedLfd := MakeListener(Port);
  SetLength(Loops, NThreads);
  for i := 0 to NThreads - 1 do
  begin
    FillChar(Loops[i], SizeOf(TLoop), 0);
    Loops[i].Index := i;
    if Length(Cpus) > 0 then
      Loops[i].Cpu := Cpus[i mod Length(Cpus)];
    Loops[i].Thread := BeginThread(@LoopMain, @Loops[i]);
  end;
  repeat
    Sleep(1000);
  until False;
end.
