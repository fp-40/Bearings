{ bearings.server.metrics - the server's counters and their Prometheus text.

  What is counted. Each event loop keeps its own TLoopMetrics and is the
  only writer of it, so counting a request costs a few plain additions and
  no atomic operation. A reader (TServer.Metrics in bearings.server) asks
  every loop for a copy of its record on the loop's own thread and adds the
  copies together with MetricsAdd. The counters are HTTP-level: a request is
  counted when its head was parsed, a response when its last bytes were
  handed to the write buffer (its status, its body size and the time since
  the head was read, by the loop's clock, which is sampled once per loop
  iteration: a request answered in the iteration that read it counts as 0),
  a connection when it closed (by outcome). Request and
  response bytes are the HTTP bytes (heads and bodies), not what the
  socket moved. The gauges (open connections, requests in flight, worker
  queue, pooled buffer bytes) are read at snapshot time.

  Latency histogram. Fixed buckets at powers of two in microseconds: bucket
  K counts the requests that took at most 2^K microseconds (K = 0 ..
  LATENCY_BUCKETS - 1: 1 us to about 8.4 s); the last entry counts the rest.
  LatencyBucket finds the bucket of one duration; the export writes the
  buckets cumulative, as Prometheus wants them.

  Prometheus. MetricsToPrometheus turns a snapshot into the text exposition
  format: a "# HELP" and a "# TYPE" line per metric, metric names with the
  prefix bearings_, labels with fixed small value sets (outcome, status
  class, reason), the histogram as cumulative _bucket lines (one per le value) plus
  _sum and _count. It does no I/O; serving it at an HTTP path such as
  /metrics is the application's job.

  Threading: TLoopMetrics is written on its loop thread only; the routines
  here have no shared state. }
unit bearings.server.metrics;

{$mode objfpc}{$H+}

interface

uses
  bearings.http.error;

const
  LATENCY_BUCKETS = 24;              { 2^0 .. 2^23 microseconds, then everything above }

