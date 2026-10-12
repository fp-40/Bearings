{ bearings.rt.timer - hierarchical timer wheel: 6 levels x 64 slots, 1 ms ticks.

  A server keeps many timeouts at once (one or more per connection: time to
  receive the request header, time to receive the body, idle time between
  keep-alive requests) and nearly all of them are cancelled or moved before
  they expire. A timer wheel makes arming, moving and cancelling a timer
  O(1) and finds the next expiry with a few bit operations, instead of
  keeping a sorted structure.

  Layout. Time is counted in ticks of 1 ms of the loop's monotonic clock
  (bearings.rt.clock). Level 0 has 64 slots of 1 ms each (it covers 64 ms), level 1
  has 64 slots of 64 ms (4.096 s), level L has 64 slots of 64^L ms. Each slot
  is a doubly linked list of timers, and Occupied[L] is a 64-bit mask with
  one bit per non-empty slot of level L. A timer is filed at the level given
  by the highest 6-bit group in which its tick and the current tick
  (Elapsed) differ, so near deadlines sit in fine slots and far ones in
  coarse slots. When a coarse slot expires, its timers are filed again
  relative to the slot's start time, which moves them down to a finer
  level; this repeats until they reach the pending list and fire. The
  largest distance the wheel can hold is WHEEL_MAX_DURATION ms (about 795
  days); a later deadline is filed at that distance and filed again when it
  is reached.

  Rounding. A deadline is rounded up to the next whole millisecond
  (DeadlineToTick) and the current time is rounded down (InstantToTick), so
  a timer never fires before its deadline.

  Entry states (TTimer.Level):
    -1             not filed (Due = 0)
    0..5           filed in Slots[Level, Slot]; Due = the tick it was filed for
    LEVEL_PENDING  expired, waiting in the pending list to be fired
  Lazy arm: Arm on an entry already filed with Due <= the new deadline only
  stores Deadline; the entry is filed again when its slot expires. Moving a
  deadline later (for example the idle timeout after each request) then
  costs no list operation. Lazy cancel: Cancel sets Deadline := 0; the entry
  stays in its slot and is dropped when the slot expires.

  Expiry order: the earliest slot first; within a slot, the oldest insertion
  first. Expired entries go through the pending list (FIFO) and fire one at
  a time, so a Proc may Arm, Cancel or Remove any timer, including its own.

  Use: each TLoop owns one TTimerWheel (TLoop.Timers). Owners embed a TTimer
  in themselves, call TimerInit once and then Arm / Cancel / Remove it. The
  loop calls Advance once per iteration and uses NextTimeoutMs as the
  epoll_wait timeout.

  Threading: a wheel and its timers belong to the loop thread; nothing here
  is thread-safe.

  No managed types (strings, interfaces, dynamic arrays) are used, so no
  routine gets an implicit exception frame; tools/check-hot-asm.sh checks
  this for TTimerWheel.*. }
unit bearings.rt.timer;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

const
  WHEEL_LEVELS = 6;
  WHEEL_SLOTS = 64;
  LEVEL_PENDING = WHEEL_LEVELS;
  { the largest tick distance the wheel can represent: 2^36 - 1 ms }
  WHEEL_MAX_DURATION = (Int64(1) shl (6 * WHEEL_LEVELS)) - 1;

