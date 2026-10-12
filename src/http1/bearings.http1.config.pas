{ bearings.http1.config - the options of an HTTP/1.1 connection, the two preset
  profiles, validation, and applying the options to a TH1Conn.

  Main types:
  - TH1Config: every option of one HTTP/1.1 connection (keep-alive, header
    limits, read buffer limit, timeouts, write batching, parser leniency,
    upgrade handling).
  - TH1ConnMode: how the dispatcher (bearings.http1.dispatch) ends a connection.
  - TTimeoutSetting: the three states of the header read timeout option.

  Use: the server builds a TH1Config once (usually from ProductionH1Config
  or ConformanceH1Config, then changes some fields), checks it with
  ValidateH1Config, and calls ApplyH1Config on the TH1Conn of every accepted
  connection. ApplyH1Config must run before the connection reads anything.

  HeaderReadTimeout has three states:
  - tsDefault: a 30 s limit when the connection has a timer (Timer = True);
    no limit without a timer.
  - tsDisabled: no limit.
  - tsMs: a limit of HeaderReadTimeoutMs; requires a timer
    (ValidateH1Config rejects it otherwise).
  The header read timeout limits how long a client may take to send a
  complete request head. Without it, a client that sends a few bytes and
  then stops keeps the connection (and its buffer) open forever.

  BodyReadTimeoutMs and BodyMinRate are the request body rate rule of
  TH1Conn (bearings.http1.conn): a body read may wait at most BodyReadTimeoutMs
  for a byte, and after that much waiting the client must have sent at
  least BodyMinRate bytes per second. They are off (0) in
  ConformanceH1Config and 30 s / 1 KiB/s in ProductionH1Config. They
  need the timer.

  This unit uses bearings.http1.conn (ApplyH1Config takes a TH1Conn);
  bearings.http1.conn does not use this unit.

  Threading: plain values; ApplyH1Config runs on the thread that owns the
  connection, before the connection starts. }
unit bearings.http1.config;

{$mode objfpc}{$H+}

interface

uses
  bearings.http1.parser, bearings.http1.role, bearings.http1.conn;

type
  { How the dispatcher ends the connection:
    - cmPlain: upgrades are not handed over. After a 101 Switching
      Protocols response the upgrade handler is told that the upgrade
      failed, and the connection ends.
    - cmWithUpgrades: after a 101 response the socket and the bytes read
      but not yet parsed are handed to the upgrade handler (for example a
      WebSocket handler).
    - cmWithoutShutdown: like cmPlain for upgrades, but when the HTTP
      connection ends the dispatcher gives the socket and the unparsed
      bytes back to the caller instead of closing the socket. }
  TH1ConnMode = (cmPlain, cmWithUpgrades, cmWithoutShutdown);
  TTimeoutSetting = (tsDefault, tsDisabled, tsMs);          { absent / null / number }

  { The defaults named below are those of ConformanceH1Config. }
  TH1Config = record
    { True: the connection serves more requests after the first one
      (HTTP/1.1 keep-alive). False: it closes after one response. }
    KeepAlive: Boolean;                { True }
    { True: when the client closes its sending side (read EOF), the server
      still finishes the response in progress. False: EOF in the middle of
      a request/response is an error and closes the connection. }
    HalfClose: Boolean;                { False }
    { Response header names are written in lowercase ("content-type").
      True: they are written in title case ("Content-Type"), for old
      clients that compare names case-sensitively. }
    TitleCaseHeaders: Boolean;         { False }
    { Accepted and ignored. Request header names are always kept as
      received (THttpHeaders); response header names follow
      TitleCaseHeaders. }
    PreserveHeaderCase: Boolean;       { False }
    { The most header fields a request head may have; more gives
      431 Request Header Fields Too Large. -1: the default, 100. }
    MaxHeaders: Integer;
    { The most bytes a request head may have; more gives 431. -1: no own
      limit, the head is limited only by MaxBufSize. }
    MaxHeaderSize: SizeInt;
    { The largest the read buffer may grow (bearings.http1.io). A request head
      must fit in it. -1: DEFAULT_MAX_BUFFER_SIZE (about 400 KiB); the
      minimum is 8192. }
    MaxBufSize: SizeInt;
    { True: the connection may arm timers on its loop. Timeouts need it. }
    Timer: Boolean;
    HeaderReadTimeout: TTimeoutSetting;
    HeaderReadTimeoutMs: Int64;        { used when HeaderReadTimeout = tsMs }
    { True: while the read buffer still holds a pipelined request (the
      client sent several requests without waiting), the response is kept
      in the write buffer instead of being written at once, so that the
      responses of several requests leave in one write(2)/writev(2). }
    PipelineFlush: Boolean;
    { True: every response gets a Date header (bearings.http.date) unless the
      application set one. }
    AutoDateHeader: Boolean;           { True }
    BodyReadTimeoutMs: Int64;          { 0 = off; the longest wait for one body byte }
    BodyMinRate: Int64;                { bytes/s required after BodyReadTimeoutMs of waiting; 0 = off }
    { Leniency switches of the head parser (bearings.http1.parser). }
    Parser: TParserConfig;
    Mode: TH1ConnMode;
  end;