type
  TStatusClass = (sc1xx, sc2xx, sc3xx, sc4xx, sc5xx, scOther);

  { One loop's counters and the gauges read for it at snapshot time. No
    managed fields: a plain record copy takes a snapshot. }
  TLoopMetrics = record
    { counters (the loop adds to them) }
    ConnectionsClosed: array[TConnOutcome] of QWord;
    Requests: QWord;
    Responses: array[TStatusClass] of QWord;
    RequestBytes: QWord;             { request heads and bodies }
    ResponseBytes: QWord;            { response heads and bodies }
    Latency: array[0..LATENCY_BUCKETS] of QWord;   { per bucket (not cumulative) }
    LatencySumNs: QWord;
    LatencyCount: QWord;
    { gauges and listener counters, filled when the snapshot is taken }
    OpenConnections: Int64;
    RequestsInFlight: Int64;
    PooledBufferBytes: Int64;
    ConnectionsAccepted: QWord;
    ListenerErrorPauses: QWord;
    ListenerLimitPauses: QWord;
    AccessLogDropped: QWord;
  end;

  TMetricsSnapshot = record
    Loops: Integer;
    Total: TLoopMetrics;             { every loop added together }
    WorkerQueueLength: Integer;      { 0 without a worker pool }
    WorkerThreads: Integer;
    CountedConnections: Integer;     { the connection limit's count; 0 without a limit }
  end;

{ The status class of a response status. }
function StatusClassOf(Status: Word): TStatusClass; inline;
{ The bucket of a duration: the smallest K with Ns <= 2^K microseconds, or
  LATENCY_BUCKETS when it is longer than 2^(LATENCY_BUCKETS - 1) us. }
function LatencyBucket(Ns: Int64): Integer;
{ Counts one completed response in M. }
procedure MetricsResponse(var M: TLoopMetrics; Status: Word; DurationNs: Int64;
  RequestBytes, ResponseBytes: QWord);
{ A := A + B, field by field. }
procedure MetricsAdd(var A: TLoopMetrics; const B: TLoopMetrics);
{ The Prometheus text exposition of a snapshot (see the unit header). }
function MetricsToPrometheus(const S: TMetricsSnapshot): RawByteString;
{ The label value of an outcome ("ok", "timeout", ...). }
function OutcomeLabel(O: TConnOutcome): RawByteString;

implementation

uses
  SysUtils;

const
  OUTCOME_LABELS: array[TConnOutcome] of RawByteString = ('ok', 'timeout', 'parse_too_large',
    'parse_version_h2', 'parse', 'incomplete', 'user', 'canceled', 'closed', 'body_write_aborted',
    'shutdown', 'io', 'other');
  STATUS_LABELS: array[TStatusClass] of RawByteString = ('1xx', '2xx', '3xx', '4xx', '5xx', 'other');

function StatusClassOf(Status: Word): TStatusClass;
begin
  case Status of
    100..199: Result := sc1xx;
    200..299: Result := sc2xx;
    300..399: Result := sc3xx;
    400..499: Result := sc4xx;
    500..599: Result := sc5xx;
  else
    Result := scOther;
  end;
end;

function LatencyBucket(Ns: Int64): Integer;
var
  Us, Bound: Int64;
begin
  if Ns <= 0 then
    Exit(0);
  Us := (Ns + 999) div 1000;         { rounded up: 1 ns counts as 1 us }
  Bound := 1;
  Result := 0;
  while (Result < LATENCY_BUCKETS) and (Us > Bound) do
  begin
    Inc(Result);
    Bound := Bound shl 1;
  end;
end;

procedure MetricsResponse(var M: TLoopMetrics; Status: Word; DurationNs: Int64;
  RequestBytes, ResponseBytes: QWord);
begin
  Inc(M.Responses[StatusClassOf(Status)]);
  Inc(M.RequestBytes, RequestBytes);
  Inc(M.ResponseBytes, ResponseBytes);
  if DurationNs < 0 then
    DurationNs := 0;
  Inc(M.Latency[LatencyBucket(DurationNs)]);
  Inc(M.LatencySumNs, QWord(DurationNs));
  Inc(M.LatencyCount);
end;

procedure MetricsAdd(var A: TLoopMetrics; const B: TLoopMetrics);
var
  O: TConnOutcome;
  C: TStatusClass;
  I: Integer;
begin
  for O := Low(TConnOutcome) to High(TConnOutcome) do
    Inc(A.ConnectionsClosed[O], B.ConnectionsClosed[O]);
  Inc(A.Requests, B.Requests);
  for C := Low(TStatusClass) to High(TStatusClass) do
    Inc(A.Responses[C], B.Responses[C]);
  Inc(A.RequestBytes, B.RequestBytes);
  Inc(A.ResponseBytes, B.ResponseBytes);
  for I := 0 to LATENCY_BUCKETS do
    Inc(A.Latency[I], B.Latency[I]);
  Inc(A.LatencySumNs, B.LatencySumNs);
  Inc(A.LatencyCount, B.LatencyCount);
  Inc(A.OpenConnections, B.OpenConnections);
  Inc(A.RequestsInFlight, B.RequestsInFlight);
  Inc(A.PooledBufferBytes, B.PooledBufferBytes);
  Inc(A.ConnectionsAccepted, B.ConnectionsAccepted);
  Inc(A.ListenerErrorPauses, B.ListenerErrorPauses);
  Inc(A.ListenerLimitPauses, B.ListenerLimitPauses);
  Inc(A.AccessLogDropped, B.AccessLogDropped);
end;

function OutcomeLabel(O: TConnOutcome): RawByteString;
begin
  Result := OUTCOME_LABELS[O];
end;

{ Seconds with 6 decimals from microseconds, as Prometheus "le" values ("0.000001", "8.388608"). }
function UsToSeconds(Us: QWord): RawByteString;
var
  F: RawByteString;
begin
  F := IntToStr(Us mod 1000000);
  while Length(F) < 6 do
    F := '0' + F;
  Result := IntToStr(Us div 1000000) + '.' + F;
end;

{ Seconds with 9 decimals from nanoseconds. }
function NsToSeconds(Ns: QWord): RawByteString;
var
  F: RawByteString;
begin
  F := IntToStr(Ns mod 1000000000);
  while Length(F) < 9 do
    F := '0' + F;
  Result := IntToStr(Ns div 1000000000) + '.' + F;
end;

function MetricsToPrometheus(const S: TMetricsSnapshot): RawByteString;
var
  R: RawByteString;
  O: TConnOutcome;
  C: TStatusClass;
  I: Integer;
  Cum: QWord;

  procedure Head(const Name, Help, Kind: RawByteString);
  begin
    R := R + '# HELP bearings_' + Name + ' ' + Help + #10
      + '# TYPE bearings_' + Name + ' ' + Kind + #10;
  end;

  procedure Line(const Name, Labels: RawByteString; Value: QWord);
  begin
    R := R + 'bearings_' + Name + Labels + ' ' + IntToStr(Value) + #10;
  end;

  procedure LineI(const Name: RawByteString; Value: Int64);
  begin
    R := R + 'bearings_' + Name + ' ' + IntToStr(Value) + #10;
  end;

begin
  R := '';
  Head('connections_open', 'HTTP connections open now.', 'gauge');
  LineI('connections_open', S.Total.OpenConnections);
  Head('connections_counted', 'Connections holding a slot of the connection limit (0 without a limit).', 'gauge');
  LineI('connections_counted', S.CountedConnections);
  Head('connections_accepted_total', 'Connections accepted by the listeners.', 'counter');
  Line('connections_accepted_total', '', S.Total.ConnectionsAccepted);
  Head('connections_closed_total', 'Connections closed, by outcome.', 'counter');
  for O := Low(TConnOutcome) to High(TConnOutcome) do
    Line('connections_closed_total', '{outcome="' + OUTCOME_LABELS[O] + '"}', S.Total.ConnectionsClosed[O]);
  Head('requests_total', 'Request heads read.', 'counter');
  Line('requests_total', '', S.Total.Requests);
  Head('requests_in_flight', 'Requests being handled or answered now.', 'gauge');
  LineI('requests_in_flight', S.Total.RequestsInFlight);
  Head('responses_total', 'Responses completed, by status class.', 'counter');
  for C := Low(TStatusClass) to High(TStatusClass) do
    Line('responses_total', '{status="' + STATUS_LABELS[C] + '"}', S.Total.Responses[C]);
  Head('request_bytes_total', 'HTTP bytes received: request heads and bodies.', 'counter');
  Line('request_bytes_total', '', S.Total.RequestBytes);
  Head('response_bytes_total', 'HTTP bytes sent: response heads and bodies.', 'counter');
  Line('response_bytes_total', '', S.Total.ResponseBytes);
  Head('request_duration_seconds', 'Time from the request head to the complete response.', 'histogram');
  Cum := 0;
  for I := 0 to LATENCY_BUCKETS - 1 do
  begin
    Inc(Cum, S.Total.Latency[I]);
    Line('request_duration_seconds_bucket', '{le="' + UsToSeconds(QWord(1) shl I) + '"}', Cum);
  end;
  Inc(Cum, S.Total.Latency[LATENCY_BUCKETS]);
  Line('request_duration_seconds_bucket', '{le="+Inf"}', Cum);
  R := R + 'bearings_request_duration_seconds_sum ' + NsToSeconds(S.Total.LatencySumNs) + #10;
  Line('request_duration_seconds_count', '', S.Total.LatencyCount);
  Head('listener_pauses_total', 'Times a listener left epoll, by reason.', 'counter');
  Line('listener_pauses_total', '{reason="error"}', S.Total.ListenerErrorPauses);
  Line('listener_pauses_total', '{reason="limit"}', S.Total.ListenerLimitPauses);
  Head('worker_queue_length', 'Work items queued for the worker pool.', 'gauge');
  LineI('worker_queue_length', S.WorkerQueueLength);
  Head('worker_threads', 'Worker threads.', 'gauge');
  LineI('worker_threads', S.WorkerThreads);
  Head('buffer_pool_bytes', 'Bytes held in the loops'' buffer pools.', 'gauge');
  LineI('buffer_pool_bytes', S.Total.PooledBufferBytes);
  Head('access_log_dropped_total', 'Access log lines dropped because a buffer was full.', 'counter');
  Line('access_log_dropped_total', '', S.Total.AccessLogDropped);
  Head('loops', 'Event loops.', 'gauge');
  LineI('loops', S.Loops);
  Result := R;
end;

end.
