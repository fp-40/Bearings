{ beconf.control - SPEC 3.4 stdin control commands (design m3-transport.md
  6.1). Test tooling.

  TControl (a TIoTask) owns fd 0 (non-blocking), registered level-triggered in loop
  0's epoll. Each Run reads until EAGAIN, splits lines and handles each one
  as the reference server's control_loop does (the line is trimmed, split
  at the first space, the argument trimmed):
    graceful_shutdown     GracefulShutdown on every connection open now, then
                          control_ack (the ack follows the effect, SPEC 3.4;
                          --loops N: loop 0 applies it here, every other
                          loop in an lmCall message, and the last loop to
                          finish emits the ack);
    signal <name>         set the latch, wake its waiters, control_ack;
    exit                  exit(0) at once;
    empty line            ignored;
    anything else         control_error with the line.
  End of stdin (or a read error) exits with status 0. The commands run in
  this task, never inside a connection's Run, so a connection's read, its
  bytes_read event and the buffering of the bytes happen before a command
  that the runner sends after seeing that event (SPEC 7).

  When epoll refuses fd 0 (a regular file or /dev/null: EPERM), a reader
  thread does blocking reads and posts each chunk to loop 0 (lmCall); the
  loop handles it like the task's own reads. }
unit beconf.control;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ctypes, bearings.rt.sys, bearings.rt.loop, bearings.http1.dispatch, bearings.server, beconf.events,
  beconf.upgrade;

