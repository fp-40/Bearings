{ Step S7 (docs/design.md section 9): end-to-end stress of the
  worker paths through TServer + dispatcher + workers with random handler
  behaviour and random client disconnects. Written by the fourth S7
  verifier (concurrency lens, build/S7-verify4-race/evidence/s7stress.pas);
  taken into the repository in the S7 fix round 5 (deviation S7-34), with
  one change: the helper holder is shared before or after the offload
  (seed parity), since round 5 made the call in flight a holder (S7-32).
  tools/s7-stress.sh builds and runs it (natively and under drd). Checks:
  - a handler never sees a clean end of a body that did not end
    (total <> declared length) and never sees wrong bytes (pattern);
  - no assertion fires in a handler (EAssertionFailed is counted) or on a
    loop (LoopErrorProc);
  - no client waits forever (timeouts counted as hangs);
  - ExchangesLive returns to its start value after the server is freed.
  S7 fix round 7 (deviations S7-43, S7-47): a complete streamed response
  of mode 7 or 12 holds every frame the worker wrote (the stream ends only
  when its last producer is gone); mode 12 is the sixth S7 verifiers'
  repro r1 (the call begins the stream, shares it with a helper that
  writes, then offloads the worker in the same Poll); a connection reset
  in a mode that may leave the request body unread (hyper's drain or
  close: the kernel resets a socket closed with unread bytes, and the
  reset can discard the end of the response) is counted apart, not as a
  client error.
  Env: CLIENTS (24), CONNS (per client, 40), SEED, WORKERS (16), LOOPS (2),
  ONLY_MODE (-1: random handler modes; 0-12: that mode only),
  STOP_EARLY_MS (0: normal run; >0: the server is destroyed while traffic
  runs), RCV_TIMEOUT_S (20). }
program stress_workers;

{$mode objfpc}{$H+}{$R-}{$Q-}

uses
  {$IFDEF WD_DRD}cmem,{$ENDIF}
  cthreads, Classes, SysUtils, Sockets, BaseUnix, ctypes,
  bearings.rt.sys, bearings.rt.sync, bearings.rt.clock, bearings.rt.loop, bearings.rt.workers, bearings.rt.buf,
  bearings.http.headers, bearings.http.error, bearings.http.exchange, bearings.server;

const
  CRLF = #13#10;
  NMODES = 13;

var
  Violations, HandlerAsserts, LoopErrors, Hangs, ClientErrors: LongInt;
  CleanOk, Gone, BodyErrs, Raised, Requests, HelperRuns, HeadAfterCancel: LongInt;
  NClients, NConns, RcvTimeoutS: Integer;
  Seed0: LongWord;
  Port: Word;
  ClientsDone: LongInt;
  HelperPool: TWorkerPool;
  StopEarly: Boolean;
  OnlyMode: Integer;                 { ONLY_MODE: every request uses this handler mode (-1: random) }
  ServerFreed, LateHelperReleases: LongInt;
  ResetUnread, StreamsChecked: LongInt;

var
  LogLock: TRTLCriticalSection;

procedure Log(const S: string);
begin
  EnterCriticalSection(LogLock);
  WriteLn(StdErr, S);
  Flush(StdErr);
  LeaveCriticalSection(LogLock);
end;

{ BoolToStr(B, True) initializes SysUtils' TrueBoolStrs lazily without a
  lock (CheckBoolStrs), which drd reports when two threads log at once }
function B2S(B: Boolean): string;
begin
  if B then
    Result := 'True'
  else
    Result := 'False';
end;

var
  MaxRequestMs: LongInt;             { the longest request (head sent to response read), client side }

procedure NoteRequestMs(Ms: Int64);
var
  M: LongInt;
begin
  repeat
    M := AtomicLoad(MaxRequestMs);
    if Ms <= M then
      Exit;
  until InterlockedCompareExchange(MaxRequestMs, LongInt(Ms), M) = M;
end;

procedure Violation(const Msg: string);
begin
  InterLockedIncrement(Violations);
  Log('VIOLATION: ' + Msg);
end;

{ ---- per-thread rng (xorshift32) ---- }
function Rnd(var S: LongWord; N: LongWord): LongWord;
begin
  S := S xor (S shl 13);
  S := S xor (S shr 17);
  S := S xor (S shl 5);
  if S = 0 then
    S := 2463534242;
  if N = 0 then
    Result := 0
  else
    Result := S mod N;
end;