type
  PTimer = ^TTimer;
  TTimerProc = procedure(T: PTimer);   { plain procedure; T^.Owner is the object }
  { One timer, embedded in its owner (no allocation). Prev/Next link it into a
    slot list or into the pending list. }
  TTimer = record
    Prev, Next: PTimer;
    Deadline: Int64;                   { ms (loop clock) the owner wants; 0 = not wanted }
    Due: Int64;                        { ms of the slot it is filed in; 0 = not filed }
    Level, Slot: SmallInt;
    Proc: TTimerProc;
    Owner: Pointer;
    Fired: Boolean;                    { True once Proc ran for the current Deadline; Arm resets it }
  end;

  { The next slot to expire: Deadline is the tick at which the slot starts. }
  TWheelExpiration = record
    Level: Integer;
    Slot: Integer;
    Deadline: Int64;
  end;

  TTimerWheel = record
    Slots: array[0..WHEEL_LEVELS - 1, 0..WHEEL_SLOTS - 1] of PTimer;   { list heads; newest first }
    Occupied: array[0..WHEEL_LEVELS - 1] of QWord;   { bit S set = Slots[L, S] is not empty }
    Elapsed: Int64;                                  { the tick the wheel has processed up to }
    PendingHead, PendingTail: PTimer;                { expired timers, in firing order }
    procedure Init(NowMs: Int64);
    { DeadlineMs is a tick (use DeadlineToTick on a ns time); it must be > 0. Lazy: when T is
      already filed with Due <= DeadlineMs only Deadline is stored; when Due > DeadlineMs (the
      deadline moved earlier) it is unlinked and filed again. Sets Fired := False. }
    procedure Arm(T: PTimer; DeadlineMs: Int64);
    { Lazy cancel: Deadline := 0 (the filed entry is dropped when its slot expires). }
    procedure Cancel(T: PTimer); inline;
    { Unlinks T at once, so the wheel holds no pointer to it: for owners about to be freed. }
    procedure Remove(T: PTimer);
    { Expires every slot that starts at or before NowMs. An entry with Deadline = 0 is dropped;
      one with Deadline > NowMs is filed again at Deadline; otherwise Fired := True and Proc(T). }
    procedure Advance(NowMs: Int64);
    { Milliseconds from NowNs to the next slot expiry, for epoll_wait: -1 when nothing is
      filed, 0 when something is already due. }
    function NextTimeoutMs(NowNs: Int64): Integer;
    { The next slot to process: the pending list (at Elapsed) if not empty, else the earliest
      occupied slot over all levels. False when the wheel is empty. }
    function NextExpiration(out E: TWheelExpiration): Boolean;
    { True when no entry is filed or pending }
    function IsEmpty: Boolean;
  private
    procedure FileAt(T: PTimer; When, Base: Int64);
    procedure Unlink(T: PTimer);
    procedure PushPending(T: PTimer); inline;
    procedure ProcessExpiration(const E: TWheelExpiration);
  end;

{ Initializes an embedded timer: not filed, no deadline. }
procedure TimerInit(T: PTimer; Proc: TTimerProc; Owner: Pointer); inline;
{ ns -> ms, rounded up: a deadline tick. }
function DeadlineToTick(Ns: Int64): Int64; inline;
{ ns -> ms, rounded down: the current tick. }
function InstantToTick(Ns: Int64): Int64; inline;
{ The level for a timer due at When when the wheel is at Elapsed: the index of the highest
  6-bit group in which the two differ. The "or 63" puts every tick of the current 64 ms
  block at level 0; the clamp keeps the result below WHEEL_LEVELS. }
function WheelLevelFor(Elapsed, When: Int64): Integer; inline;

implementation

procedure TimerInit(T: PTimer; Proc: TTimerProc; Owner: Pointer);
begin
  T^.Prev := nil;
  T^.Next := nil;
  T^.Deadline := 0;
  T^.Due := 0;
  T^.Level := -1;
  T^.Slot := -1;
  T^.Proc := Proc;
  T^.Owner := Owner;
  T^.Fired := False;
end;

function DeadlineToTick(Ns: Int64): Int64;
begin
  Result := (Ns + 999999) div 1000000;
end;

function InstantToTick(Ns: Int64): Int64;
begin
  Result := Ns div 1000000;
end;

function WheelLevelFor(Elapsed, When: Int64): Integer;
var
  Masked: QWord;
begin
  Masked := (QWord(Elapsed) xor QWord(When)) or QWord(WHEEL_SLOTS - 1);
  if Masked >= QWord(WHEEL_MAX_DURATION) then
    Masked := QWord(WHEEL_MAX_DURATION) - 1;
  Result := Integer(BsrQWord(Masked)) div WHEEL_LEVELS;
end;

{ SlotRange: the ms one slot of Level covers (64^Level). LevelRange: the ms the whole
  level covers (64^(Level+1)). SlotFor: the slot of Level that holds tick When. }
function SlotRange(Level: Integer): Int64; inline;
begin
  Result := Int64(1) shl (6 * Level);
end;

function LevelRange(Level: Integer): Int64; inline;
begin
  Result := Int64(1) shl (6 * (Level + 1));
end;

function SlotFor(When: Int64; Level: Integer): Integer; inline;
begin
  Result := Integer((QWord(When) shr (Level * 6)) and (WHEEL_SLOTS - 1));