{ Creates the control task on Server's loop 0 (before the loop runs). }
procedure StartControl(Server: TServer);

implementation

uses
  BaseUnix;

type
  TControl = class(TIoTask)
  private
    FPartial: RawByteString;
    procedure HandleLine(const Raw: RawByteString);
  public
    Server: TServer;
    procedure Feed(P: PByte; Len: SizeInt);
    procedure Eof;
    procedure Run; override;         { fd 0 readable: read until EAGAIN }
    procedure Abort; override;
  end;

  PChunkMsg = ^TChunkMsg;
  TChunkMsg = record
    Msg: TLoopMsg;                   { first field: the inbox link }
    Len: SizeInt;                    { 0: end of stdin }
    Data: array[0..4095] of Byte;
  end;

  { one graceful_shutdown command across the loops }
  PGsCmd = ^TGsCmd;
  TGsCmd = record
    Left: LongInt;                   { loops still to apply it }
    Msgs: array of TLoopMsg;         { one per loop (index 0 unused) }
  end;

var
  Ctl: TControl;

procedure ShutdownLoopConns(SL: TServerLoop);
var
  D: TH1Dispatcher;
begin
  D := SL.Conns.Head;
  while D <> nil do
  begin
    D.GracefulShutdown;
    D := D.NextConn;
  end;
end;

procedure GsLoopDone(C: PGsCmd);
begin
  if InterLockedDecrement(C^.Left) = 0 then
  begin
    EmitLine('{"event":"control_ack","command":"graceful_shutdown"}');
    Dispose(C);
  end;
end;

procedure GsLoopProc(Loop: TLoop; Arg: Pointer);
begin
  ShutdownLoopConns(Ctl.Server.Loops[Loop.Index]);
  GsLoopDone(PGsCmd(Arg));
end;

procedure ExitNow;
begin
  { std::process::exit(0). Event lines are written with write(2); stderr
    (StdErr is a buffered Text) is flushed, exit_group would drop it }
  try
    Flush(StdErr);
  except
  end;
  FpExit(0);
end;

function TrimAscii(const S: RawByteString): RawByteString;
var
  A, B: Integer;
begin
  A := 1;
  B := Length(S);
  while (A <= B) and (S[A] in [' ', #9, #10, #11, #12, #13]) do
    Inc(A);
  while (B >= A) and (S[B] in [' ', #9, #10, #11, #12, #13]) do
    Dec(B);
  Result := Copy(S, A, B - A + 1);
end;

procedure TControl.HandleLine(const Raw: RawByteString);
var
  Line, Cmd, Arg: RawByteString;
  Sp: Integer;
  HasArg: Boolean;
  C: PGsCmd;
  I: Integer;
begin
  Line := TrimAscii(Raw);
  Sp := Pos(' ', Line);
  if Sp > 0 then
  begin
    Cmd := Copy(Line, 1, Sp - 1);
    Arg := TrimAscii(Copy(Line, Sp + 1, MaxInt));
    HasArg := True;
  end
  else
  begin
    Cmd := Line;
    Arg := '';
    HasArg := False;
  end;
  if Cmd = '' then
    Exit;
  if (Cmd = 'graceful_shutdown') and not HasArg then
  begin
    { every connection open now: loop 0 here, the others in their own
      thread (an lmCall per loop); the last one acks }
    New(C);
    C^.Left := Server.LoopCount;
    SetLength(C^.Msgs, Server.LoopCount);
    for I := 1 to Server.LoopCount - 1 do
    begin
      C^.Msgs[I].Kind := lmCall;
      C^.Msgs[I].Proc := @GsLoopProc;
      C^.Msgs[I].Arg := C;
      Server.Loops[I].Loop.Post(@C^.Msgs[I]);
    end;
    ShutdownLoopConns(Server.Loops[0]);
    GsLoopDone(C);
  end
  else if (Cmd = 'signal') and HasArg and (Arg <> '') then
  begin
    SetLatch(Arg);
    EmitLine('{"event":"control_ack","command":"signal","name":' + JText(Arg) + '}');
  end
  else if (Cmd = 'exit') and not HasArg then
    ExitNow
  else
    EmitLine('{"event":"control_error","line":' + JText(Line) + '}');
end;

procedure TControl.Feed(P: PByte; Len: SizeInt);
var
  S: RawByteString;
  NL: Integer;
begin
  SetString(S, PAnsiChar(P), Len);
  FPartial := FPartial + S;
  repeat
    NL := Pos(#10, FPartial);
    if NL = 0 then
      Break;
    S := Copy(FPartial, 1, NL - 1);
    Delete(FPartial, 1, NL);
    HandleLine(S);
  until False;
end;

procedure TControl.Eof;
begin
  { stdin closed (or broken): the runner is gone. A last line without a
    newline is handled first, as BufRead::lines does. }
  if FPartial <> '' then
  begin
    HandleLine(FPartial);
    FPartial := '';
  end;
  ExitNow;
end;

procedure TControl.Run;
var
  Buf: array[0..4095] of Byte;
  R: SizeInt;
begin
  while True do
  begin
    R := SysRead(Src.Fd, @Buf[0], SizeOf(Buf));
    if R = -ESysEINTR then
      Continue;
    if R = -ESysEAGAIN then
      Exit;
    if R <= 0 then
      Eof;
    Feed(@Buf[0], R);
  end;
end;

procedure TControl.Abort;
begin
  { an exception in a command: the control channel is gone }
  ExitNow;
end;

{ ---- fallback: stdin that epoll refuses ---- }

procedure ChunkProc(Loop: TLoop; Arg: Pointer);
var
  M: PChunkMsg;
  Len: SizeInt;
begin
  M := PChunkMsg(Arg);
  Len := M^.Len;
  try
    if Len > 0 then
      Ctl.Feed(@M^.Data[0], Len);
  finally
    Dispose(M);
  end;
  if Len <= 0 then
    Ctl.Eof;
end;

function ReaderThread(Arg: Pointer): PtrInt;
var
  M: PChunkMsg;
  L: TLoop;
  R: TSsize;
begin
  L := TLoop(Arg);
  repeat
    New(M);
    repeat
      R := FpRead(0, @M^.Data[0], SizeOf(M^.Data));
    until (R >= 0) or (fpgeterrno <> ESysEINTR);
    if R < 0 then
      R := 0;
    M^.Len := R;
    M^.Msg.Kind := lmCall;
    M^.Msg.Proc := @ChunkProc;
    M^.Msg.Arg := M;
    L.Post(@M^.Msg);
  until R = 0;
  Result := 0;
end;

procedure StartControl(Server: TServer);
var
  L: TLoop;
  Fl: cint;
begin
  L := Server.Loops[0].Loop;
  Ctl := TControl.Create(L, 0);
  Ctl.Server := Server;
  Fl := FpFcntl(0, F_GETFL);
  if (Fl >= 0) and L.Register(@Ctl.Src, EPOLLIN) then
  begin
    FpFcntl(0, F_SETFL, Fl or O_NONBLOCK);
    Exit;
  end;
  { fd 0 stays blocking and is read by the thread; no event runs the task }
  Ctl.Src.Fd := -1;
  BeginThread(@ReaderThread, Pointer(L));
end;

end.
