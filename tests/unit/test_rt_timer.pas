{ M3 step S1 tests for bearings.rt.timer (docs/design.md section 4):
  - tokio's tick rounding (TimeSource::deadline_to_tick / instant_to_tick)
    and the wheel's level_for / slot_for tables (tokio's own unit tests,
    ported);
  - arm / lazy re-arm / lazy cancel / remove / fire-in-proc semantics;
  - a randomized comparison against a sorted-list reference: random arm,
    re-arm, cancel, remove and advance (small steps and large jumps over
    every level); the set fired by each Advance equals the reference's;
    NextTimeoutMs never sleeps past the earliest wanted deadline; a loop
    that sleeps exactly NextTimeoutMs fires every timer at its exact tick.
  Run: test_rt_timer --all --format=plain }
program test_rt_timer;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, fpcunit, testregistry, consoletestrunner,
  bearings.rt.timer;

type
  TTestTimer = class(TTestCase)
  published
    procedure Tick_rounding_matches_tokio;
    procedure Level_for_matches_tokio_tests;
    procedure Slot_for_matches_tokio_tests;
    procedure Fires_at_deadline_not_before;
    procedure Lazy_rearm_later_keeps_filing;
    procedure Rearm_earlier_refiles;
    procedure Lazy_cancel_drops_entry_at_expiry;
    procedure Remove_unlinks_now;
    procedure Arm_in_the_past_fires_on_next_advance;
    procedure Proc_may_rearm_itself_and_others;
    procedure Proc_arming_due_timer_fires_in_same_advance;
    procedure Cancel_while_pending_does_not_fire;
    procedure Next_timeout_values;
    procedure Far_deadlines_cascade_down_levels;
    procedure Random_vs_sorted_reference;
    procedure Exact_tick_firing_when_sleeping_next_timeout;
  end;

const
  N_TIMERS = 512;

type
  TOwnerRec = record
    Id: Integer;
    FiredAt: Int64;
    FireCount: Integer;
  end;

var
  Owners: array[0..N_TIMERS - 1] of TOwnerRec;
  Timers: array[0..N_TIMERS - 1] of TTimer;
  FiredLog: TList;            { Ids fired, in order }
  CurNow: Int64;
  W: TTimerWheel;
  { for the proc tests }
  RearmTarget: Integer;
  RearmDelta: Int64;

procedure LogProc(T: PTimer);
var
  O: ^TOwnerRec;
begin
  O := T^.Owner;
  O^.FiredAt := CurNow;
  Inc(O^.FireCount);
  FiredLog.Add(Pointer(PtrInt(O^.Id)));
end;

procedure RearmProc(T: PTimer);
begin
  LogProc(T);
  if RearmTarget >= 0 then
    W.Arm(@Timers[RearmTarget], CurNow + RearmDelta);
end;

procedure ResetAll(NowMs: Int64);
var
  I: Integer;
begin
  CurNow := NowMs;
  W.Init(NowMs);
  for I := 0 to N_TIMERS - 1 do
  begin
    Owners[I].Id := I;
    Owners[I].FiredAt := -1;
    Owners[I].FireCount := 0;
    TimerInit(@Timers[I], @LogProc, @Owners[I]);
  end;
  FiredLog.Clear;
end;

procedure AdvanceTo(NowMs: Int64);
begin
  CurNow := NowMs;
  W.Advance(NowMs);
end;

{ ---- tables ---- }

procedure TTestTimer.Tick_rounding_matches_tokio;
const
  { (ns, deadline_to_tick, instant_to_tick) with start_time = 0:
    deadline_to_tick(t) = (t + 999_999 ns).as_millis(); instant_to_tick(t) = t.as_millis() }
  Tab: array[0..9, 0..2] of Int64 = (
    (0, 0, 0),
    (1, 1, 0),
    (999999, 1, 0),
    (1000000, 1, 1),
    (1000001, 2, 1),
    (1999999, 2, 1),
    (2000000, 2, 2),
    (30000000000, 30000, 30000),
    (30000000001, 30001, 30000),
    (123456789012345, 123456790, 123456789));
var
  I: Integer;
