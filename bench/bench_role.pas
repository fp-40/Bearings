{ bench_role - micro-benchmark of the M2 codec hot paths (M3 design 7.6,
  step S0 gate: parse 152 ns, encode 121 ns, +-10 %).

  Same request and response as the design-phase bench_role (M3 design
  measurements, section 0.2): ServerParse of a TFB-like request;
  ServerEncode of a 200 with content-type + server, content-length 13 and
  the date. Added in S0: the TByteVec overload of ServerEncode (the one the
  M3 connection uses) and the header validation cost (R11): Clear + two
  validating Add versus two AddTrusted.

  Each line is run ROUNDS times; the minimum and the median ns/op are
  printed. Run pinned to one P-core: taskset -c 2 bench_role
  Build: fpc -Mobjfpc -Sh -O3 -CX -XX -Xs -Fusrc/rt -Fusrc/http1 bench/bench_role.pas }
program bench_role;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, BaseUnix, Unix, Linux, bearings.rt.buf, bearings.http1.parser, bearings.http.headers,
  bearings.http1.encode, bearings.http1.role, bearings.http.date;

const
  N = 5000000;
  ROUNDS = 7;

type
  TRoundTimes = array[0..ROUNDS - 1] of Double;

var
  Req: RawByteString;
  H, RH, VH: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TResponseHead;
  P: TServerEncodeParams;
  Ctx: TEncodeContext;
  Enc: TEncoder;
  Dst: TBytes;
  DstLen: SizeInt;
  Vec: TByteVec;
  PCtx: TH1ParseContext;
  Sink: SizeInt;

function NowNs: Int64;
var
  T: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @T);
  Result := Int64(T.tv_sec) * 1000000000 + T.tv_nsec;
end;

procedure Report(const Name: string; var R: TRoundTimes);
var
  I, J: Integer;
  X: Double;
begin
  for I := 1 to ROUNDS - 1 do
  begin
    X := R[I];
    J := I - 1;
    while (J >= 0) and (R[J] > X) do
    begin
      R[J + 1] := R[J];
      Dec(J);
    end;
    R[J + 1] := X;
  end;
  WriteLn(Format('%-36s min %7.1f  median %7.1f ns/op', [Name, R[0], R[ROUNDS div 2]]));
end;

procedure BenchParse;
var
  R: TRoundTimes;
  K, I: Integer;
  T0: Int64;
begin
  for K := 0 to ROUNDS - 1 do
  begin
    T0 := NowNs;
    for I := 1 to N do
      ServerParse(PByte(Pointer(Req)), Length(Req), PCtx, H, Msg);
    R[K] := (NowNs - T0) / N;
  end;
  Report('parse', R);
end;

procedure BenchEncodeBytes(const Name: string; Headers: THttpHeaders);
var
  R: TRoundTimes;
  K, I: Integer;
  T0: Int64;
begin
  Head.Headers := Headers;
  for K := 0 to ROUNDS - 1 do
  begin
    T0 := NowNs;
    for I := 1 to N do
    begin
      DstLen := 0;
      ServerEncode(Head, P, Dst, DstLen, Enc);
    end;
    R[K] := (NowNs - T0) / N;
  end;
  Inc(Sink, DstLen);
  Report(Name, R);
end;

procedure BenchEncodeVec(const Name: string; Headers: THttpHeaders);
var
  R: TRoundTimes;
  K, I: Integer;
  T0: Int64;
begin
  Head.Headers := Headers;
  for K := 0 to ROUNDS - 1 do
  begin
    T0 := NowNs;
    for I := 1 to N do
    begin
      Vec.Clear;
      ServerEncode(Head, P, Ctx, Vec, nil, Enc);
    end;
    R[K] := (NowNs - T0) / N;
  end;
  Inc(Sink, Vec.Len);
  Report(Name, R);
end;

procedure BenchHeaders(Validating: Boolean);
var
  R: TRoundTimes;
  K, I: Integer;
  T0: Int64;
const
  N1: RawByteString = 'content-type';
  V1: RawByteString = 'text/plain';
  N2: RawByteString = 'server';
  V2: RawByteString = 'wd-40';
begin
  for K := 0 to ROUNDS - 1 do
  begin
    T0 := NowNs;
    if Validating then
      for I := 1 to N do
      begin
        VH.Clear;
        VH.Add(PByte(Pointer(N1)), 12, PByte(Pointer(V1)), 10);
        VH.Add(PByte(Pointer(N2)), 6, PByte(Pointer(V2)), 5);
      end
    else
      for I := 1 to N do
      begin
        VH.Clear;
        VH.AddTrusted(PByte(Pointer(N1)), 12, PByte(Pointer(V1)), 10);
        VH.AddTrusted(PByte(Pointer(N2)), 6, PByte(Pointer(V2)), 5);
      end;
    R[K] := (NowNs - T0) / N;
  end;
  Inc(Sink, VH.Count);
  if Validating then
    Report('headers: Clear + 2 x Add (validating)', R)
  else
    Report('headers: Clear + 2 x AddTrusted', R);
end;

begin
  IsMultiThread := True;   { as in the server: AnsiString refcounts become lock-prefixed }
  Req := 'GET /plaintext HTTP/1.1'#13#10'Host: server'#13#10'User-Agent: Mozilla/5.0'#13#10 +
    'Accept: text/plain,text/html;q=0.9'#13#10'Connection: keep-alive'#13#10#13#10;
  H := THttpHeaders.Create;
  RH := THttpHeaders.Create;
  VH := THttpHeaders.Create;
  RH.Add('content-type', 'text/plain');
  RH.Add('server', 'wd-40');
  PCtx := DefaultParseContext;
  ServerParse(PByte(Pointer(Req)), Length(Req), PCtx, H, Msg);
  Head := DefaultResponseHead;
  P := DefaultEncodeParams;
  P.Body := blkKnown;
  P.BodyLen := 13;
  P.ReqMethod := hmGet;
  SetLength(Dst, 4096);
  Ctx.Date := DateBuffer;           { the loop passes its own date bytes }
  Ctx.Trailers := nil;
  Vec := Default(TByteVec);
  Vec.Reserve(4096, nil);
  Sink := 0;

  BenchParse;
  BenchEncodeBytes('encode (TBytes, 2 headers)', RH);
  BenchEncodeBytes('encode (TBytes, no headers)', nil);
  BenchEncodeVec('encode (TByteVec, 2 headers)', RH);
  BenchEncodeVec('encode (TByteVec, no headers)', nil);
  BenchHeaders(False);
  BenchHeaders(True);
  if Sink = 0 then
    WriteLn('(sink 0)');
end.
