{ beconf.upgrade - SPEC 6.3 upgrade tasks and the signal latches (docs/design.md
  section 9). Test tooling.

  The reference server's run_upgrade, on the loop that served the
  connection (tokio::spawn on the current-thread runtime): emit `upgraded`
  with the hand-over bytes; wait for the latch named by await_signal; write;
  read to EOF and emit `upgrade_read`; close. Errors emit `upgrade_error`.
  The hand-over bytes are reported, not read again (the reference task reads
  the bare TcpStream, not the Rewind).

  TConfUpgrader is a TRawListener attached to the TUpgraded (bearings.rt.stream):
  its callbacks run on every socket event and on every Wake; each step tries
  its operation and stops at -EAGAIN.

  TConfUpgradeHandler is what the handler registers with Ex.OnUpgrade
  (hyper upgrade::on). In the reference server the task that awaits the
  OnUpgrade is spawned only when the handler reaches step 8 of SPEC 5.5;
  before that, a dropped OnUpgrade gives no event. Armed models that spawn.
  An armed handler that gets a failure (plain mode: "upgrade expected but
  low level API in use"; a dropped connection: "upgrade expected but not
  completed") emits `upgrade_error` from a queued task, because the
  reference's spawned task runs after serve_conn emitted `conn_close`.

  Latches (SPEC 3.4 signal): a set of names, never reset, and the upgraders
  waiting for a name, under a lock (--loops N, S8: the control task runs on
  loop 0, an upgrader on the loop of its connection). SetLatch takes the
  waiters of the name out of the list and posts an lmCall to each one's
  loop; the upgrader goes on only when that message arrives (FSignaled),
  so it is never touched by another thread. }
unit beconf.upgrade;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, ctypes, bearings.rt.sys, bearings.rt.loop, bearings.rt.stream, bearings.http.exchange,
  beconf.spec, beconf.events;

type
  TUpStep = (upSignal, upWrite, upRead, upDone);

  TConfUpgrader = class(TRawListener)
  private
    FU: TUpgraded;
    FStep: TUpStep;
    FSignaled: Boolean;              { the latch message arrived (or the latch was set at Start) }
    FSignalMsg: TLoopMsg;
    FWPos: SizeInt;
    FData: RawByteString;
    procedure Step;
    procedure Finish;
  public
    Conn: QWord;
    Spec: TUpgradeSpec;
    procedure Readable(U: TUpgraded); override;
    procedure Writable(U: TUpgraded); override;
    { emits upgraded, then runs the task on U }
    procedure Start(U: TUpgraded);
    procedure SignalSet;             { the latch it waits for was set }
  end;

  TConfUpgradeHandler = class(TUpgradeHandler)
  public
    Conn: QWord;
    Spec: TUpgradeSpec;
    Loop: TLoop;
    Armed: Boolean;                  { the reference spawned its task (SPEC 5.5 step 8) }
    procedure Upgraded(U: TUpgraded); override;
    procedure UpgradeFailed(const Msg: string); override;
  end;

  { one event line emitted from the run queue (after the current task) }
  TEmitTask = class(TLoopTask)
  public
    Line: RawByteString;
    procedure Run; override;
    procedure Abort; override;
  end;

{ SPEC 3.4 signal: sets the latch and wakes its waiters. }
procedure SetLatch(const Name: RawByteString);
function LatchIsSet(const Name: RawByteString): Boolean;
{ Starts the upgrade task of Spec on U (with_upgrades delivery, without_shutdown parts). }
procedure StartUpgrade(Conn: QWord; Spec: TUpgradeSpec; U: TUpgraded);
{ Queues Line on Loop's run queue. }
procedure EmitLater(Loop: TLoop; const Line: RawByteString);

implementation

var
  Latches: TStringList;
  Waiters: TList;                    { TConfUpgrader in upSignal }
  LatchLock: TRTLCriticalSection;

function LatchIsSet(const Name: RawByteString): Boolean;
begin
  EnterCriticalSection(LatchLock);
  try
    Result := Latches.IndexOf(Name) >= 0;
  finally
    LeaveCriticalSection(LatchLock);
  end;
end;

procedure SignalProc(Loop: TLoop; Arg: Pointer);
begin
  TConfUpgrader(Arg).SignalSet;
end;

procedure SetLatch(const Name: RawByteString);
var
  I: Integer;
  W: TConfUpgrader;
begin
  EnterCriticalSection(LatchLock);
  try
    if Latches.IndexOf(Name) < 0 then
      Latches.Add(Name);
    I := 0;
    while I < Waiters.Count do
    begin
      W := TConfUpgrader(Waiters[I]);
      if W.Spec.AwaitSignal = Name then
      begin
        Waiters.Delete(I);
        { on the upgrader's own loop (the run of this message comes after
          the current task, as the Wake did with one loop) }
        W.FSignalMsg.Kind := lmCall;
        W.FSignalMsg.Proc := @SignalProc;
        W.FSignalMsg.Arg := W;
        W.FU.Loop.Post(@W.FSignalMsg);
      end
      else
        Inc(I);
    end;
  finally
    LeaveCriticalSection(LatchLock);
  end;
end;

procedure TEmitTask.Run;
begin
  EmitLine(Line);
  Close;
end;

procedure TEmitTask.Abort;
begin
end;

procedure EmitLater(Loop: TLoop; const Line: RawByteString);
var
  T: TEmitTask;
begin
  T := TEmitTask.Create;
  T.Loop := Loop;
  T.Line := Line;
  T.Wake;
end;

function OsErrorText(Errno: cint): string;
begin
  { std::io::Error Display: "<strerror> (os error N)" }
  Result := SysErrorMessage(Errno) + ' (os error ' + IntToStr(Errno) + ')';
end;

{ ---- TConfUpgrader ---- }

procedure TConfUpgrader.Start(U: TUpgraded);
var
  P: PByte;
  L: SizeInt;
begin
  FU := U;
  U.Leftover(P, L);
  EmitLine('{"event":"upgraded","conn":' + JUInt(Conn) + ',"read_buf":' + JBytesP(P, L) + '}');
  U.ConsumeLeftover(L);
  FStep := upWrite;
  if Spec.HasAwait then
  begin
    EnterCriticalSection(LatchLock);
    try
      if Latches.IndexOf(Spec.AwaitSignal) < 0 then
      begin
        FStep := upSignal;
        Waiters.Add(Self);
      end;
    finally
      LeaveCriticalSection(LatchLock);
    end;
  end;
  U.Attach(Self);                    { runs Step once from the run queue }
end;

procedure TConfUpgrader.SignalSet;
begin
  FSignaled := True;
  if (FStep = upSignal) and (FU <> nil) then
    FU.Wake;
end;

procedure TConfUpgrader.Readable(U: TUpgraded);
begin
  Step;
end;

procedure TConfUpgrader.Writable(U: TUpgraded);
begin
  Step;
end;

procedure TConfUpgrader.Finish;
var
  U: TUpgraded;
begin
  { close the socket; this object goes (the stream is freed by the loop) }
  U := FU;
  FU := nil;
  EnterCriticalSection(LatchLock);
  try
    Waiters.Remove(Self);
  finally
    LeaveCriticalSection(LatchLock);
  end;
  U.Close;
  Free;
end;

procedure TConfUpgrader.Step;
var
  R: SizeInt;
  Buf: array[0..16383] of Byte;
  S: RawByteString;
begin
  while True do
    case FStep of
      upSignal:
        begin
          if not FSignaled then
            Exit;
          FStep := upWrite;
        end;
      upWrite:
        begin
          if (not Spec.HasWrite) or (FWPos >= Length(Spec.Write)) then
          begin
            if Spec.ReadToEof then
              FStep := upRead
            else
              FStep := upDone;
            Continue;
          end;
          R := FU.TryWrite(@Spec.Write[FWPos + 1], Length(Spec.Write) - FWPos);
          if R = -ESysEAGAIN then
            Exit;
          if R < 0 then
          begin
            EmitLine('{"event":"upgrade_error","conn":' + JUInt(Conn) + ',"message":'
              + JText(OsErrorText(-R)) + '}');
            Finish;
            Exit;
          end;
          Inc(FWPos, R);
        end;
      upRead:
        begin
          R := FU.TryRead(@Buf[0], SizeOf(Buf));
          if R = -ESysEAGAIN then
            Exit;
          if R > 0 then
          begin
            SetString(S, PAnsiChar(@Buf[0]), R);
            FData := FData + S;
            Continue;
          end;
          if R = 0 then
            EmitLine('{"event":"upgrade_read","conn":' + JUInt(Conn) + ',"data":' + JBytes(FData)
              + ',"end":"eof"}')
          else
            EmitLine('{"event":"upgrade_read","conn":' + JUInt(Conn) + ',"data":' + JBytes(FData)
              + ',"end":"error","message":' + JText(OsErrorText(-R)) + '}');
          Finish;
          Exit;
        end;
    else
      begin
        Finish;
        Exit;
      end;
    end;
end;

procedure StartUpgrade(Conn: QWord; Spec: TUpgradeSpec; U: TUpgraded);
var
  W: TConfUpgrader;
begin
  W := TConfUpgrader.Create;
  W.Conn := Conn;
  W.Spec := Spec;
  W.Start(U);
end;

{ ---- TConfUpgradeHandler ---- }

procedure TConfUpgradeHandler.Upgraded(U: TUpgraded);
begin
  { the slot calls its handler once (bearings.http.exchange: a oneshot) }
  if Armed then
    StartUpgrade(Conn, Spec, U)
  else
    U.Close;                         { the OnUpgrade was dropped: the Upgraded is dropped }
  Free;
end;

procedure TConfUpgradeHandler.UpgradeFailed(const Msg: string);
begin
  if Armed then
    EmitLater(Loop, '{"event":"upgrade_error","conn":' + JUInt(Conn) + ',"message":'
      + JText(Msg) + '}');
  Free;
end;

initialization
  Latches := TStringList.Create;
  Latches.CaseSensitive := True;
  Waiters := TList.Create;
  InitCriticalSection(LatchLock);
finalization
  Latches.Free;
  Waiters.Free;
  DoneCriticalSection(LatchLock);
end.