begin
  for I := 0 to High(Tab) do
  begin
    AssertEquals('deadline_to_tick(' + IntToStr(Tab[I, 0]) + ')', Tab[I, 1], DeadlineToTick(Tab[I, 0]));
    AssertEquals('instant_to_tick(' + IntToStr(Tab[I, 0]) + ')', Tab[I, 2], InstantToTick(Tab[I, 0]));
  end;
end;

{ wheel/mod.rs test_level_for }
procedure TTestTimer.Level_for_matches_tokio_tests;
var
  Pos, Level: Integer;
  A: Int64;
begin
  for Pos := 0 to 63 do
    AssertEquals('level_for(0, ' + IntToStr(Pos) + ')', 0, WheelLevelFor(0, Pos));
  for Level := 1 to 4 do
    for Pos := Level to 63 do
    begin
      A := Int64(Pos) * (Int64(1) shl (6 * Level));
      AssertEquals('level_for(' + IntToStr(A) + ')', Level, WheelLevelFor(0, A));
      if Pos > Level then
        AssertEquals('level_for(' + IntToStr(A - 1) + ')', Level, WheelLevelFor(0, A - 1));
      if Pos < 64 then
        AssertEquals('level_for(' + IntToStr(A + 1) + ')', Level, WheelLevelFor(0, A + 1));
    end;
end;

{ level.rs test_slot_for, through the filing of an entry }
procedure TTestTimer.Slot_for_matches_tokio_tests;
var
  Pos, Level: Integer;
  A: Int64;
begin
  for Pos := 1 to 63 do
  begin
    ResetAll(0);
    W.Arm(@Timers[0], Pos);
    AssertEquals('level of ' + IntToStr(Pos), 0, Timers[0].Level);
    AssertEquals('slot of ' + IntToStr(Pos), Pos, Timers[0].Slot);
  end;
  for Level := 1 to 4 do
    for Pos := Level to 63 do
    begin
      A := Int64(Pos) * (Int64(1) shl (6 * Level));
      ResetAll(0);
      W.Arm(@Timers[0], A);
      AssertEquals('level of ' + IntToStr(A), Level, Timers[0].Level);
      AssertEquals('slot of ' + IntToStr(A), Pos, Timers[0].Slot);
    end;
end;

{ ---- semantics ---- }

procedure TTestTimer.Fires_at_deadline_not_before;
begin
  ResetAll(1000);
  W.Arm(@Timers[1], 1010);
  AssertFalse(Timers[1].Fired);
  AdvanceTo(1009);
  AssertEquals('not before', 0, Owners[1].FireCount);
  AdvanceTo(1010);
  AssertEquals('at the deadline', 1, Owners[1].FireCount);
  AssertTrue('Fired set', Timers[1].Fired);
  AssertEquals('unfiled after firing', -1, Timers[1].Level);
  AssertEquals('Due cleared', 0, Timers[1].Due);
  AssertTrue('wheel empty', W.IsEmpty);
  AdvanceTo(5000);
  AssertEquals('fires once', 1, Owners[1].FireCount);
end;

procedure TTestTimer.Lazy_rearm_later_keeps_filing;
begin
  ResetAll(1000);
  W.Arm(@Timers[2], 1100);
  AssertEquals(1100, Timers[2].Due);
  W.Arm(@Timers[2], 1200);
  AssertEquals('lazy: still filed at the old tick', 1100, Timers[2].Due);
  AssertEquals('deadline stored', 1200, Timers[2].Deadline);
  AdvanceTo(1150);
  AssertEquals('not fired at the old tick', 0, Owners[2].FireCount);
  AssertEquals('refiled at the new deadline', 1200, Timers[2].Due);
  AdvanceTo(1199);
  AssertEquals(0, Owners[2].FireCount);
  AdvanceTo(1200);
  AssertEquals(1, Owners[2].FireCount);
  AssertEquals(1200, Owners[2].FiredAt);
end;

procedure TTestTimer.Rearm_earlier_refiles;
begin
  ResetAll(1000);
  W.Arm(@Timers[3], 1200);
  W.Arm(@Timers[3], 1100);
  AssertEquals('refiled at once', 1100, Timers[3].Due);
  AdvanceTo(1100);
  AssertEquals(1, Owners[3].FireCount);
  AssertEquals(1100, Owners[3].FiredAt);
