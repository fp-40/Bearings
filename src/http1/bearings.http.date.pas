{ bearings.http.date - the value of the Date response header, formatted once per
  second.

  An HTTP server sends a Date header with each response (RFC 9110 section
  6.6.1), in the fixed format IMF-fixdate, always 29 bytes and in GMT:
  "Sun, 06 Nov 1994 08:49:37 GMT". The value changes only once per second,
  so instead of formatting it for every response this unit keeps the
  formatted bytes and formats them again only when the second changes.

  Main types and routines:
  - TDateCache: the formatted value and the time of the next change.
  - LoopDate: the cache of an event loop. Each loop keeps one in its Ext
    storage (bearings.rt.loop); this unit's initialization installs the
    loop's tick hook (LoopTickProc), which refreshes it once per second, and
    the response encoder copies the 29 bytes from LoopDate(Loop).
  - DateUpdate / DateExtend / DateBuffer: the same with one TDateCache per
    thread (a threadvar), for code that runs outside an event loop. The
    response encoder uses DateBuffer when it is given no loop cache.
  - FormatHttpDate: the formatter itself.

  The cache formats the value again at most once per second: Update sets
  the next update time to the start of the next whole second, and Check
  formats again only after that time.

  Threading: a TDateCache belongs to one thread (no locking). The
  thread-local routines use the calling thread's own cache. }
unit bearings.http.date;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, bearings.rt.loop;

const
  { the length of "Sun, 06 Nov 1994 08:49:37 GMT" }
  DATE_VALUE_LENGTH = 29;

type
  TDateBytes = array[0..DATE_VALUE_LENGTH - 1] of Byte;
  PDateBytes = ^TDateBytes;
  PDateCache = ^TDateCache;

  TDateCache = record
  private
    FBytes: TDateBytes;
    FNextUpdateUs: Int64;  { microseconds since the Unix epoch; 0 = never rendered }
  public
    { Formats the value for the current time. }
    procedure Init;
    { Formats the value again if NowUs (microseconds since the Unix epoch)
      is past the next update time; the overload without NowUs reads the
      clock. }
    procedure Check; overload;
    procedure Check(NowUs: Int64); overload;
    { Formats the value for NowUs and sets the next update time to the
      start of the next whole second. }
    procedure Update(NowUs: Int64);
    { The 29 formatted bytes; the pointer stays valid as long as the cache. }
    function Buffer: PByte;
    procedure CopyTo(Dst: PByte);
    function AsString: RawByteString;
    property NextUpdateUs: Int64 read FNextUpdateUs;
  end;

{ The 29 bytes of Loop's cache (in Loop.Ext). The loop's tick hook keeps
  them current; valid as long as the loop. Loop thread only. }
function LoopDate(Loop: TLoop): PByte; inline;
{ Loop's cache itself. }
function LoopDateCache(Loop: TLoop): PDateCache; inline;

{ Current wall-clock time in microseconds since the Unix epoch. }
function UnixTimeMicros: Int64;

{ Writes UnixSeconds (>= 0 and < 253402300800, that is from 1970 to the end
  of year 9999) as IMF-fixdate into Dst (29 bytes). Raises ERangeError
  outside that range, because the format has a four-digit year. }
procedure FormatHttpDate(UnixSeconds: Int64; Dst: PByte);
function FormatHttpDateStr(UnixSeconds: Int64): RawByteString;

{ The thread-local cache. DateUpdate formats this thread's value again when
  the second changed; DateExtend and DateBuffer do not refresh the value
  (they only format it the first time), so the thread must call DateUpdate
  regularly. }
procedure DateUpdate;
{ Copies the cached 29 bytes to Dst. Renders first if this thread never did. }
procedure DateExtend(Dst: PByte);
{ Pointer to this thread's cached 29 bytes (valid for the thread's life). }
function DateBuffer: PByte;

implementation

uses
  BaseUnix, Unix, bearings.rt.clock;

{ the cache must fit in TLoop.Ext: a negative upper bound fails the build }
type
  TDateFitsLoopExt = array[0..LOOP_EXT_BYTES - SizeOf(TDateCache)] of Byte;

function LoopDateCache(Loop: TLoop): PDateCache;
begin
  Result := PDateCache(@Loop.Ext[0]);
end;

function LoopDate(Loop: TLoop): PByte;
begin
  { FBytes is the first field of TDateCache }
  Result := @Loop.Ext[0];
end;

{ LoopTickProc: formats the value again if the second changed; the next call
  when the wall clock reaches the next whole second. }
function DateTick(Loop: TLoop): Int64;
var
  C: PDateCache;
  R: Int64;
begin
  C := PDateCache(@Loop.Ext[0]);
  R := RealNowUs;
  C^.Check(R);
  Result := (C^.NextUpdateUs - R) * 1000;
end;

threadvar
  CachedDate: TDateCache;

function UnixTimeMicros: Int64;
var
  TV: TTimeVal;
begin
  fpgettimeofday(@TV, nil);
  Result := Int64(TV.tv_sec) * 1000000 + TV.tv_usec;
end;

const
  WDAYS: array[1..7] of array[0..2] of AnsiChar = ('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun');
  MONS: array[1..12] of array[0..2] of AnsiChar = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');
  MONTH_LENS: array[0..11] of Int64 = (31, 30, 31, 30, 31, 31, 30, 31, 30, 31, 31, 29);

procedure FormatHttpDate(UnixSeconds: Int64; Dst: PByte);
const
  { The calendar arithmetic counts from 2000-03-01 (day 11017 after
    1970-01-01): with years starting on March 1, the leap day is the last
    day of the year, and 400-, 100- and 4-year cycles divide evenly.
    MONTH_LENS lists the months from March to February. }
  LEAPOCH = 11017;               { 2000-03-01 }
  DAYS_PER_400Y = 365 * 400 + 97;
  DAYS_PER_100Y = 365 * 100 + 24;
  DAYS_PER_4Y = 365 * 4 + 1;
  TEMPLATE: array[0..DATE_VALUE_LENGTH - 1] of AnsiChar = '   , 00     0000 00:00:00 GMT';
var
  Days, SecsOfDay, QcCycles, RemDays, CCycles, QCycles, RemYears, Year: Int64;
  Mon, MDay, WDay, I: Int64;
  Hour, Min, Sec: Int64;
begin
  if (UnixSeconds < 0) or (UnixSeconds >= 253402300800) then
    raise ERangeError.Create('date must be between 1970 and year 9999');

  Days := (UnixSeconds div 86400) - LEAPOCH;
  SecsOfDay := UnixSeconds mod 86400;

  QcCycles := Days div DAYS_PER_400Y;
  RemDays := Days mod DAYS_PER_400Y;
  if RemDays < 0 then
  begin
    RemDays := RemDays + DAYS_PER_400Y;
    Dec(QcCycles);
  end;

  CCycles := RemDays div DAYS_PER_100Y;
  if CCycles = 4 then Dec(CCycles);
  RemDays := RemDays - CCycles * DAYS_PER_100Y;

  QCycles := RemDays div DAYS_PER_4Y;
  if QCycles = 25 then Dec(QCycles);
  RemDays := RemDays - QCycles * DAYS_PER_4Y;

  RemYears := RemDays div 365;
  if RemYears = 4 then Dec(RemYears);
  RemDays := RemDays - RemYears * 365;

  Year := 2000 + RemYears + 4 * QCycles + 100 * CCycles + 400 * QcCycles;

  Mon := 0;
  for I := 0 to 11 do
  begin
    Inc(Mon);
    if RemDays < MONTH_LENS[I] then
      Break;
    RemDays := RemDays - MONTH_LENS[I];
  end;
  MDay := RemDays + 1;
  if Mon + 2 > 12 then
  begin
    Inc(Year);
    Mon := Mon - 10;
  end
  else
    Mon := Mon + 2;

  WDay := (3 + Days) mod 7;
  if WDay <= 0 then
    WDay := WDay + 7;

  Hour := SecsOfDay div 3600;
  Min := (SecsOfDay mod 3600) div 60;
  Sec := SecsOfDay mod 60;

  Move(TEMPLATE[0], Dst^, DATE_VALUE_LENGTH);
  Dst[0] := Ord(WDAYS[WDay][0]);
  Dst[1] := Ord(WDAYS[WDay][1]);
  Dst[2] := Ord(WDAYS[WDay][2]);
  Dst[5] := Ord('0') + MDay div 10;
  Dst[6] := Ord('0') + MDay mod 10;
  Dst[8] := Ord(MONS[Mon][0]);
  Dst[9] := Ord(MONS[Mon][1]);
  Dst[10] := Ord(MONS[Mon][2]);
  Dst[12] := Ord('0') + Year div 1000;
  Dst[13] := Ord('0') + (Year div 100) mod 10;
  Dst[14] := Ord('0') + (Year div 10) mod 10;
  Dst[15] := Ord('0') + Year mod 10;
  Dst[17] := Ord('0') + Hour div 10;
  Dst[18] := Ord('0') + Hour mod 10;
  Dst[20] := Ord('0') + Min div 10;
  Dst[21] := Ord('0') + Min mod 10;
  Dst[23] := Ord('0') + Sec div 10;
  Dst[24] := Ord('0') + Sec mod 10;
end;

function FormatHttpDateStr(UnixSeconds: Int64): RawByteString;
begin
  SetLength(Result, DATE_VALUE_LENGTH);
  FormatHttpDate(UnixSeconds, PByte(Pointer(Result)));
end;

{ TDateCache }

procedure TDateCache.Init;
begin
  Update(UnixTimeMicros);
end;

procedure TDateCache.Check;
begin
  Check(UnixTimeMicros);
end;

procedure TDateCache.Check(NowUs: Int64);
begin
  if NowUs > FNextUpdateUs then
    Update(NowUs);
end;

procedure TDateCache.Update(NowUs: Int64);
var
  SubSecUs: Int64;
begin
  FormatHttpDate(NowUs div 1000000, @FBytes[0]);
  SubSecUs := NowUs mod 1000000;
  { the start of the next whole second }
  FNextUpdateUs := NowUs + 1000000 - SubSecUs;
end;

function TDateCache.Buffer: PByte;
begin
  Result := @FBytes[0];
end;

procedure TDateCache.CopyTo(Dst: PByte);
begin
  Move(FBytes[0], Dst^, DATE_VALUE_LENGTH);
end;

function TDateCache.AsString: RawByteString;
begin
  SetLength(Result, DATE_VALUE_LENGTH);
  Move(FBytes[0], Pointer(Result)^, DATE_VALUE_LENGTH);
end;

{ thread-local }

procedure DateUpdate;
begin
  CachedDate.Check(UnixTimeMicros);
end;

function DateBuffer: PByte;
begin
  if CachedDate.FNextUpdateUs = 0 then
    CachedDate.Init;
  Result := @CachedDate.FBytes[0];
end;

procedure DateExtend(Dst: PByte);
begin
  Move(DateBuffer^, Dst^, DATE_VALUE_LENGTH);
end;

initialization
  LoopTickProc := @DateTick;
end.
