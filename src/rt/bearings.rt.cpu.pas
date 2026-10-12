{ bearings.rt.cpu - how many CPUs the process may use, and thread pinning.

  The server runs one event loop thread per usable CPU by default
  (DefaultLoopCount), and the worker pool size is derived from the same
  number. bearings.server calls DefaultLoopCount when no loop count is configured
  and PinCurrentThread to bind each loop thread to one CPU, so the thread
  keeps its CPU caches and does not migrate.

  DefaultLoopCount counts the CPUs in the process's affinity mask
  (sched_getaffinity(2): the CPUs the scheduler may run it on, which
  taskset or a container can restrict) and caps the count by the cgroup CPU
  quota. A container limited to, say, 2.5 CPUs of a 64-CPU host gets 3
  loops, not 64. The quota is read from the process's own cgroup, found
  through /proc/self/cgroup and /proc/self/mountinfo: cgroup v1
  cpu.cfs_quota_us / cpu.cfs_period_us or cgroup v2 cpu.max, rounded up.
  FPC's GetCPUCount is not used (on Linux it returns 1).

  Threading: any thread; the routines keep no state. Called at startup
  only, so they use strings and files freely. }
unit bearings.rt.cpu;

{$mode objfpc}{$H+}

interface

uses
  bearings.rt.sys;

type
  TCpuList = array of Integer;

{ sched_getaffinity(0, ...): the CPU ids the calling thread may run on,
  ascending; empty if the system call fails. }
function UsableCpus: TCpuList;
{ The CPU quota of the process's cgroup, rounded up: Ceil(quota / period)
  from cgroup v2 cpu.max ("quota period") or cgroup v1 cpu.cfs_quota_us and
  cpu.cfs_period_us. 0 when there is no quota or it cannot be read. }
function CgroupCpuLimit: Integer;
{ Max(1, Min(Length(UsableCpus), CgroupCpuLimit if > 0)). When the
  affinity call fails, counts the CPUs listed in
  /sys/devices/system/cpu/online instead. }
function DefaultLoopCount: Integer;
{ sched_setaffinity(0, [Cpu]): the calling thread runs only on Cpu from now
  on. False if Cpu is out of range or the call fails. }
function PinCurrentThread(Cpu: Integer): Boolean;

{ CgroupCpuLimit with the two /proc files given (tests use fixture files);
  0 = no quota. }
function CgroupCpuLimitFrom(const CgroupProc, MountInfoProc: string): Integer;
{ Parses a CPU list such as '0-3,8,10-11' (the sysfs 'online' format);
  invalid items are skipped. Public for tests. }
function ParseCpuList(const S: string): TCpuList;

implementation

uses
  SysUtils, Classes;

function UsableCpus: TCpuList;
var
  Mask: array[0..CPU_SET_BYTES div 8 - 1] of QWord;
  R: SizeInt;
  I, K: Integer;
begin
  Result := nil;
  FillChar(Mask, SizeOf(Mask), 0);
  R := SysSchedGetAffinity(0, SizeOf(Mask), @Mask);
  if R <= 0 then
    Exit;
  K := 0;
  SetLength(Result, CPU_SET_BYTES * 8);
  for I := 0 to CPU_SET_BYTES * 8 - 1 do
    if (Mask[I div 64] and (QWord(1) shl (I mod 64))) <> 0 then
    begin
      Result[K] := I;
      Inc(K);
    end;
  SetLength(Result, K);
end;

function ParseCpuList(const S: string): TCpuList;
var
  Parts: TStringArray;
  P: string;
  Dash, A, B, I, K: Integer;