end;

procedure TTestTimer.Lazy_cancel_drops_entry_at_expiry;
begin
  ResetAll(1000);
  W.Arm(@Timers[4], 1050);
  W.Cancel(@Timers[4]);
  AssertEquals('cancel only clears Deadline', 1050, Timers[4].Due);
  AssertEquals(0, Timers[4].Deadline);
  AdvanceTo(1050);
  AssertEquals('not fired', 0, Owners[4].FireCount);
  AssertEquals('dropped (unfiled)', -1, Timers[4].Level);
  AssertTrue(W.IsEmpty);
  { cancel then re-arm before expiry: one firing at the new deadline }
  W.Arm(@Timers[4], 1100);
  W.Cancel(@Timers[4]);
  W.Arm(@Timers[4], 1120);
  AdvanceTo(1119);
  AssertEquals(0, Owners[4].FireCount);
  AdvanceTo(1120);
  AssertEquals(1, Owners[4].FireCount);
end;

procedure TTestTimer.Remove_unlinks_now;
begin
  ResetAll(1000);
  W.Arm(@Timers[5], 1300);
  W.Arm(@Timers[6], 1300);
  W.Remove(@Timers[5]);
  AssertEquals(-1, Timers[5].Level);
  AssertEquals(0, Timers[5].Due);
  AssertFalse('the other entry stays', W.IsEmpty);
  W.Remove(@Timers[6]);
  AssertTrue('slot bit cleared', W.IsEmpty);
  AssertEquals(-1, W.NextTimeoutMs(1000 * 1000000));
  AdvanceTo(2000);
  AssertEquals(0, Owners[5].FireCount + Owners[6].FireCount);
  W.Remove(@Timers[5]);    { removing an unfiled timer is a no-op }
end;

procedure TTestTimer.Arm_in_the_past_fires_on_next_advance;
begin
  ResetAll(1000);
  W.Arm(@Timers[7], 900);
  AssertEquals('pending', LEVEL_PENDING, Timers[7].Level);
  AssertEquals('no sleep', 0, W.NextTimeoutMs(1000 * 1000000));
  AdvanceTo(1000);
  AssertEquals(1, Owners[7].FireCount);
  W.Arm(@Timers[7], 1000);   { = elapsed: fires too (tokio: when <= elapsed) }
  AdvanceTo(1000);
  AssertEquals(2, Owners[7].FireCount);
end;

procedure TTestTimer.Proc_may_rearm_itself_and_others;
var
  I: Integer;
begin
  ResetAll(0);
  Timers[0].Proc := @RearmProc;
  RearmTarget := 0;
  RearmDelta := 10;
  W.Arm(@Timers[0], 10);
  for I := 1 to 100 do
    AdvanceTo(I * 10);
  AssertEquals('periodic', 100, Owners[0].FireCount);
  AssertEquals(1000, Owners[0].FiredAt);
  { rearm another one }
  ResetAll(0);
  Timers[1].Proc := @RearmProc;
  RearmTarget := 2;
  RearmDelta := 5;
  W.Arm(@Timers[1], 10);
  AdvanceTo(10);
  AssertEquals(1, Owners[1].FireCount);
  AdvanceTo(14);
  AssertEquals(0, Owners[2].FireCount);
  AdvanceTo(15);
  AssertEquals(1, Owners[2].FireCount);
  RearmTarget := -1;
end;

procedure TTestTimer.Proc_arming_due_timer_fires_in_same_advance;
begin
  ResetAll(0);
  Timers[1].Proc := @RearmProc;
  RearmTarget := 2;
  RearmDelta := -5;          { Timers[2] armed at 95 from a proc running at 100 }
  W.Arm(@Timers[1], 100);
  AdvanceTo(100);
  AssertEquals(1, Owners[1].FireCount);
  AssertEquals('fired in the same Advance', 1, Owners[2].FireCount);
  RearmTarget := -1;
end;

procedure CancelOtherProc(T: PTimer);
begin
  LogProc(T);
  if RearmTarget >= 0 then
    W.Cancel(@Timers[RearmTarget]);
