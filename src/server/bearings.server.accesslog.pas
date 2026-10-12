{ bearings.server.accesslog - one line per completed request, written
  without blocking the event loops.

  Formats (TAccessLogFormat). alfJson, the default: one JSON object per
  line with the field names of the OpenTelemetry semantic conventions for
  HTTP: "time" (RFC 3339, UTC, milliseconds), "client.address" (the peer's
  IP address; "unix" for a Unix domain socket), "http.request.method",
  "url.path", "url.query" (only when the target has one),
  "network.protocol.version" ("1.0" or "1.1"), "http.response.status_code",
  "http.response.body.size", "http.server.request.duration" (seconds, from
  the request head to the complete response, measured with the loop's
  clock, which is sampled once per loop iteration: a request answered in
  the iteration that read it shows 0) and "user_agent.original"
  (only when the request had a User-Agent header and the log is told to
  include it). alfCombined: the Combined Log Format of classic log tools,
    host - - [11/Oct/2026:23:59:59 +0000] "GET /x HTTP/1.1" 200 5 "referer" "agent"
  The JSON is written by hand: '"', '\' and control bytes are escaped, a
  byte sequence that is not valid UTF-8 is written as \u00XX escapes. The
  Combined format escapes '"' and '\' with a backslash and control bytes as
  \xXX. Nothing is allocated per line.

  The buffers. Each loop owns a TLogBuffer: two byte areas of BufferBytes
  each. The loop formats a line straight into the active area under a
  spin lock (held for the time of the copy, never across a system call); a
  line that does not fit is dropped and counted in Dropped. The flusher
  thread of the TAccessLog wakes every FlushMs, and at once when a loop
  filled half an area, takes each buffer's lock just long enough to swap
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
  ctypes, bearings.rt.sys, bearings.rt.sync, bearings.http1.role;

type
  TAccessLogFormat = (alfJson, alfCombined);

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
    Version: THttpVersion;
    Status: Word;
    BodyBytes: QWord;
    DurationNs: Int64;
    UserAgent: PByte;  UserAgentLen: SizeInt;   { nil: none }
    Referer: PByte;  RefererLen: SizeInt;       { nil: none (Combined only) }
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
    FUserAgent: Boolean;
  public
    Dropped: QWord;                  { lines that did not fit (loop thread) }
    constructor Create(AOwner: TAccessLog; ACap: SizeInt; AFormat: TAccessLogFormat; AUserAgent: Boolean);
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
    { Loops buffers of BufferBytes each; Sink = nil means a TFdSink on stdout (owned). }
    constructor Create(Loops: Integer; BufferBytes: SizeInt; AFormat: TAccessLogFormat;
      AUserAgent: Boolean; Sink: TLogSink; FlushMs: Integer);
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

{ Formats R as one line (with the trailing LF) into Dst, at most Cap bytes;
  returns the length, or -1 when it does not fit. No allocation. }
function FormatAccessLine(const R: TAccessRecord; Format: TAccessLogFormat; UserAgent: Boolean;
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
    procedure JsonStr(S: PByte; N: SizeInt);        { with the quotes }
    procedure Escaped(S: PByte; N: SizeInt);        { Combined format escapes, no quotes }
    procedure QuotedStr(S: PByte; N: SizeInt);      { Combined format, with the quotes }
  end;

const
  HEX: array[0..15] of AnsiChar = '0123456789abcdef';
  MONTHS: array[1..12] of RawByteString = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug',
    'Sep', 'Oct', 'Nov', 'Dec');

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

procedure TLineWriter.JsonStr(S: PByte; N: SizeInt);
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
  Byte_(Ord('"'));
  I := 0;
  while I < N do
  begin
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
    else if B < $80 then
      Byte_(B)
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
  Byte_(Ord('"'));
end;

procedure TLineWriter.QuotedStr(S: PByte; N: SizeInt);
begin
  Byte_(Ord('"'));
  Escaped(S, N);
  Byte_(Ord('"'));
end;

procedure TLineWriter.Escaped(S: PByte; N: SizeInt);
var
  I: SizeInt;
  B: Byte;
begin
  for I := 0 to N - 1 do
  begin
    B := S[I];
    if (B = Ord('"')) or (B = Ord('\')) then
    begin
      Byte_(Ord('\'));
      Byte_(B);
    end
    else if (B < $20) or (B = $7F) then
    begin
      Str('\x');
      Byte_(Ord(HEX[B shr 4]));
      Byte_(Ord(HEX[B and 15]));
    end
    else
      Byte_(B);
  end;
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

procedure SplitTime(TimeUs: Int64; out Y: Int64; out Mo, D, H, Mi, S, Ms: Integer);
var
  Secs, Days, Rem: Int64;
begin
  Secs := TimeUs div 1000000;
  Ms := Integer((TimeUs mod 1000000) div 1000);
  Days := Secs div 86400;
  Rem := Secs mod 86400;
  CivilFromDays(Days, Y, Mo, D);
  H := Integer(Rem div 3600);
  Mi := Integer((Rem mod 3600) div 60);
  S := Integer(Rem mod 60);
end;

{ "1.1", "1.0", "0.9", "2", "3" }
function VersionText(V: THttpVersion): RawByteString;
begin
  case V of
    hv09: Result := '0.9';
    hv10: Result := '1.0';
    hv2: Result := '2';
    hv3: Result := '3';
  else
    Result := '1.1';
  end;
end;

function FormatAccessLine(const R: TAccessRecord; Format: TAccessLogFormat; UserAgent: Boolean;
  Dst: PByte; Cap: SizeInt): SizeInt;
var
  W: TLineWriter;
  Y: Int64;
  Mo, D, H, Mi, S, Ms: Integer;
  Q: SizeInt;
  Peer: RawByteString;
  Ns: QWord;
begin
  W.P := Dst;
  W.Len := 0;
  W.Cap := Cap;
  W.Overflow := False;
  SplitTime(R.TimeUs, Y, Mo, D, H, Mi, S, Ms);
  if (R.Peer <> nil) and (R.Peer^.Family = AF_UNIX) then
    Peer := 'unix'
  else if R.Peer <> nil then
    Peer := SockAddrToStr(R.Peer^)
  else
    Peer := '';
  if R.DurationNs > 0 then
    Ns := QWord(R.DurationNs)
  else
    Ns := 0;
  { the query starts at the first '?' of the target }
  Q := 0;
  while (Q < R.TargetLen) and (R.Target[Q] <> Ord('?')) do
    Inc(Q);
  case Format of
    alfJson:
      begin
        W.Str('{"time":"');
        W.DecN(QWord(Y), 4);  W.Byte_(Ord('-'));  W.Dec2(Mo);  W.Byte_(Ord('-'));  W.Dec2(D);
        W.Byte_(Ord('T'));  W.Dec2(H);  W.Byte_(Ord(':'));  W.Dec2(Mi);  W.Byte_(Ord(':'));  W.Dec2(S);
        W.Byte_(Ord('.'));  W.DecN(QWord(Ms), 3);  W.Str('Z","client.address":');
        W.JsonStr(PByte(PAnsiChar(Peer)), Length(Peer));
        W.Str(',"http.request.method":');
        W.JsonStr(R.Method, R.MethodLen);
        W.Str(',"url.path":');
        W.JsonStr(R.Target, Q);
        if Q < R.TargetLen then
        begin
          W.Str(',"url.query":');
          W.JsonStr(R.Target + Q + 1, R.TargetLen - Q - 1);
        end;
        W.Str(',"network.protocol.version":"');
        W.Str(VersionText(R.Version));
        W.Str('","http.response.status_code":');
        W.Dec_(R.Status);
        W.Str(',"http.response.body.size":');
        W.Dec_(R.BodyBytes);
        W.Str(',"http.server.request.duration":');
        W.Dec_(Ns div 1000000000);
        W.Byte_(Ord('.'));
        W.DecN((Ns mod 1000000000) div 1000, 6);
        if UserAgent and (R.UserAgent <> nil) then
        begin
          W.Str(',"user_agent.original":');
          W.JsonStr(R.UserAgent, R.UserAgentLen);
        end;
        W.Str('}'#10);
      end;
    alfCombined:
      begin
        if Peer = '' then
          W.Byte_(Ord('-'))
        else
          W.Str(Peer);
        W.Str(' - - [');
        W.Dec2(D);  W.Byte_(Ord('/'));  W.Str(MONTHS[Mo]);  W.Byte_(Ord('/'));  W.DecN(QWord(Y), 4);
        W.Byte_(Ord(':'));  W.Dec2(H);  W.Byte_(Ord(':'));  W.Dec2(Mi);  W.Byte_(Ord(':'));  W.Dec2(S);
        W.Str(' +0000] "');
        { the request line, escaped, inside one pair of quotes }
        W.Escaped(R.Method, R.MethodLen);
        W.Byte_(Ord(' '));
        W.Escaped(R.Target, R.TargetLen);
        W.Str(' HTTP/');
        W.Str(VersionText(R.Version));
        W.Str('" ');
        W.Dec_(R.Status);
        W.Byte_(Ord(' '));
        W.Dec_(R.BodyBytes);
        W.Byte_(Ord(' '));
        if R.Referer <> nil then
          W.QuotedStr(R.Referer, R.RefererLen)
        else
          W.Str('"-"');
        W.Byte_(Ord(' '));
        if UserAgent and (R.UserAgent <> nil) then
          W.QuotedStr(R.UserAgent, R.UserAgentLen)
        else
          W.Str('"-"');
        W.Byte_(10);
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
  AUserAgent: Boolean);
begin
  inherited Create;
  FOwner := AOwner;
  FCap := ACap;
  FFormat := AFormat;
  FUserAgent := AUserAgent;
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
  FLock.Acquire;
  N := FormatAccessLine(R, FFormat, FUserAgent, FActive.Data + FActive.Len, FCap - FActive.Len);
  if N >= 0 then
    Inc(FActive.Len, N);
  Half := FActive.Len >= FCap div 2;
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
  AUserAgent: Boolean; Sink: TLogSink; FlushMs: Integer);
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
    FBuffers[I] := TLogBuffer.Create(Self, BufferBytes, AFormat, AUserAgent);
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