end;

{ The first occupied slot of Level at or after the slot that holds Now, wrapping around.
  Rotating the mask right by NowSlot makes the lowest set bit that slot. Its start
  time is computed within the current turn of the level; a start not after Now
  belongs to the next turn, one LevelRange later. }
function LevelNextExpiration(Occupied: QWord; Level: Integer; Now: Int64;
  out E: TWheelExpiration): Boolean; inline;
var
  NowSlot, Slot: Integer;
  Rotated: QWord;
  LStart, Deadline: Int64;
begin
  if Occupied = 0 then
    Exit(False);
  NowSlot := Integer((QWord(Now) div QWord(SlotRange(Level))) mod WHEEL_SLOTS);
  Rotated := RorQWord(Occupied, NowSlot);
  Slot := (Integer(BsfQWord(Rotated)) + NowSlot) mod WHEEL_SLOTS;
  LStart := Now and not (LevelRange(Level) - 1);
  Deadline := LStart + Int64(Slot) * SlotRange(Level);
  if Deadline <= Now then
    Inc(Deadline, LevelRange(Level));
  E.Level := Level;
  E.Slot := Slot;
  E.Deadline := Deadline;
  Result := True;
end;

procedure TTimerWheel.Init(NowMs: Int64);
begin
  FillChar(Slots, SizeOf(Slots), 0);
  FillChar(Occupied, SizeOf(Occupied), 0);
  Elapsed := NowMs;
  PendingHead := nil;
  PendingTail := nil;
end;

procedure TTimerWheel.PushPending(T: PTimer);
begin
  T^.Level := LEVEL_PENDING;
  T^.Slot := -1;
  T^.Next := nil;
  T^.Prev := PendingTail;
  if PendingTail <> nil then
    PendingTail^.Next := T
  else
    PendingHead := T;
  PendingTail := T;
end;

{ Files T for tick When, at the level computed against Base (the current tick,
  or the start of the slot being expired). The entry goes to the front of the
  slot list. A tick at or before Elapsed goes straight to the pending list, so
  it fires in this Advance. }
procedure TTimerWheel.FileAt(T: PTimer; When, Base: Int64);
var
  L, S: Integer;
  H: PTimer;
begin
  if When <= Elapsed then
  begin
    T^.Due := When;
    PushPending(T);
    Exit;
  end;
  if When - Base > WHEEL_MAX_DURATION - 1 then
    When := Base + WHEEL_MAX_DURATION - 1;   { clamped: filed again when this slot expires }
  L := WheelLevelFor(Base, When);
  S := SlotFor(When, L);
  T^.Due := When;
  T^.Level := L;
  T^.Slot := S;
  H := Slots[L, S];
  T^.Prev := nil;
  T^.Next := H;
  if H <> nil then
    H^.Prev := T;
  Slots[L, S] := T;
  Occupied[L] := Occupied[L] or (QWord(1) shl S);
end;

procedure TTimerWheel.Unlink(T: PTimer);
var
  L, S: Integer;
begin
  L := T^.Level;
  if L = LEVEL_PENDING then
  begin
    if T^.Prev <> nil then
      T^.Prev^.Next := T^.Next
    else
      PendingHead := T^.Next;
    if T^.Next <> nil then
      T^.Next^.Prev := T^.Prev
    else
      PendingTail := T^.Prev;
  end
  else if L >= 0 then
  begin
    S := T^.Slot;
    if T^.Prev <> nil then
      T^.Prev^.Next := T^.Next
    else
      Slots[L, S] := T^.Next;
    if T^.Next <> nil then
      T^.Next^.Prev := T^.Prev;
    if Slots[L, S] = nil then
      Occupied[L] := Occupied[L] and not (QWord(1) shl S);
  end;
  T^.Prev := nil;
  T^.Next := nil;
  T^.Level := -1;
  T^.Slot := -1;
  T^.Due := 0;
end;

procedure TTimerWheel.Arm(T: PTimer; DeadlineMs: Int64);
begin
  Assert(DeadlineMs > 0, 'TTimerWheel.Arm: deadline 0 means "not wanted"');
  T^.Deadline := DeadlineMs;
  T^.Fired := False;
  if T^.Level >= 0 then
  begin
    if T^.Due <= DeadlineMs then
      Exit;                                  { lazy: refiled when its slot expires }
    Unlink(T);
  end;
  FileAt(T, DeadlineMs, Elapsed);