{ The base defaults: keep-alive on, no timer (so no timeouts), no pipeline
  batching, upgrades not handed over (cmPlain), the body rate rule off.
  The conformance server uses this profile. }
function ConformanceH1Config: TH1Config;
{ The profile for production: the base defaults plus a timer with the 30 s
  header read timeout, PipelineFlush, cmWithUpgrades and the body rate
  rule (30 s, 1 KiB/s). }
function ProductionH1Config: TH1Config;
{ False with a message in Msg for an invalid combination: MaxBufSize below
  8192, a tsMs header timeout or a body timeout without a timer, negative
  timeouts or rates, BodyMinRate without BodyReadTimeoutMs. A tsDefault
  header timeout without a timer is valid and means no timeout. }
function ValidateH1Config(const C: TH1Config; out Msg: string): Boolean;
{ Applies every option to a newly initialized TH1Conn that has not read
  anything yet. C must have passed ValidateH1Config. }
procedure ApplyH1Config(const C: TH1Config; var Conn: TH1Conn);

implementation

const
  DEFAULT_HEADER_READ_TIMEOUT_MS = 30000;
  { the production profile's body rate rule }
  PRODUCTION_BODY_READ_TIMEOUT_MS = 30000;
  PRODUCTION_BODY_MIN_RATE = 1024;
  { the smallest allowed MaxBufSize (MINIMUM_MAX_BUFFER_SIZE in bearings.http1.io) }
  MIN_MAX_BUF_SIZE = 8192;

{ an integer as decimal text, for the messages of ValidateH1Config }
function IntText(V: Int64): string;
begin
  Str(V, Result);
end;

function ConformanceH1Config: TH1Config;
begin
  Result := Default(TH1Config);
  Result.KeepAlive := True;
  Result.HalfClose := False;
  Result.TitleCaseHeaders := False;
  Result.PreserveHeaderCase := False;
  Result.MaxHeaders := -1;
  Result.MaxHeaderSize := -1;
  Result.MaxBufSize := -1;
  Result.Timer := False;
  Result.HeaderReadTimeout := tsDefault;
  Result.HeaderReadTimeoutMs := DEFAULT_HEADER_READ_TIMEOUT_MS;
  Result.PipelineFlush := False;
  Result.AutoDateHeader := True;
  Result.BodyReadTimeoutMs := 0;
  Result.BodyMinRate := 0;
  Result.Parser := DefaultParserConfig;
  Result.Mode := cmPlain;
end;

function ProductionH1Config: TH1Config;
begin
  { a timer with the 30 s default header read timeout, pipeline batching
    on, upgrades handed over }
  Result := ConformanceH1Config;
  Result.Timer := True;
  Result.HeaderReadTimeout := tsDefault;
  Result.PipelineFlush := True;
  Result.Mode := cmWithUpgrades;
  Result.BodyReadTimeoutMs := PRODUCTION_BODY_READ_TIMEOUT_MS;
  Result.BodyMinRate := PRODUCTION_BODY_MIN_RATE;
end;

function ValidateH1Config(const C: TH1Config; out Msg: string): Boolean;
begin
  Msg := '';
  { the read buffer must at least hold its initial 8 KiB }
  if (C.MaxBufSize >= 0) and (C.MaxBufSize < MIN_MAX_BUF_SIZE) then
  begin
    Msg := 'TH1Config.MaxBufSize (' + IntText(C.MaxBufSize) + ') is below the minimum (' +
      IntText(MIN_MAX_BUF_SIZE) + ')';
    Exit(False);
  end;
  { an explicit timeout cannot work without a timer }
  if (C.HeaderReadTimeout = tsMs) and not C.Timer then
  begin
    Msg := 'TH1Config.HeaderReadTimeout is tsMs, which needs TH1Config.Timer, and Timer is False';
    Exit(False);
  end;
  if (C.HeaderReadTimeout = tsMs) and (C.HeaderReadTimeoutMs < 0) then
  begin
    Msg := 'TH1Config.HeaderReadTimeoutMs (' + IntText(C.HeaderReadTimeoutMs) + ') is negative';
    Exit(False);
  end;
  { the body rate rule runs on the loop's timer }
  if (C.BodyReadTimeoutMs < 0) or (C.BodyMinRate < 0) then
  begin
    Msg := 'TH1Config.BodyReadTimeoutMs (' + IntText(C.BodyReadTimeoutMs) + ') and TH1Config.BodyMinRate (' +
      IntText(C.BodyMinRate) + ') must be 0 or more';
    Exit(False);
  end;
  if (C.BodyReadTimeoutMs > 0) and not C.Timer then
  begin
    Msg := 'TH1Config.BodyReadTimeoutMs is set, which needs TH1Config.Timer, and Timer is False';
    Exit(False);
  end;
  if (C.BodyMinRate > 0) and (C.BodyReadTimeoutMs = 0) then
  begin
    Msg := 'TH1Config.BodyMinRate is set, which needs TH1Config.BodyReadTimeoutMs, and BodyReadTimeoutMs is 0';
    Exit(False);
  end;
  Result := True;
end;

procedure ApplyH1Config(const C: TH1Config; var Conn: TH1Conn);
begin
  Conn.SetParserConfig(C.Parser);
  if not C.KeepAlive then
    Conn.DisableKeepAlive;
  if C.HalfClose then
    Conn.SetAllowHalfClose;
  if C.TitleCaseHeaders then
    Conn.SetTitleCaseHeaders;
  { PreserveHeaderCase: ignored (see TH1Config) }
  if C.MaxHeaders >= 0 then
    Conn.SetMaxHeaders(C.MaxHeaders);
  if C.MaxHeaderSize >= 0 then
    Conn.SetMaxHeaderSize(C.MaxHeaderSize);
  case C.HeaderReadTimeout of
    tsDefault:
      if C.Timer then
        Conn.SetHeaderReadTimeout(DEFAULT_HEADER_READ_TIMEOUT_MS);
      { else: no timer, so no header timeout }
    tsMs:
      begin
        Assert(C.Timer, 'TH1Config.HeaderReadTimeout is tsMs without TH1Config.Timer (ValidateH1Config rejects this)');
        if C.Timer then
          Conn.SetHeaderReadTimeout(C.HeaderReadTimeoutMs);
      end;
  else
    { tsDisabled: no header timeout }
  end;
  Conn.SetFlushPipeline(C.PipelineFlush);
  if C.MaxBufSize >= 0 then
    Conn.SetMaxBufSize(C.MaxBufSize);
  if not C.AutoDateHeader then
    Conn.DisableDateHeader;
  if C.Timer and (C.BodyReadTimeoutMs > 0) then
    Conn.SetBodyReadTimeout(C.BodyReadTimeoutMs, C.BodyMinRate);
end;

end.