end;

procedure TTestTimer.Cancel_while_pending_does_not_fire;
begin
  { armed in the past (pending), then cancelled before the Advance }
  ResetAll(1000);
  W.Arm(@Timers[1], 990);
  W.Cancel(@Timers[1]);
  AdvanceTo(1000);
  AssertEquals('cancelled pending entry', 0, Owners[1].FireCount);
  AssertTrue(W.IsEmpty);
  { two entries expire in the same slot; the first one's proc cancels the
    second one, which is already in the pending list }
  ResetAll(1000);
  Timers[2].Proc := @CancelOtherProc;
  RearmTarget := 3;
  W.Arm(@Timers[2], 1010);
  W.Arm(@Timers[3], 1010);
  AdvanceTo(1010);
  RearmTarget := -1;
  AssertEquals(1, Owners[2].FireCount);
  AssertEquals('cancelled by a proc while pending', 0, Owners[3].FireCount);
  AssertTrue(W.IsEmpty);
end;

procedure TTestTimer.Next_timeout_values;
begin
  ResetAll(5000);
  AssertEquals('nothing filed', -1, W.NextTimeoutMs(5000 * 1000000));
  W.Arm(@Timers[0], 5030);
  AssertEquals(30, W.NextTimeoutMs(5000 * 1000000));
  AssertEquals('now rounded down', 30, W.NextTimeoutMs(5000 * 1000000 + 999999));
  AssertEquals(1, W.NextTimeoutMs(5029 * 1000000));
  AssertEquals(0, W.NextTimeoutMs(5030 * 1000000));
  AssertEquals(0, W.NextTimeoutMs(6000 * 1000000));
  { a level-1 entry: the wheel wakes at its slot start (<= the deadline) }
  ResetAll(5000);
  W.Arm(@Timers[0], 5000 + 3000);
  AssertTrue(W.NextTimeoutMs(5000 * 1000000) <= 3000);
  AssertTrue(W.NextTimeoutMs(5000 * 1000000) > 0);
end;

procedure TTestTimer.Far_deadlines_cascade_down_levels;
const
  Far: array[0..5] of Int64 = (63, 4095, 262143, 16777215, 1073741823, 68719476734);
var
  I: Integer;
  Now, Next: Int64;
  T: Integer;
begin
  for I := 0 to High(Far) do
  begin
    ResetAll(7);
    W.Arm(@Timers[0], 7 + Far[I]);
    AssertEquals('level of +' + IntToStr(Far[I]), WheelLevelFor(7, 7 + Far[I]), Timers[0].Level);
    Now := 7;
    T := 0;
    while Owners[0].FireCount = 0 do
    begin
      Next := W.NextTimeoutMs(Now * 1000000);
      AssertTrue('a wake is scheduled', Next >= 0);
      Now := Now + Next;
      AdvanceTo(Now);
      Inc(T);
      AssertTrue('bounded number of wakes', T < 100);
    end;
    AssertEquals('fires exactly at +' + IntToStr(Far[I]), 7 + Far[I], Owners[0].FiredAt);
  end;
end;

{ ---- randomized comparison with a sorted-list reference ---- }

type
  TRef = record
    Wanted: Int64;           { 0 = none }
  end;

var
  Ref: array[0..N_TIMERS - 1] of TRef;

function ComparePointers(A, B: Pointer): Integer;
begin
  if PtrInt(A) < PtrInt(B) then
    Result := -1
  else if PtrInt(A) > PtrInt(B) then
    Result := 1
  else
    Result := 0;
end;

function RefEarliest: Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to N_TIMERS - 1 do
    if (Ref[I].Wanted <> 0) and ((Result = 0) or (Ref[I].Wanted < Result)) then
      Result := Ref[I].Wanted;
end;

function RandomDelta: Int64;
begin
  case Random(6) of
    0: Result := 1 + Random(64);
    1: Result := 1 + Random(4096);
    2: Result := 1 + Random(262144);
    3: Result := 1 + Random(16777216);
    4: Result := 1 + Random(30000);
  else
    Result := 1 + Random(200);
  end;