function PatByte(Seed: LongWord; I: SizeInt): Byte; inline;
begin
  Result := Byte((I * 7 + Seed * 13 + (I shr 8)) and $FF);
end;

procedure MicroSleep(Us: Integer);
var
  T0: Int64;
begin
  if Us <= 0 then
    Exit;
  if Us < 200 then
  begin
    T0 := MonoNowNs;
    while MonoNowNs - T0 < Int64(Us) * 1000 do
      CpuRelax;
  end
  else
    Sleep(Us div 1000);
end;

{ ---- server side ---- }

function HdrInt(Ex: TExchange; const Name: RawByteString): Int64;
var
  V: TByteSlice;
  S: RawByteString;
begin
  if not Ex.Header(Name, V) then
    Exit(-1);
  SetString(S, PAnsiChar(V.P), V.Len);
  Result := StrToInt64Def(S, -1);
end;

type
  THandler = class(TBlockingHandler)
  public
    procedure Run(Ex: TExchange); override;
  end;

  THelperItem = class(TWorkItem)
  public
    Ex: TExchange;
    Kind: Integer;
    R: LongWord;
    procedure Execute; override;
  end;

  TStressCall = class(TServiceCall)
  public
    Pool: TWorkerPool;
    Handler: THandler;
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TStressService = class(THttpService)
  public
    C: TStressCall;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TObs = class(TConnObserver)
  public
    function OnAccept(Loop: TLoop; ConnId: QWord; const Peer: TSockAddrStorage): Pointer; override;
    procedure OnConnClose(ConnId: QWord; Data: Pointer; Outcome: TConnOutcome;
      const Detail: string); override;
  end;

  TApp = class
  public
    Srv: TServer;
    H: THandler;
    function NewService(Loop: TLoop): THttpService;
  end;

procedure THelperItem.Execute;
var
  I: Integer;
  S: RawByteString;