begin
  Result := nil;
  K := 0;
  Parts := Trim(S).Split([',']);
  for P in Parts do
  begin
    if Trim(P) = '' then
      Continue;
    Dash := Pos('-', P);
    if Dash > 0 then
    begin
      A := StrToIntDef(Trim(Copy(P, 1, Dash - 1)), -1);
      B := StrToIntDef(Trim(Copy(P, Dash + 1, MaxInt)), -1);
    end
    else
    begin
      A := StrToIntDef(Trim(P), -1);
      B := A;
    end;
    if (A < 0) or (B < A) then
      Continue;
    SetLength(Result, K + B - A + 1);
    for I := A to B do
    begin
      Result[K] := I;
      Inc(K);
    end;
  end;
end;

function ReadFileText(const Path: string; out Text: string): Boolean;
var
  L: TStringList;
begin
  Result := False;
  Text := '';
  if not FileExists(Path) then
    Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
      Text := L.Text;
      Result := True;
    except
      Result := False;
    end;
  finally
    L.Free;
  end;
end;

{ Finds the cgroup path of the cpu controller in /proc/self/cgroup. Each
  line is "id:controllers:path"; a cgroup v1 line lists its controllers
  (for example "4:cpu,cpuacct:/user.slice"), the cgroup v2 line has an empty
  list ("0::/user.slice"). A v1 line naming 'cpu' wins over the v2 line,
  because on a hybrid system the v1 hierarchy holds the cpu controller.
  IsV2 tells which kind was found. }
function LoadSubsys(const CgroupProc: string; out IsV2: Boolean; out Base: string): Boolean;
var
  Text, Line, Subs, Path: string;
  Lines, F, SubList: TStringArray;
  HaveV1, Found, LineV2, HasCpu: Boolean;
  S: string;