end;

procedure TTestTimer.Random_vs_sorted_reference;
var
  Seed, Step, I, K, Op: Integer;
  Now, D, E, Nxt: Int64;
  Expected, Got: TList;
begin
  Expected := TList.Create;
  Got := TList.Create;
  try
    for Seed := 1 to 40 do
    begin
      RandSeed := Seed;
      Now := 1 + Random(100000);
      ResetAll(Now);
      for I := 0 to N_TIMERS - 1 do
        Ref[I].Wanted := 0;
      for Step := 1 to 4000 do
      begin
        Op := Random(100);
        K := Random(N_TIMERS);
        if Op < 45 then
        begin
          D := Now + RandomDelta;
          W.Arm(@Timers[K], D);
          Ref[K].Wanted := D;
        end
        else if Op < 55 then
        begin
          W.Cancel(@Timers[K]);
          Ref[K].Wanted := 0;
        end
        else if Op < 60 then
        begin
          W.Remove(@Timers[K]);
          Ref[K].Wanted := 0;
        end
        else
        begin
          { no oversleep: the wheel wakes no later than the earliest deadline }
          E := RefEarliest;
          Nxt := W.NextTimeoutMs(Now * 1000000 + Random(1000000));
          if E <> 0 then
          begin
            AssertTrue(Format('seed %d step %d: a wake is scheduled', [Seed, Step]), Nxt >= 0);
            AssertTrue(Format('seed %d step %d: wake %d after earliest %d', [Seed, Step, Now + Nxt, E]),
              Now + Nxt <= E);
          end;
          case Random(4) of
            0: D := Random(3);
            1: D := Random(70);
            2: D := Random(5000);
          else
            D := Random(400000);
          end;
          Now := Now + D;
          Expected.Clear;
          for I := 0 to N_TIMERS - 1 do
            if (Ref[I].Wanted <> 0) and (Ref[I].Wanted <= Now) then
            begin
              Expected.Add(Pointer(PtrInt(I)));
              Ref[I].Wanted := 0;
            end;
          FiredLog.Clear;
          AdvanceTo(Now);
          Got.Assign(FiredLog);
          Expected.Sort(@ComparePointers);
          Got.Sort(@ComparePointers);
          AssertEquals(Format('seed %d step %d: number fired at %d', [Seed, Step, Now]),
            Expected.Count, Got.Count);
          for I := 0 to Expected.Count - 1 do
            AssertEquals(Format('seed %d step %d: fired id', [Seed, Step]),
              PtrInt(Expected[I]), PtrInt(Got[I]));
          for I := 0 to Got.Count - 1 do
            AssertTrue('Fired flag', Timers[PtrInt(Got[I])].Fired);
        end;
      end;
    end;
  finally
    Expected.Free;
    Got.Free;
  end;
end;

procedure TTestTimer.Exact_tick_firing_when_sleeping_next_timeout;
var
  Seed, I, Fired, Wakes: Integer;
  Now, Nxt: Int64;
begin
  for Seed := 1 to 20 do
  begin
    RandSeed := 1000 + Seed;
    Now := 1 + Random(1000000);
    ResetAll(Now);
    for I := 0 to N_TIMERS - 1 do
      W.Arm(@Timers[I], Now + RandomDelta);
    Fired := 0;
    Wakes := 0;
    repeat
      Nxt := W.NextTimeoutMs(Now * 1000000);
      if Nxt < 0 then
        Break;
      Now := Now + Nxt;
      FiredLog.Clear;
      AdvanceTo(Now);
      Inc(Wakes);
      for I := 0 to FiredLog.Count - 1 do
      begin
        AssertEquals(Format('seed %d: timer %d fired at its tick', [Seed, PtrInt(FiredLog[I])]),
          Timers[PtrInt(FiredLog[I])].Deadline, Now);
        Inc(Fired);
      end;
    until False;
    AssertEquals('every timer fired', N_TIMERS, Fired);
    AssertTrue('wheel empty', W.IsEmpty);
  end;
end;

begin
  FiredLog := TList.Create;
  RearmTarget := -1;
  RegisterTest(TTestTimer);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
  FiredLog.Free;
end.