end;

procedure TTimerWheel.Cancel(T: PTimer);
begin
  T^.Deadline := 0;
end;

procedure TTimerWheel.Remove(T: PTimer);
begin
  if T^.Level >= 0 then
    Unlink(T);
  T^.Deadline := 0;
end;

function TTimerWheel.NextExpiration(out E: TWheelExpiration): Boolean;
var
  L: Integer;
begin
  if PendingHead <> nil then
  begin
    E.Level := 0;
    E.Slot := 0;
    E.Deadline := Elapsed;
    Exit(True);
  end;
  for L := 0 to WHEEL_LEVELS - 1 do
    if LevelNextExpiration(Occupied[L], L, Elapsed, E) then
      Exit(True);
  Result := False;
end;

function TTimerWheel.IsEmpty: Boolean;
var
  L: Integer;
begin
  if PendingHead <> nil then
    Exit(False);
  for L := 0 to WHEEL_LEVELS - 1 do
    if Occupied[L] <> 0 then
      Exit(False);
  Result := True;
end;

{ Empties one expired slot, walking from the list's tail (the oldest entry,
  since entries are added at the front). An entry whose Deadline is after
  the slot's start is filed again relative to that start, which puts it at a
  lower level or in a later slot. The others go to the pending list.
  Lazily cancelled entries are dropped. }
procedure TTimerWheel.ProcessExpiration(const E: TWheelExpiration);
var
  T, Prev: PTimer;
begin
  T := Slots[E.Level, E.Slot];
  Slots[E.Level, E.Slot] := nil;
  Occupied[E.Level] := Occupied[E.Level] and not (QWord(1) shl E.Slot);
  if T = nil then
    Exit;
  while T^.Next <> nil do
    T := T^.Next;
  while T <> nil do
  begin
    Prev := T^.Prev;
    T^.Prev := nil;
    T^.Next := nil;
    T^.Level := -1;
    T^.Slot := -1;
    if T^.Deadline = 0 then
      T^.Due := 0                                  { lazily cancelled: dropped }
    else if T^.Deadline > E.Deadline then
      FileAt(T, T^.Deadline, E.Deadline)           { moved later by a lazy Arm, or a coarse-level entry moving down }
    else
      PushPending(T);
    T := Prev;
  end;
end;

{ Repeats until nothing more is due: fire the pending entries one by one,
  then process the next slot whose start is <= NowMs (which may add pending
  entries). Finally Elapsed := NowMs. Each pending entry is unlinked before
  its Proc runs, so the Proc may change any timer. }
procedure TTimerWheel.Advance(NowMs: Int64);
var
  T: PTimer;
  E: TWheelExpiration;
begin
  repeat
    T := PendingHead;
    if T <> nil then
    begin
      PendingHead := T^.Next;
      if PendingHead <> nil then
        PendingHead^.Prev := nil
      else
        PendingTail := nil;
      T^.Prev := nil;
      T^.Next := nil;
      T^.Level := -1;
      T^.Slot := -1;
      T^.Due := 0;
      if T^.Deadline = 0 then
        Continue;                                  { cancelled while pending }
      if T^.Deadline > NowMs then
      begin
        FileAt(T, T^.Deadline, Elapsed);           { moved later by Arm while pending }
        Continue;
      end;
      T^.Fired := True;
      T^.Proc(T);                                  { may Arm/Cancel/Remove any timer }
      Continue;
    end;
    if NextExpiration(E) and (E.Deadline <= NowMs) then
    begin
      ProcessExpiration(E);
      if E.Deadline > Elapsed then
        Elapsed := E.Deadline;
    end
    else
    begin
      if NowMs > Elapsed then
        Elapsed := NowMs;
      Break;
    end;
  until False;
end;

function TTimerWheel.NextTimeoutMs(NowNs: Int64): Integer;
var
  E: TWheelExpiration;
  NowMs, D: Int64;
begin
  if not NextExpiration(E) then
    Exit(-1);
  NowMs := NowNs div 1000000;
  D := E.Deadline - NowMs;
  if D <= 0 then
    Exit(0);
  if D > High(Integer) then
    D := High(Integer);
  Result := Integer(D);
end;

end.