begin
  Result := False;
  IsV2 := False;
  Base := '';
  if not ReadFileText(CgroupProc, Text) then
    Exit;
  HaveV1 := False;
  Found := False;
  Lines := Text.Split([#10]);
  for Line in Lines do
  begin
    F := Line.Split([':']);
    if Length(F) < 3 then
      Continue;
    Subs := F[1];
    LineV2 := Subs = '';
    if not LineV2 then
    begin
      HasCpu := False;
      SubList := Subs.Split([',']);
      for S in SubList do
        if S = 'cpu' then
          HasCpu := True;
      if not HasCpu then
        Continue;
    end;
    { the path is everything after the second ':' }
    Path := Copy(Line, Length(F[0]) + Length(F[1]) + 3, MaxInt);
    if Found and LineV2 then
      Continue;                       { a line already found wins over the v2 line }
    if HaveV1 and LineV2 then
      Continue;
    Found := True;
    IsV2 := LineV2;
    if not LineV2 then
      HaveV1 := True;
    Base := Path;
  end;
  Result := Found;
end;

{ Finds, in /proc/self/mountinfo, the first mount of the requested cgroup
  version (for v1: one with the 'cpu' super option). Fields used (see
  proc(5)): 3 = root of the mount inside the cgroup tree, 4 = mount point;
  after the '-' separator: the file system type ('cgroup' or 'cgroup2'),
  the source, the super options. }
function LoadMountInfo(const MountInfoProc: string; WantV2: Boolean;
  out Root, MountPoint: string): Boolean;
var
  Text, Line, S: string;
  Lines, F, Opts: TStringArray;
  I, Sep: Integer;
  IsV2, HasCpu: Boolean;
begin
  Result := False;
  Root := '';
  MountPoint := '';
  if not ReadFileText(MountInfoProc, Text) then
    Exit;
  Lines := Text.Split([#10]);
  for Line in Lines do
  begin
    F := Line.Split([' ']);
    if Length(F) < 5 then
      Continue;
    Sep := -1;
    for I := 5 to High(F) do
      if F[I] = '-' then
      begin
        Sep := I;
        Break;
      end;
    if (Sep < 0) or (Sep + 1 > High(F)) then
      Continue;
    if F[Sep + 1] = 'cgroup' then
      IsV2 := False
    else if F[Sep + 1] = 'cgroup2' then
      IsV2 := True
    else
      Continue;
    if not IsV2 then
    begin
      if Sep + 3 > High(F) then
        Continue;
      HasCpu := False;
      Opts := F[Sep + 3].Split([',']);
      for S in Opts do
        if S = 'cpu' then
          HasCpu := True;
      if not HasCpu then
        Continue;
    end;
    if IsV2 <> WantV2 then
      Continue;
    Root := F[3];
    MountPoint := F[4];
    Exit(True);
  end;
end;

{ Decimal digits only: 'max' and '-1' (the "no quota" values) fail. }
function ParseUInt(const S: string; out V: QWord): Boolean;
var
  I: Integer;
begin
  Result := (S <> '');
  V := 0;
  for I := 1 to Length(S) do
    if (S[I] >= '0') and (S[I] <= '9') then
      V := V * 10 + QWord(Ord(S[I]) - Ord('0'))
    else
      Exit(False);
end;

function CgroupCpuLimitFrom(const CgroupProc, MountInfoProc: string): Integer;
var
  IsV2: Boolean;
  Base, Root, Mp, Rel, Dir, Text, Line: string;
  Quota, Period: QWord;
  F: TStringArray;
begin
  Result := 0;
  if not LoadSubsys(CgroupProc, IsV2, Base) then
    Exit;
  if not LoadMountInfo(MountInfoProc, IsV2, Root, Mp) then
    Exit;
  { the cgroup path relative to the mount's root (whole path components
  only), then appended to the mount point }
  if Root = '/' then
    Rel := Base
  else if Base = Root then
    Rel := ''
  else if Copy(Base, 1, Length(Root) + 1) = Root + '/' then
    Rel := Copy(Base, Length(Root) + 1, MaxInt)
  else
    Exit;
  while (Rel <> '') and (Rel[1] = '/') do
    Delete(Rel, 1, 1);
  Dir := IncludeTrailingPathDelimiter(Mp) + Rel;
  Dir := IncludeTrailingPathDelimiter(Dir);
  if IsV2 then
  begin
    if not ReadFileText(Dir + 'cpu.max', Text) then
      Exit;
    Line := Text.Split([#10])[0];
    F := Line.Split([' ']);
    if Length(F) < 2 then
      Exit;
    if not ParseUInt(F[0], Quota) then
      Exit;                            { 'max': no quota }
    if not ParseUInt(Trim(F[1]), Period) then
      Exit;
  end
  else
  begin
    if not ReadFileText(Dir + 'cpu.cfs_quota_us', Text) then
      Exit;
    if not ParseUInt(Trim(Text), Quota) then
      Exit;                            { -1: no quota }
    if not ReadFileText(Dir + 'cpu.cfs_period_us', Text) then
      Exit;
    if not ParseUInt(Trim(Text), Period) then
      Exit;
  end;
  if Period = 0 then
    Exit;
  Result := Integer((Quota + Period - 1) div Period);
end;

function CgroupCpuLimit: Integer;
begin
  Result := CgroupCpuLimitFrom('/proc/self/cgroup', '/proc/self/mountinfo');
end;

function DefaultLoopCount: Integer;
var
  N, Q: Integer;
  Text: string;
begin
  N := Length(UsableCpus);
  if N = 0 then
  begin
    if ReadFileText('/sys/devices/system/cpu/online', Text) then
      N := Length(ParseCpuList(Text));
  end;
  if N < 1 then
    N := 1;
  Q := CgroupCpuLimit;
  if (Q > 0) and (Q < N) then
    N := Q;
  Result := N;
end;

function PinCurrentThread(Cpu: Integer): Boolean;
var
  Mask: array[0..CPU_SET_BYTES div 8 - 1] of QWord;
begin
  if (Cpu < 0) or (Cpu >= CPU_SET_BYTES * 8) then
    Exit(False);
  FillChar(Mask, SizeOf(Mask), 0);
  Mask[Cpu div 64] := QWord(1) shl (Cpu mod 64);
  Result := SysSchedSetAffinity(0, SizeOf(Mask), @Mask) = 0;
end;

end.