begin
  InterLockedIncrement(HelperRuns);
  try
    if Kind = 3 then
    begin
      { mode 12 (repro r1): one frame and the Release at once, so the
        Release often comes before the call's Offload }
      Ex.TryWrite(PByte(PAnsiChar('helper1')), 7);
      Ex.Release;
      Free;
      Exit;
    end;
    MicroSleep(Rnd(R, 1500));
    if Ex.IsCanceled then
      ;
    if Rnd(R, 2) = 0 then
      Ex.Wake;
    if Ex.Answered then
      ;
    if Kind = 2 then
      { a second producer of the stream (modes 7 / 11 only) }
      for I := 1 to 1 + Integer(Rnd(R, 4)) do
      begin
        S := 'helper' + IntToStr(I);
        if Ex.TryWrite(PByte(Pointer(S)), Length(S)) = wrCanceled then
          Break;
        MicroSleep(Rnd(R, 300));
      end;
    MicroSleep(Rnd(R, 800));
  except
    on E: EAssertionFailed do
    begin
      InterLockedIncrement(HandlerAsserts);
      Log('ASSERT in helper: ' + E.Message);
    end;
    on E: Exception do
      Log('helper raised ' + E.ClassName + ': ' + E.Message);
  end;
  if AtomicLoad(ServerFreed) <> 0 then
  begin
    InterLockedIncrement(LateHelperReleases);
    Log('helper: Release after the server was freed (test order)');
  end;
  Ex.Release;
  Free;
end;

function TStressCall.Poll(Ex: TExchange): TCallPoll;
var
  H: THelperItem;
  Kind, Sd: Int64;
begin
  if not Ex.Offloaded then
  begin
    InterLockedIncrement(Requests);
    Kind := HdrInt(Ex, 'x-helper');
    Sd := HdrInt(Ex, 'x-seed');
    if HdrInt(Ex, 'x-mode') = 12 then
    begin
      { the sixth S7 verifiers' repro r1: the call begins the stream and
        writes, shares it with a helper that writes, then offloads the
        worker; nobody calls Finish }
      Ex.BeginStream(64);
      Ex.WriteString('call;');
      H := THelperItem.Create;
      H.Ex := Ex.Share;
      H.Kind := 3;
      H.R := LongWord(Sd) * 2654435761 + 1;
      if not HelperPool.TrySubmit(H) then
      begin
        Ex.Release;
        H.Free;
      end;
      Ex.Offload(Pool, Handler);
      { answered (BeginStream on the loop): nothing would wake a Pending call }
      Exit(cpReady);
    end;
    { S7 fix round 5: the helper is shared before or after the offload
      (the call in flight holds the request, S7-32, so the order does not
      matter; before round 5 a helper's Release could drop the request
      while the call was still in flight, S7-27 (6)) }
    if Sd mod 2 = 1 then
      Ex.Offload(Pool, Handler);
    if Kind > 0 then
    begin
      H := THelperItem.Create;
      H.Ex := Ex.Share;
      H.Kind := Kind;
      H.R := LongWord(Sd) * 2654435761 + 1;
      if not HelperPool.TrySubmit(H) then
      begin
        Ex.Release;
        H.Free;
      end;
    end;
    if Sd mod 2 = 0 then
      Ex.Offload(Pool, Handler);
    Exit(cpPending);
  end;
  if Ex.Answered then
    Result := cpReady
  else
    Result := cpPending;
end;

destructor TStressService.Destroy;
begin
  C.Free;
  inherited Destroy;
end;

function TStressService.Call(Ex: TExchange): TServiceCall;
begin
  Result := C;
end;

function TApp.NewService(Loop: TLoop): THttpService;
var
  S: TStressService;
begin
  S := TStressService.Create;
  S.C := TStressCall.Create;
  S.C.Pool := Srv.Workers;
  S.C.Handler := H;
  Result := S;
end;

{ reads the body with the pattern check; returns True on a clean end }
function ReadChecked(Ex: TExchange; Len, Seed: Int64; var R: LongWord; SleepMax: Integer;
  UseRead: Boolean; Echo: Boolean; out Total: Int64): Boolean;
var
  C: TByteSlice;
  I: SizeInt;
  Buf: array[0..12] of Byte;
  N: SizeInt;
  S: RawByteString;
begin
  Total := 0;
  Result := False;
  while True do
  begin
    if UseRead then
    begin
      N := Ex.Read(@Buf[0], 1 + Rnd(R, SizeOf(Buf)));
      if N = 0 then
        Break;
      C.P := @Buf[0];
      C.Len := N;
    end
    else if not Ex.ReadChunk(C) then
      Break;
    for I := 0 to C.Len - 1 do
      if C.P[I] <> PatByte(Seed, Total + I) then
      begin
        Violation(Format('body byte %d is %d, expected %d (seed %d, len %d)',
          [Total + I, C.P[I], PatByte(Seed, Total + I), Seed, Len]));
        Break;
      end;
    if Echo then
    begin
      SetString(S, PAnsiChar(C.P), C.Len);
      if Rnd(R, 2) = 0 then
        Ex.WriteString(S)
      else
        Ex.Write(C.P, C.Len);
    end;
    Inc(Total, C.Len);
    if SleepMax > 0 then
      MicroSleep(Rnd(R, SleepMax));
  end;
  { a clean end }
  if Total <> Len then
    Violation(Format('clean end after %d of %d bytes (seed %d)', [Total, Len, Seed]));
  Result := True;
end;

procedure THandler.Run(Ex: TExchange);
var
  Mode, Len, Seed, Total: Int64;
  R: LongWord;
  C: TByteSlice;
  I, N: Integer;
  S: RawByteString;
  St: TBodyReadStatus;
begin
  Mode := HdrInt(Ex, 'x-mode');
  Len := HdrInt(Ex, 'x-len');
  Seed := HdrInt(Ex, 'x-seed');
  R := LongWord(Seed) or 1;
  try
    try
      MicroSleep(Rnd(R, 300));
      case Mode of
        0:
          begin
            if Rnd(R, 2) = 0 then
              Ex.ReleaseRequest;
            Ex.Status := 200;
            Ex.Respond(BodyString('hello'));
          end;
        1:
          begin
            ReadChecked(Ex, Len, Seed, R, 0, False, False, Total);
            Ex.ResponseHeaders.Add('x-got', IntToStr(Total));
            Ex.Respond(BodyString(IntToStr(Total)));
          end;
        2:
          begin
            Ex.Respond(BodyString('ok'));
            MicroSleep(Rnd(R, 500));
            ReadChecked(Ex, Len, Seed, R, 100, False, False, Total);
          end;
        3:
          begin
            Ex.BeginStream(16 + Rnd(R, 512));
            if ReadChecked(Ex, Len, Seed, R, 50, False, True, Total) then
              Ex.Finish(nil);
          end;
        4:
          begin
            if Ex.ReadChunk(C) then
              for I := 0 to C.Len - 1 do
                if C.P[I] <> PatByte(Seed, I) then
                begin
                  Violation('mode 4: wrong first chunk byte');
                  Break;
                end;
            case Rnd(R, 3) of
              0: Ex.ReleaseRequest;
              1: Ex.DiscardBody;
            end;
            MicroSleep(Rnd(R, 300));
            Ex.Respond(BodyString('partial'));
          end;
        5:
          Ex.Respond(BodyString('noread'));
        6:
          begin
            Ex.ReadChunk(C);
            raise EConvertError.Create('mode 6 raises');
          end;
        7, 12:
          begin
            { mode 12: the call began the stream }
            if Mode = 7 then
              Ex.BeginStream(64);
            N := 1 + Rnd(R, 20);
            for I := 1 to N do
            begin
              S := 'frame' + IntToStr(I) + ';';
              if Ex.WriteString(S) = wrCanceled then
                Break;
              MicroSleep(Rnd(R, 200));
            end;
            { no Finish: the last Release ends the stream }
          end;
        8:
          begin
            ReadChecked(Ex, Len, Seed, R, 30, True, False, Total);
            Ex.Respond(BodyString(IntToStr(Total)));
          end;
        9:
          Ex.Fail('mode 9 fails');
        10:
          begin
            { non-blocking polls from the worker }
            Total := 0;
            repeat
              St := Ex.TryRead(C);
              case St of
                brData:
                  begin
                    for I := 0 to C.Len - 1 do
                      if C.P[I] <> PatByte(Seed, Total + I) then
                      begin
                        Violation('mode 10: wrong byte');
                        Break;
                      end;
                    Inc(Total, C.Len);
                  end;
                brPending:
                  MicroSleep(20 + Rnd(R, 200));
              end;
            until (St = brEnd) or (St = brError) or (St = brCanceled);
            if (St = brEnd) and (Total <> Len) then
              Violation(Format('mode 10: brEnd after %d of %d', [Total, Len]));
            if St = brCanceled then
              InterLockedIncrement(Gone);
            Ex.Respond(BodyString(IntToStr(Total)));
          end;
        11:
          begin
            { a stream answered first, then the body read and dropped half way }
            Ex.BeginStream(32);
            Ex.WriteString('start;');
            if Ex.ReadChunk(C) then
              Ex.WriteString('chunk;');
            if Rnd(R, 2) = 0 then
              Ex.ReleaseRequest;
            Ex.WriteString('end;');
            if Rnd(R, 2) = 0 then
              Ex.Finish(nil);
          end;
      end;
      InterLockedIncrement(CleanOk);
    except
      on E: EAssertionFailed do
      begin
        if (Pos('written after the terminal call', E.Message) > 0) and Ex.IsCanceled then
          InterLockedIncrement(HeadAfterCancel)
        else
        begin
          InterLockedIncrement(HandlerAsserts);
          Log(Format('ASSERT in handler (mode %d, canceled %s): %s', [Mode, B2S(Ex.IsCanceled), E.Message]));
        end;
      end;
      on E: EClientGone do
        InterLockedIncrement(Gone);
      on E: EBodyError do
        InterLockedIncrement(BodyErrs);
    end;
  except
    on E: EAssertionFailed do
      raise;
    on E: Exception do
    begin
      InterLockedIncrement(Raised);
      if Mode <> 6 then
        Log(Format('handler mode %d len %d seed %d raised %s: %s', [Mode, Len, Seed, E.ClassName, E.Message]));
      raise;
    end;
  end;
end;

function TObs.OnAccept(Loop: TLoop; ConnId: QWord; const Peer: TSockAddrStorage): Pointer;
begin
  Result := Pointer(PtrUInt(ntohs(PInetSockAddr(@Peer)^.sin_port)));
end;

procedure TObs.OnConnClose(ConnId: QWord; Data: Pointer; Outcome: TConnOutcome;
  const Detail: string);
begin
  if GetEnvironmentVariable('LOG_CLOSE') <> '' then
    Log(Format('conn port %d closed: %d %s', [PtrUInt(Data), Ord(Outcome), Detail]));
end;

procedure OnLoopError(Loop: TLoop; Task: TLoopTask; E: Exception);
begin
  InterLockedIncrement(LoopErrors);
  Log('LOOP ERROR: ' + E.ClassName + ': ' + E.Message);
end;

{ ---- client side ---- }

function LocalPort(Fd: cint): Integer;
var
  A: TInetSockAddr;
  L: TSockLen;
begin
  L := SizeOf(A);
  fpGetSockName(Fd, @A, @L);
  Result := ntohs(A.sin_port);
end;

function Connect(P: Word): cint;
var
  A: TInetSockAddr;
  TV: TTimeVal;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(P);
  A.sin_addr.s_addr := htonl($7F000001);
  if fpConnect(Result, @A, SizeOf(A)) <> 0 then
  begin
    fpClose(Result);
    Exit(-1);
  end;
  TV.tv_sec := RcvTimeoutS;
  TV.tv_usec := 0;
  fpSetSockOpt(Result, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
end;

function SendAll(Fd: cint; P: PAnsiChar; Len: SizeInt): Boolean;
var
  Off, R: SizeInt;
begin
  Off := 0;
  while Off < Len do
  begin
    R := fpSend(Fd, P + Off, Len - Off, MSG_NOSIGNAL);
    if R <= 0 then
      Exit(False);
    Inc(Off, R);
  end;
  Result := True;
end;

function SendStr(Fd: cint; const S: RawByteString): Boolean;
begin
  Result := (Length(S) = 0) or SendAll(Fd, PAnsiChar(S), Length(S));
end;

type
  TRecvBuf = record
    Fd: cint;
    Data: RawByteString;
    Pos: SizeInt;        { 1-based read position }
    Eof, TimedOut: Boolean;
    Err: Integer;
  end;

function Fill(var B: TRecvBuf): Boolean;
var
  Buf: array[0..16383] of AnsiChar;
  R: ssize_t;
  S: RawByteString;
begin
  if B.Eof then
    Exit(False);
  R := fpRecv(B.Fd, @Buf[0], SizeOf(Buf), 0);
  if R <= 0 then
  begin
    B.Eof := True;
    if R < 0 then
      B.Err := fpgeterrno;
    if (R < 0) and ((fpgeterrno = ESysEAGAIN) or (fpgeterrno = ESysEWOULDBLOCK)) then
      B.TimedOut := True;
    Exit(False);
  end;
  SetString(S, PAnsiChar(@Buf[0]), R);
  if B.Pos > 1 then
  begin
    Delete(B.Data, 1, B.Pos - 1);
    B.Pos := 1;
  end;
  B.Data := B.Data + S;
  Result := True;
end;

function ReadLine(var B: TRecvBuf; out L: RawByteString): Boolean;
var
  P: SizeInt;
begin
  repeat
    P := Pos(CRLF, B.Data, B.Pos);
    if P > 0 then
    begin
      L := Copy(B.Data, B.Pos, P - B.Pos);
      B.Pos := P + 2;
      Exit(True);
    end;
  until not Fill(B);
  Result := False;
end;

function ReadN(var B: TRecvBuf; N: SizeInt; out S: RawByteString): Boolean;
begin
  while Length(B.Data) - B.Pos + 1 < N do
    if not Fill(B) then
      Exit(False);
  S := Copy(B.Data, B.Pos, N);
  Inc(B.Pos, N);
  Result := True;
end;

{ one response; False on EOF / timeout before its end }
function ReadResponse(var B: TRecvBuf; out Status: Integer; out Body: RawByteString): Boolean;
var
  L, Name, Val, S: RawByteString;
  CL: Int64;
  Chunked: Boolean;
  P: SizeInt;
  N: Int64;
begin
  Body := '';
  Status := 0;
  if not ReadLine(B, L) then
    Exit(False);
  Status := StrToIntDef(Copy(L, 10, 3), 0);
  CL := -1;
  Chunked := False;
  while True do
  begin
    if not ReadLine(B, L) then
      Exit(False);
    if L = '' then
      Break;
    P := Pos(':', L);
    Name := LowerCase(Copy(L, 1, P - 1));
    Val := Trim(Copy(L, P + 1, MaxInt));
    if Name = 'content-length' then
      CL := StrToInt64Def(Val, -1)
    else if (Name = 'transfer-encoding') and (LowerCase(Val) = 'chunked') then
      Chunked := True;
  end;
  if Chunked then
  begin
    while True do
    begin
      if not ReadLine(B, L) then
        Exit(False);
      N := StrToInt64Def('$' + Trim(L), -1);
      if N < 0 then
        Exit(False);
      if N = 0 then
      begin
        repeat
          if not ReadLine(B, L) then
            Exit(False);
        until L = '';
        Break;
      end;
      if not ReadN(B, N, S) then
        Exit(False);
      Body := Body + S;
      if not ReadLine(B, L) then
        Exit(False);
    end;
  end
  else if CL > 0 then
  begin
    if not ReadN(B, CL, Body) then
      Exit(False);
  end;
  Result := True;
end;

function Pattern(Seed: LongWord; Len: Integer): RawByteString;
var
  I: Integer;
begin
  SetLength(Result, Len);
  for I := 0 to Len - 1 do
    Result[I + 1] := AnsiChar(PatByte(Seed, I));
end;

procedure SetRst(Fd: cint);
var
  Lg: linger;
begin
  Lg.l_onoff := 1;
  Lg.l_linger := 0;
  fpSetSockOpt(Fd, SOL_SOCKET, SO_LINGER, @Lg, SizeOf(Lg));
end;

{ modes 7 and 12: the worker wrote frame1; .. frameN; (N from the seed, as
  THandler.Run draws it) and returned without Finish; the stream ended only
  when its last producer was gone, so a complete response holds them all, in
  order (the call's "call;" first in mode 12); helper frames may be anywhere }
procedure CheckWorkerFrames(Mode: Integer; Seed: LongWord; const Got: RawByteString);
var
  R: LongWord;
  N, I: Integer;
  P, Q: SizeInt;
begin
  InterLockedIncrement(StreamsChecked);
  R := Seed or 1;
  Rnd(R, 300);                       { THandler.Run's first draw (its sleep) }
  N := 1 + Rnd(R, 20);
  P := 1;
  if Mode = 12 then
  begin
    if Copy(Got, 1, 5) <> 'call;' then
      Violation('mode 12: the call''s frame is not first: ' + Copy(Got, 1, 40));
    P := 6;
  end;
  for I := 1 to N do
  begin
    Q := Pos('frame' + IntToStr(I) + ';', Got, P);
    if Q = 0 then
    begin
      Violation(Format('mode %d seed %d: a complete stream without the worker''s frame %d of %d: %s',
        [Mode, Seed, I, N, Copy(Got, 1, 200)]));
      Exit;
    end;
    P := Q + 1;
  end;
end;

function ClientMain(Arg: Pointer): PtrInt;
var
  R: LongWord;
  C, K, NReq, Mode, Len, Disc, Helper, ChunkSz, Off, Status, Cut, I: Integer;
  Seed: LongWord;
  Fd: cint;
  B: TRecvBuf;
  Body, Head, Got, Piece: RawByteString;
  Chunked, Closes, Ok, Expect: Boolean;
  PrevDesc: string;
  TReq: Int64;
begin
  R := LongWord(PtrUInt(Arg)) * 7919 + Seed0;
  if R = 0 then
    R := 1;
  for C := 1 to NConns do
  begin
    if StopEarly and (AtomicLoad(ClientsDone) < 0) then
      Break;
    Fd := Connect(Port);
    if Fd < 0 then
    begin
      if not StopEarly then
        InterLockedIncrement(ClientErrors);
      Break;
    end;
    B := Default(TRecvBuf);
    B.Fd := Fd;
    B.Pos := 1;
    NReq := 1 + Rnd(R, 4);
    PrevDesc := '';
    Closes := False;
    for K := 1 to NReq do
    begin
      Mode := Rnd(R, NMODES);
      if OnlyMode >= 0 then
        Mode := OnlyMode;
      case Rnd(R, 4) of
        0: Len := 0;
        1: Len := 1 + Rnd(R, 64);
        2: Len := 1 + Rnd(R, 4096);
      else
        Len := 1 + Rnd(R, 40000);
      end;
      Seed := Rnd(R, 1000000) + 1;
      Chunked := (Len > 0) and (Rnd(R, 3) = 0);
      Helper := 0;
      if Rnd(R, 4) = 0 then
      begin
        Helper := 1;
        if (Mode = 7) or (Mode = 11) then
          Helper := 2;
      end;
      { 0 none; 1 after head; 2 mid body; 3 after part of the response; 4 RST mid body }
      Disc := 0;
      if Rnd(R, 5) = 0 then
        Disc := 1 + Rnd(R, 4);
      Body := Pattern(Seed, Len);
      Head := 'POST /s HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'x-mode: ' + IntToStr(Mode) + CRLF
        + 'x-len: ' + IntToStr(Len) + CRLF + 'x-seed: ' + IntToStr(Seed) + CRLF
        + 'x-helper: ' + IntToStr(Helper) + CRLF;
      if Chunked then
        Head := Head + 'Transfer-Encoding: chunked' + CRLF
      else
        Head := Head + 'Content-Length: ' + IntToStr(Len) + CRLF;
      Expect := (Len > 0) and (Rnd(R, 6) = 0);
      if Expect then
        Head := Head + 'Expect: 100-continue' + CRLF;
      Head := Head + CRLF;
      TReq := MonoNowNs;
      if not SendStr(Fd, Head) then
      begin
        Closes := True;
        Break;
      end;
      if Disc = 1 then
      begin
        MicroSleep(Rnd(R, 3000));
        if Rnd(R, 2) = 0 then
          SetRst(Fd);
        Closes := True;
        Break;
      end;
      { the body, in pieces }
      Off := 0;
      Cut := -1;
      if (Disc = 2) or (Disc = 4) then
        Cut := Rnd(R, Len + 1);
      Ok := True;
      while Off < Len do
      begin
        ChunkSz := 1 + Rnd(R, 9000);
        if ChunkSz > Len - Off then
          ChunkSz := Len - Off;
        if (Cut >= 0) and (Off + ChunkSz > Cut) then
          ChunkSz := Cut - Off;
        if ChunkSz > 0 then
        begin
          Piece := Copy(Body, Off + 1, ChunkSz);
          if Chunked then
            Piece := IntToHex(ChunkSz, 1) + CRLF + Piece + CRLF;
          if not SendStr(Fd, Piece) then
          begin
            Ok := False;
            Break;
          end;
          Inc(Off, ChunkSz);
        end;
        if (Cut >= 0) and (Off >= Cut) then
          Break;
        if Rnd(R, 4) = 0 then
          MicroSleep(Rnd(R, 1500));
      end;
      if not Ok then
      begin
        Closes := True;
        Break;
      end;
      if Cut >= 0 then
      begin
        MicroSleep(Rnd(R, 3000));
        if Disc = 4 then
          SetRst(Fd);
        Closes := True;
        Break;
      end;
      if Chunked and not SendStr(Fd, '0' + CRLF + CRLF) then
      begin
        Closes := True;
        Break;
      end;
      if Disc = 3 then
      begin
        Fill(B);
        if Rnd(R, 2) = 0 then
          SetRst(Fd);
        Closes := True;
        Break;
      end;
      { the response }
      repeat
        Ok := ReadResponse(B, Status, Got);
      until (not Ok) or (Status <> 100);
      NoteRequestMs((MonoNowNs - TReq) div 1000000);
      if (Mode = 6) or (Mode = 9) then
      begin
        { a failed handler: no response, the connection closes }
        if Ok then
          Violation(Format('mode %d answered %d', [Mode, Status]));
        if B.TimedOut then
        begin
          InterLockedIncrement(Hangs);
          Log(Format('HANG: mode %d (no close) len %d seed %d', [Mode, Len, Seed]));
        end;
        Closes := True;
        Break;
      end;
      if not Ok then
      begin
        if B.TimedOut then
        begin
          InterLockedIncrement(Hangs);
          Log(Format('HANG: mode %d len %d chunked %s helper %d seed %d', [Mode, Len, B2S(Chunked), Helper, Seed]));
        end
        else if (B.Err = ESysECONNRESET) and (Len > 0) and (Mode in [0, 4, 5, 7, 11, 12]) then
          { the server closed with the request body unread (drain or close):
            the kernel's reset may discard the end of the response }
          InterLockedIncrement(ResetUnread)
        else if not StopEarly then
        begin
          InterLockedIncrement(ClientErrors);
          Log(Format('client: connection ended in mode %d len %d helper %d seed %d k %d prev %s port %d errno %d data %d', [Mode, Len, Helper, Seed, K, PrevDesc, LocalPort(Fd), B.Err, Length(B.Data) - B.Pos + 1]));
        end;
        Closes := True;
        Break;
      end;
      if (Len > 0) and (Mode in [0, 4, 5, 7, 11, 12]) then
        { the body may be left unread: hyper drains or closes }
        Closes := True;
      case Mode of
        1, 8, 10:
          if Got <> IntToStr(Len) then
            Violation(Format('mode %d: response %s, sent %d', [Mode, Got, Len]));
        3:
          if Got <> Body then
            Violation(Format('mode 3: echo of %d bytes differs (got %d)', [Len, Length(Got)]));
        7, 12:
          CheckWorkerFrames(Mode, Seed, Got);
      end;
      PrevDesc := Format('mode %d len %d chunked %s expect %s helper %d', [Mode, Len, B2S(Chunked), B2S(Expect), Helper]);
      if Closes then
        Break;
    end;
    if Closes and (Rnd(R, 3) = 0) then
      SetRst(Fd);
    fpClose(Fd);
  end;
  InterLockedIncrement(ClientsDone);
  Result := 0;
end;

var
  App: TApp;
  Cfg: TServerConfig;
  Srv: TServer;
  Threads: array of TThreadID;
  I: Integer;
  Live0: LongInt;
  T0: Int64;
  StopMs: Integer;
  Obs: TObs;

begin
  InitCriticalSection(LogLock);
  NClients := StrToIntDef(GetEnvironmentVariable('CLIENTS'), 24);
  NConns := StrToIntDef(GetEnvironmentVariable('CONNS'), 40);
  Seed0 := StrToIntDef(GetEnvironmentVariable('SEED'), 12345);
  RcvTimeoutS := StrToIntDef(GetEnvironmentVariable('RCV_TIMEOUT_S'), 20);
  StopMs := StrToIntDef(GetEnvironmentVariable('STOP_EARLY_MS'), 0);
  OnlyMode := StrToIntDef(GetEnvironmentVariable('ONLY_MODE'), -1);
  StopEarly := StopMs > 0;
  LoopErrorProc := @OnLoopError;
  Live0 := AtomicLoad(ExchangesLive);
  HelperPool := TWorkerPool.Create(4);
  Cfg := BenchmarkServerConfig;
  Cfg.Listen.Host := '127.0.0.1';
  Cfg.Listen.Port := 0;
  Cfg.Loops := StrToIntDef(GetEnvironmentVariable('LOOPS'), 2);
  Cfg.Workers := StrToIntDef(GetEnvironmentVariable('WORKERS'), 16);
  Cfg.WorkerWaitMs := 20000;
  Cfg.H1.AutoDateHeader := False;
  if GetEnvironmentVariable('NO_PIPELINE_FLUSH') <> '' then
    Cfg.H1.PipelineFlush := False;
  App := TApp.Create;
  App.H := THandler.Create;
  Obs := TObs.Create;
  Srv := TServer.Create(Cfg, @App.NewService, Obs);
  App.Srv := Srv;
  Srv.Start;
  Port := Srv.Port;
  SetLength(Threads, NClients);
  for I := 0 to NClients - 1 do
    Threads[I] := BeginThread(@ClientMain, Pointer(PtrUInt(I + 1)));
  T0 := MonoNowNs;
  if StopEarly then
  begin
    Sleep(StopMs);
    WriteLn('destroying the server while traffic runs');
    Srv.Stop(0);
    Srv.Wait;
    { the helpers' references go before the loops do }
    HelperPool.Shutdown(10000);
    Srv.Free;
    InterLockedExchange(ServerFreed, 1);
    Srv := nil;
  end;
  for I := 0 to NClients - 1 do
    WaitForThreadTerminate(Threads[I], 0);
  if Srv <> nil then
  begin
    Srv.Stop(2000);
    Srv.Wait;
    { the helpers' references go before the loops do }
    HelperPool.Shutdown(10000);
    Srv.Free;
  end;
  InterLockedExchange(ServerFreed, 1);
  HelperPool.Shutdown(10000);
  HelperPool.Free;
  Obs.Free;
  DoneCriticalSection(LogLock);
  App.H.Free;
  App.Free;
  WriteLn(Format('requests=%d handlers_ok=%d gone=%d body_errors=%d raised=%d helpers=%d time=%.1fs',
    [Requests, CleanOk, Gone, BodyErrs, Raised, HelperRuns, (MonoNowNs - T0) / 1e9]));
  WriteLn(Format('head_write_after_cancel_asserts=%d late_helper_releases=%d max_request_ms=%d',
    [HeadAfterCancel, LateHelperReleases, MaxRequestMs]));
  WriteLn(Format('streams_checked=%d reset_with_unread_body=%d', [StreamsChecked, ResetUnread]));
  WriteLn(Format('violations=%d handler_asserts=%d loop_errors=%d hangs=%d client_errors=%d exchanges_live=%d (start %d)',
    [Violations, HandlerAsserts, LoopErrors, Hangs, ClientErrors, AtomicLoad(ExchangesLive), Live0]));
  if (Violations = 0) and (HandlerAsserts = 0) and (LoopErrors = 0) and (Hangs = 0)
    and (ClientErrors = 0) and (AtomicLoad(ExchangesLive) = Live0) then
  begin
    WriteLn('STRESS PASSED');
    Halt(0);
  end;
  WriteLn('STRESS FAILED');
  Halt(1);
end.
