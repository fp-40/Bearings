{ bearings.server.accesslog - one line per completed request, written
  without blocking the event loops.

  Formats (TAccessLogFormat). Both have the keys of structlog's lines, so
  the server's lines and a Python app's read the same way.

  alfJson, the default: one JSON object per line: "timestamp" (RFC 3339,
  UTC, microseconds), "level" (see Levels), "logger" (always
  "bearings"), "event" (the method and the path, "GET /x"), "request_id"
  (only when the response has an X-Request-ID header, as an application
  or a proxy behind it sets it to find the request in its own logs),
  "method", "path", "query" (only when the target has one),
  "status", "size" (the body bytes),
  "duration" (seconds, from the request head to the complete response,
  measured with the loop's clock, which is sampled once per loop
  iteration: a request answered in the iteration that read it shows 0),
  "client" (the peer's IP address; "unix" for a Unix domain socket),
  "user_agent" and "referer" (only when the request had the header and
  the log is told to include it).

  alfConsole: one short line for people:
    23:59:59.123456Z [info]  200 GET /x?a=1  (0.412ms; 16.03 KB)
    23:59:59.124001Z [error] 404 GET /nope  (0.051ms; 9.48 KB)
  The time of day (UTC), the level padded to the width of "[error]" so
  that the statuses line up, the status, the method, the request target
  (the path and the query), then the duration in milliseconds and the
  body size in the largest unit it reaches: "164 bytes", "1.60 KB",
  "15.65 MB", "1.53 GB" (1 KB = 1024 bytes, two decimals; GB above). A
  control byte is written as \xXX. The other fields are only in the JSON.
  With Colors, the level has structlog's ANSI color: bright green for
  info, red for error; the rest of the line has none.

  Levels (TLogLevel). A line has the level of its status: "error" for a
  4xx or a 5xx, "info" for the others. TAccessLog.MinLevel drops the
  lines below it, in both formats: llWarning or llError keeps only the
  requests that failed. llDebug, the default, keeps every line.

  The JSON is written by hand: '"', '\' and control bytes are escaped, a
  byte sequence that is not valid UTF-8 is written as \u00XX escapes (as
  \xXX in the console format). Nothing is allocated per line.

  The buffers. Each loop owns a TLogBuffer: two byte areas of BufferBytes
  each. The loop formats a line straight into the active area under a
  spin lock (held for the time of the copy, never across a system call); a
  line that does not fit is dropped and counted in Dropped. The flusher
  thread of the TAccessLog wakes every FlushMs, and at once when a loop
  filled half an area (one wake per area), takes each buffer's lock just long enough to swap
  the two areas, and writes the full one to the sink outside the lock. So
  a slow sink (a full pipe, a slow disk) never stalls a loop: it costs
  dropped lines, which the metrics report.

  The sink. TLogSink.Write receives whole lines (one or many) from the
  flusher thread only. TFdSink writes to a file descriptor, by default 1
  (stdout), where containers, systemd's journal and log agents collect it;
  diagnostic messages of bearings go to stderr. An application gives its
  own sink (a file it rotates, a socket) through TServerConfig.AccessLog.

  Threading: TLogBuffer.Append runs on the buffer's loop thread; Swap,
  Flush and the sink run on the flusher thread (and on the thread that
  calls TAccessLog.Flush or Destroy, after the loops stopped). }
unit bearings.server.accesslog;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  ctypes, bearings.rt.sys, bearings.rt.sync;

type
  TAccessLogFormat = (alfJson, alfConsole);
  { The levels of Python's logging, in order. }
  TLogLevel = (llDebug, llInfo, llWarning, llError, llCritical);

  { Where the lines go. Write gets whole lines; it may block (flusher
    thread). }
  TLogSink = class
  public
    procedure Write(P: PByte; Len: SizeInt); virtual; abstract;
  end;

  { write(2) to a descriptor, in full (short writes and EINTR are retried;
    EAGAIN on a non-blocking descriptor waits a millisecond and retries). }
  TFdSink = class(TLogSink)
  public
    Fd: cint;
    constructor Create(AFd: cint = 1);
    procedure Write(P: PByte; Len: SizeInt); override;
  end;

  { The fields of one request, as pointers into memory the caller holds
    for the duration of Append. }
  TAccessRecord = record
    TimeUs: Int64;                   { wall clock, microseconds since 1970 }
    Peer: PSockAddrStorage;
    Method: PByte;  MethodLen: SizeInt;
    Target: PByte;  TargetLen: SizeInt;   { the request target as received (path and query) }
    Status: Word;
    BodyBytes: QWord;
    DurationNs: Int64;
    UserAgent: PByte;  UserAgentLen: SizeInt;   { nil: none }
    RequestId: PByte;  RequestIdLen: SizeInt;   { the response's X-Request-ID; nil: none }
    Referer: PByte;  RefererLen: SizeInt;       { nil: none }
  end;

  TLogArea = record
    Data: PByte;
    Len: SizeInt;
  end;

  TAccessLog = class;

  { One loop's buffer (see the unit header). }
  TLogBuffer = class
  private
    FLock: TSpinLock;
    FActive, FOther: TLogArea;
    FCap: SizeInt;
    FOwner: TAccessLog;
    FFormat: TAccessLogFormat;
    FColors: Boolean;
    FWoke: Boolean;                  { the flusher was woken for the active area already }
  public
    Dropped: QWord;                  { lines that did not fit (loop thread) }
    constructor Create(AOwner: TAccessLog; ACap: SizeInt; AFormat: TAccessLogFormat; AColors: Boolean);
    destructor Destroy; override;
    { Formats R as one line into the active area (loop thread). }
    procedure Append(const R: TAccessRecord);
    { Flusher thread: swaps the areas and writes what the active one held. }
    procedure Flush(Sink: TLogSink);
  end;

  { The access log of a server: the loops' buffers, the sink and the
    flusher thread. }
  TAccessLog = class
  private
    FBuffers: array of TLogBuffer;
    FSink: TLogSink;
    FOwnsSink: Boolean;
    FFlushMs: Integer;
    FThread: TThreadID;
    FWake: PRTLEvent;
    FQuit: LongInt;
    FRunning: Boolean;
    procedure FlushAll;
  public
    MinLevel: TLogLevel;             { the lines below it are dropped; set before Start }
    { Loops buffers of BufferBytes each; Sink = nil means a TFdSink on stdout (owned). }
    constructor Create(Loops: Integer; BufferBytes: SizeInt; AFormat: TAccessLogFormat;
      AColors: Boolean; Sink: TLogSink; FlushMs: Integer);
    { Stops the flusher thread (after a last flush) and frees the buffers. }
    destructor Destroy; override;
    procedure Start;                 { starts the flusher thread }
    procedure Stop;                  { stops it, after a last flush; the loops must have stopped }
    { Writes every buffer to the sink now (calling thread). }
    procedure Flush;
    function Buffer(LoopIndex: Integer): TLogBuffer;
    function Dropped: QWord;         { every buffer's Dropped added together }
    property Sink: TLogSink read FSink;
  end;

const
  LOG_LEVEL_NAMES: array[TLogLevel] of string = ('debug', 'info', 'warning', 'error', 'critical');

{ The level of a line with this status: llError for a 4xx or a 5xx, llInfo
  for the others. }
function AccessLevel(Status: Word): TLogLevel;

{ Formats R as one line (with the trailing LF) into Dst, at most Cap bytes;
  returns the length, or -1 when it does not fit. Colors: the console
  format's ANSI colors. No allocation. }
function FormatAccessLine(const R: TAccessRecord; Format: TAccessLogFormat; Colors: Boolean;
  Dst: PByte; Cap: SizeInt): SizeInt;

implementation

uses
  SysUtils, BaseUnix, bearings.rt.net;

{ ---- formatting ---- }

type
  { a bounded writer over Dst; Overflow stays True once a write did not fit }
  TLineWriter = record
    P: PByte;
    Len, Cap: SizeInt;
    Overflow: Boolean;
    procedure Byte_(B: Byte); inline;
    procedure Bytes(S: PByte; N: SizeInt);
    procedure Str(const S: RawByteString);
    procedure Dec_(N: QWord);
    procedure Dec2(N: Integer);      { two digits, zero-padded }
    procedure DecN(N: QWord; Digits: Integer);
    procedure Peer(A: PSockAddrStorage);            { the address text: IPv4 directly, IPv6 through SockAddrToStr }
    procedure JsonChars(S: PByte; N: SizeInt);      { escaped, no quotes }
    procedure JsonStr(S: PByte; N: SizeInt);        { with the quotes }
    procedure ConsoleChars(S: PByte; N: SizeInt);   { control bytes as \xXX }
    procedure Size(N: QWord);                       { "164 bytes", "1.64 KB", ... }
  end;

const
  HEX: array[0..15] of AnsiChar = '0123456789abcdef';
  { the level colors of structlog's ConsoleRenderer }
  RESET = #27'[0m';
  BRIGHT = #27'[1m';
  LEVEL_COLORS: array[TLogLevel] of string = (#27'[32m', #27'[32m', #27'[33m', #27'[31m', #27'[31m');

procedure TLineWriter.Byte_(B: Byte);
begin
  if Len < Cap then
  begin
    P[Len] := B;
    Inc(Len);
  end
  else
    Overflow := True;
end;

procedure TLineWriter.Bytes(S: PByte; N: SizeInt);
begin
  if N <= 0 then
    Exit;
  if Len + N > Cap then
  begin
    Overflow := True;
    Exit;
  end;
  Move(S^, P[Len], N);
  Inc(Len, N);
end;

procedure TLineWriter.Str(const S: RawByteString);
begin
  if S <> '' then
    Bytes(PByte(PAnsiChar(S)), Length(S));
end;

procedure TLineWriter.Dec_(N: QWord);
var
  Buf: array[0..20] of Byte;
  I: Integer;
begin
  I := High(Buf);
  repeat
    Buf[I] := Ord('0') + Byte(N mod 10);
    N := N div 10;
    Dec(I);
  until N = 0;
  Bytes(@Buf[I + 1], High(Buf) - I);
end;

procedure TLineWriter.Dec2(N: Integer);
begin
  Byte_(Ord('0') + Byte(N div 10));
  Byte_(Ord('0') + Byte(N mod 10));
end;

procedure TLineWriter.DecN(N: QWord; Digits: Integer);
var
  Buf: array[0..20] of Byte;
  I: Integer;
begin
  for I := Digits - 1 downto 0 do
  begin
    Buf[I] := Ord('0') + Byte(N mod 10);
    N := N div 10;
  end;
  Bytes(@Buf[0], Digits);
end;

procedure TLineWriter.Peer(A: PSockAddrStorage);
var
  B: PByte;
  S: RawByteString;
begin
  if A = nil then
    Exit;
  if A^.Family = AF_UNIX then
    Str('unix')
  else if A^.Family = AF_INET then
  begin
    { sockaddr_in: the address is at offset 4 }
    B := @A^.Data[2];
    Dec_(B[0]);  Byte_(Ord('.'));  Dec_(B[1]);  Byte_(Ord('.'));  Dec_(B[2]);  Byte_(Ord('.'));  Dec_(B[3]);
  end
  else
  begin
    S := SockAddrToStr(A^);          { IPv6: the cold path, with a string }
    Str(S);
  end;
end;

{ the length of the valid UTF-8 sequence starting at S[0] (2..4), or 0 }
function Utf8SeqLen(S: PByte; N: SizeInt): Integer;
var
  B: Byte;
  Need, I: Integer;
  Cp: Cardinal;
begin
  B := S[0];
  if (B and $E0) = $C0 then
  begin
    Need := 2;
    Cp := B and $1F;
  end
  else if (B and $F0) = $E0 then
  begin
    Need := 3;
    Cp := B and $0F;
  end
  else if (B and $F8) = $F0 then
  begin
    Need := 4;
    Cp := B and $07;
  end
  else
    Exit(0);
  if N < Need then
    Exit(0);
  for I := 1 to Need - 1 do
  begin
    if (S[I] and $C0) <> $80 then
      Exit(0);
    Cp := (Cp shl 6) or (S[I] and $3F);
  end;
  { overlong forms, surrogates and values above U+10FFFF are not valid }
  if ((Need = 2) and (Cp < $80)) or ((Need = 3) and (Cp < $800)) or ((Need = 4) and (Cp < $10000))
    or ((Cp >= $D800) and (Cp <= $DFFF)) or (Cp > $10FFFF) then
    Exit(0);
  Result := Need;
end;

procedure TLineWriter.JsonChars(S: PByte; N: SizeInt);
var
  I, L: SizeInt;
  B: Byte;

  procedure U(B: Byte);
  begin
    Str('\u00');
    Byte_(Ord(HEX[B shr 4]));
    Byte_(Ord(HEX[B and 15]));
  end;

begin
  I := 0;
  while I < N do
  begin
    { a run of bytes that need no escape is copied in one move }
    L := I;
    while (L < N) and (S[L] >= $20) and (S[L] < $80) and (S[L] <> Ord('"')) and (S[L] <> Ord('\')) do
      Inc(L);
    if L > I then
    begin
      Bytes(S + I, L - I);
      I := L;
      Continue;
    end;
    B := S[I];
    if B = Ord('"') then
      Str('\"')
    else if B = Ord('\') then
      Str('\\')
    else if B = 10 then
      Str('\n')
    else if B = 13 then
      Str('\r')
    else if B = 9 then
      Str('\t')
    else if B < $20 then
      U(B)
    else
    begin
      L := Utf8SeqLen(S + I, N - I);
      if L = 0 then
        U(B)
      else
      begin
        Bytes(S + I, L);
        Inc(I, L - 1);
      end;
    end;
    Inc(I);
  end;
end;

procedure TLineWriter.JsonStr(S: PByte; N: SizeInt);
begin
  Byte_(Ord('"'));
  JsonChars(S, N);
  Byte_(Ord('"'));
end;

procedure TLineWriter.ConsoleChars(S: PByte; N: SizeInt);
var
  I, L: SizeInt;
  B: Byte;

  procedure X(B: Byte);
  begin
    Str('\x');
    Byte_(Ord(HEX[B shr 4]));
    Byte_(Ord(HEX[B and 15]));
  end;

begin
  I := 0;
  while I < N do
  begin
    B := S[I];
    if (B < $20) or (B = $7F) then
      X(B)
    else if B < $80 then
      Byte_(B)
    else
    begin
      L := Utf8SeqLen(S + I, N - I);
      if L = 0 then
        X(B)
      else
      begin
        Bytes(S + I, L);
        Inc(I, L - 1);
      end;
    end;
    Inc(I);
  end;
end;

procedure TLineWriter.Size(N: QWord);
const
  UNITS: array[1..3] of RawByteString = (' KB', ' MB', ' GB');
var
  U: Integer;
  D, Hundredths: QWord;

  { N in hundredths of D bytes, rounded half up; split so that N * 100
    cannot overflow }
  function InHundredths(D: QWord): QWord;
  begin
    Result := (N div D) * 100 + ((N mod D) * 100 + D div 2) div D;
  end;

begin
  if N < 1024 then
  begin
    Dec_(N);
    if N = 1 then
      Str(' byte')
    else
      Str(' bytes');
    Exit;
  end;
  { a value that rounds to 1024.00 of a unit is 1.00 of the next one }
  U := 1;
  D := 1024;
  Hundredths := InHundredths(D);
  while (U < High(UNITS)) and (Hundredths >= 102400) do
  begin
    Inc(U);
    D := D * 1024;
    Hundredths := InHundredths(D);
  end;
  Dec_(Hundredths div 100);
  Byte_(Ord('.'));
  Dec2(Integer(Hundredths mod 100));
  Str(UNITS[U]);
end;

{ days since 1970-01-01 to a civil date (proleptic Gregorian); the usual
  integer algorithm of Howard Hinnant }
procedure CivilFromDays(Z: Int64; out Y: Int64; out M, D: Integer);
var
  Era, Doe, Yoe, Doy, Mp: Int64;
begin
  Z := Z + 719468;
  if Z >= 0 then
    Era := Z div 146097
  else
    Era := (Z - 146096) div 146097;
  Doe := Z - Era * 146097;
  Yoe := (Doe - Doe div 1460 + Doe div 36524 - Doe div 146096) div 365;
  Y := Yoe + Era * 400;
  Doy := Doe - (365 * Yoe + Yoe div 4 - Yoe div 100);
  Mp := (5 * Doy + 2) div 153;
  D := Integer(Doy - (153 * Mp + 2) div 5 + 1);
  if Mp < 10 then
    M := Integer(Mp + 3)
  else
    M := Integer(Mp - 9);
  if M <= 2 then
    Inc(Y);
end;

procedure SplitTime(TimeUs: Int64; out Y: Int64; out Mo, D, H, Mi, S, Us: Integer);
var
  Secs, Days, Rem: Int64;
begin
  Secs := TimeUs div 1000000;
  Us := Integer(TimeUs mod 1000000);
  Days := Secs div 86400;
  Rem := Secs mod 86400;
  CivilFromDays(Days, Y, Mo, D);
  H := Integer(Rem div 3600);
  Mi := Integer((Rem mod 3600) div 60);
  S := Integer(Rem mod 60);
end;

function AccessLevel(Status: Word): TLogLevel;
begin
  if Status >= 400 then
    Result := llError
  else
    Result := llInfo;
end;

function FormatAccessLine(const R: TAccessRecord; Format: TAccessLogFormat; Colors: Boolean;
  Dst: PByte; Cap: SizeInt): SizeInt;
var
  W: TLineWriter;
  Y: Int64;
  Mo, D, H, Mi, S, Us: Integer;
  Q: SizeInt;
  Ns: QWord;
  Level: TLogLevel;
  I: Integer;


  procedure Timestamp;
  begin
    W.DecN(QWord(Y), 4);  W.Byte_(Ord('-'));  W.Dec2(Mo);  W.Byte_(Ord('-'));  W.Dec2(D);
    W.Byte_(Ord('T'));  W.Dec2(H);  W.Byte_(Ord(':'));  W.Dec2(Mi);  W.Byte_(Ord(':'));  W.Dec2(S);
    W.Byte_(Ord('.'));  W.DecN(QWord(Us), 6);  W.Byte_(Ord('Z'));
  end;

  procedure Duration;
  begin
    W.Dec_(Ns div 1000000000);
    W.Byte_(Ord('.'));
    W.DecN((Ns mod 1000000000) div 1000, 6);
  end;

begin
  W.P := Dst;
  W.Len := 0;
  W.Cap := Cap;
  W.Overflow := False;
  SplitTime(R.TimeUs, Y, Mo, D, H, Mi, S, Us);
  if R.DurationNs > 0 then
    Ns := QWord(R.DurationNs)
  else
    Ns := 0;
  { the query starts at the first '?' of the target }
  Q := 0;
  while (Q < R.TargetLen) and (R.Target[Q] <> Ord('?')) do
    Inc(Q);
  Level := AccessLevel(R.Status);
  case Format of
    alfJson:
      begin
        W.Str('{"timestamp":"');
        Timestamp;
        W.Str('","level":"');
        W.Str(LOG_LEVEL_NAMES[Level]);
        W.Str('","logger":"bearings","event":"');
        W.JsonChars(R.Method, R.MethodLen);
        W.Byte_(Ord(' '));
        W.JsonChars(R.Target, Q);
        W.Byte_(Ord('"'));
        if R.RequestId <> nil then
        begin
          W.Str(',"request_id":');
          W.JsonStr(R.RequestId, R.RequestIdLen);
        end;
        W.Str(',"method":');
        W.JsonStr(R.Method, R.MethodLen);
        W.Str(',"path":');
        W.JsonStr(R.Target, Q);
        if Q < R.TargetLen then
        begin
          W.Str(',"query":');
          W.JsonStr(R.Target + Q + 1, R.TargetLen - Q - 1);
        end;
        W.Str(',"status":');
        W.Dec_(R.Status);
        W.Str(',"size":');
        W.Dec_(R.BodyBytes);
        W.Str(',"duration":');
        Duration;
        W.Str(',"client":"');
        W.Peer(R.Peer);                { digits, dots, hex and colons: nothing to escape }
        W.Byte_(Ord('"'));
        if R.UserAgent <> nil then
        begin
          W.Str(',"user_agent":');
          W.JsonStr(R.UserAgent, R.UserAgentLen);
        end;
        if R.Referer <> nil then
        begin
          W.Str(',"referer":');
          W.JsonStr(R.Referer, R.RefererLen);
        end;
        W.Str('}'#10);
      end;
    alfConsole:
      begin
        { the time of day: the date is the same for many lines }
        W.Dec2(H);  W.Byte_(Ord(':'));  W.Dec2(Mi);  W.Byte_(Ord(':'));  W.Dec2(S);
        W.Byte_(Ord('.'));  W.DecN(QWord(Us), 6);  W.Byte_(Ord('Z'));
        W.Str(' [');
        if Colors then
        begin
          W.Str(LEVEL_COLORS[Level]);
          W.Str(BRIGHT);
        end;
        W.Str(LOG_LEVEL_NAMES[Level]);
        if Colors then
          W.Str(RESET);
        W.Byte_(Ord(']'));
        { padded to the width of "[error]", so that the statuses line up }
        for I := Length(LOG_LEVEL_NAMES[Level]) to 5 do
          W.Byte_(Ord(' '));
        if Length(LOG_LEVEL_NAMES[Level]) > 5 then
          W.Byte_(Ord(' '));
        W.Dec_(R.Status);
        W.Byte_(Ord(' '));
        W.ConsoleChars(R.Method, R.MethodLen);
        W.Byte_(Ord(' '));
        W.ConsoleChars(R.Target, R.TargetLen);
        { milliseconds, for people: 0.412ms }
        W.Str('  (');
        W.Dec_(Ns div 1000000);
        W.Byte_(Ord('.'));
        W.DecN((Ns mod 1000000) div 1000, 3);
        W.Str('ms; ');
        W.Size(R.BodyBytes);
        W.Str(')'#10);
      end;
  end;
  if W.Overflow then
    Result := -1
  else
    Result := W.Len;
end;

{ ---- TFdSink ---- }

constructor TFdSink.Create(AFd: cint);
begin
  inherited Create;
  Fd := AFd;
end;

procedure TFdSink.Write(P: PByte; Len: SizeInt);
var
  R: SizeInt;
begin
  while Len > 0 do
  begin
    R := SysWrite(Fd, P, SizeUInt(Len));
    if R > 0 then
    begin
      Inc(P, R);
      Dec(Len, R);
    end
    else if R = -ESysEAGAIN then
      Sleep(1)
    else if R <> -ESysEINTR then
      Exit;                          { a closed pipe, a bad descriptor: the lines are lost }
  end;
end;

{ ---- TLogBuffer ---- }

constructor TLogBuffer.Create(AOwner: TAccessLog; ACap: SizeInt; AFormat: TAccessLogFormat;
  AColors: Boolean);
begin
  inherited Create;
  FOwner := AOwner;
  FCap := ACap;
  FFormat := AFormat;
  FColors := AColors;
  FActive.Data := GetMem(ACap);
  FOther.Data := GetMem(ACap);
end;

destructor TLogBuffer.Destroy;
begin
  FreeMem(FActive.Data);
  FreeMem(FOther.Data);
  inherited Destroy;
end;

procedure TLogBuffer.Append(const R: TAccessRecord);
var
  N: SizeInt;
  Half: Boolean;
begin
  if (FOwner <> nil) and (AccessLevel(R.Status) < FOwner.MinLevel) then
    Exit;
  FLock.Acquire;
  N := FormatAccessLine(R, FFormat, FColors, FActive.Data + FActive.Len, FCap - FActive.Len);
  if N >= 0 then
    Inc(FActive.Len, N);
  { the flusher is woken once per area, by the line that fills it to the
    half (the wake is a system call) }
  Half := (FActive.Len >= FCap div 2) and not FWoke;
  if Half then
    FWoke := True;
  FLock.Release;
  if N < 0 then
    Inc(Dropped)
  else if Half and (FOwner <> nil) and (FOwner.FWake <> nil) then
    RTLEventSetEvent(FOwner.FWake);  { the flusher should come early }
end;

procedure TLogBuffer.Flush(Sink: TLogSink);
var
  Full: TLogArea;
begin
  FLock.Acquire;
  Full := FActive;
  FActive := FOther;
  FActive.Len := 0;
  FOther := Full;
  FWoke := False;
  FLock.Release;
  if (Full.Len > 0) and (Sink <> nil) then
    Sink.Write(Full.Data, Full.Len);
end;

{ ---- TAccessLog ---- }

function FlusherMain(Arg: Pointer): PtrInt;
var
  L: TAccessLog;
begin
  L := TAccessLog(Arg);
  while AtomicLoad(L.FQuit) = 0 do
  begin
    RTLEventWaitFor(L.FWake, L.FFlushMs);
    RTLEventResetEvent(L.FWake);
    L.FlushAll;
  end;
  Result := 0;
end;

constructor TAccessLog.Create(Loops: Integer; BufferBytes: SizeInt; AFormat: TAccessLogFormat;
  AColors: Boolean; Sink: TLogSink; FlushMs: Integer);
var
  I: Integer;
begin
  inherited Create;
  if BufferBytes < 4096 then
    BufferBytes := 65536;
  if FlushMs <= 0 then
    FlushMs := 100;
  FFlushMs := FlushMs;
  if Sink = nil then
  begin
    FSink := TFdSink.Create(1);
    FOwnsSink := True;
  end
  else
    FSink := Sink;
  FWake := RTLEventCreate;
  SetLength(FBuffers, Loops);
  for I := 0 to Loops - 1 do
    FBuffers[I] := TLogBuffer.Create(Self, BufferBytes, AFormat, AColors);
end;

destructor TAccessLog.Destroy;
var
  I: Integer;
begin
  Stop;
  for I := 0 to High(FBuffers) do
    FBuffers[I].Free;
  if FOwnsSink then
    FSink.Free;
  if FWake <> nil then
    RTLEventDestroy(FWake);
  inherited Destroy;
end;

procedure TAccessLog.Start;
begin
  if FRunning then
    Exit;
  AtomicStore(FQuit, 0);
  FRunning := True;
  FThread := BeginThread(@FlusherMain, Pointer(Self));
end;

procedure TAccessLog.Stop;
begin
  if FRunning then
  begin
    AtomicStore(FQuit, 1);
    RTLEventSetEvent(FWake);
    WaitForThreadTerminate(FThread, 0);
    CloseThread(FThread);
    FRunning := False;
  end;
  FlushAll;
end;

procedure TAccessLog.FlushAll;
var
  I: Integer;
begin
  for I := 0 to High(FBuffers) do
    FBuffers[I].Flush(FSink);
end;

procedure TAccessLog.Flush;
begin
  FlushAll;
end;

function TAccessLog.Buffer(LoopIndex: Integer): TLogBuffer;
begin
  Result := FBuffers[LoopIndex];
end;

function TAccessLog.Dropped: QWord;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FBuffers) do
    Inc(Result, FBuffers[I].Dropped);
end;

end.
