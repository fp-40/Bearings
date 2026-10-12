{ M3 S4: connection-level micro-benchmark (design 0.4 P-P1, risk R1).

  Measures the CPU cost per request of the TH1Conn calls the dispatcher
  (S5) makes for a TFB plaintext request, over an in-memory transport:
  PollReadHead, releasing the head, two trusted response headers,
  WriteHead (known length 13), WriteBodyAndEnd, PollFlush. Pipelined
  batches of Depth requests per read, PipelineFlush on (the TFB
  configuration), so one write per batch. No dispatcher, no service call,
  no exchange: this is the conn part of the 420 ns budget only; the S5
  dispatcher micro-benchmark is the gate.

  Usage: bench_conn [requests (default 10000000)] [depth (default 16)] }
program bench_conn;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, ctypes, bearings.rt.sys, bearings.rt.clock, bearings.rt.buf, bearings.rt.loop, bearings.rt.net, bearings.http.headers,
  bearings.http1.encode, bearings.http1.role, bearings.http.error, bearings.http1.io, bearings.http1.conn;

const
  REQ: RawByteString = 'GET /plaintext HTTP/1.1'#13#10'Host: localhost'#13#10 +
    'Accept: text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7'#13#10 +
    'Connection: keep-alive'#13#10#13#10;
  HELLO: array[0..12] of AnsiChar = 'Hello, World!';
  HN_SERVER: array[0..5] of AnsiChar = 'server';
  HV_WD40: array[0..4] of AnsiChar = 'wd-40';
  HN_CTYPE: array[0..11] of AnsiChar = 'content-type';
  HV_TEXT: array[0..9] of AnsiChar = 'text/plain';

type
  { Read: one batch per round, then -EAGAIN. Write: accepts everything. }
  TMemTransport = class(TTransport)
  public
    Batch: RawByteString;
    Pos: SizeInt;
    Armed: Boolean;
    Written: QWord;
    Writes: QWord;
    function Read(Buf: PByte; Len: SizeInt): SizeInt; override;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; override;
    function ShutdownWrite: SizeInt; override;
    procedure Close; override;
  end;

  TOwner = class(TLoopTask)
    procedure Run; override;
    procedure Abort; override;
  end;

function TMemTransport.Read(Buf: PByte; Len: SizeInt): SizeInt;
begin
  if not Armed then
    Exit(-ESysEAGAIN);
  Result := Length(Batch) - Pos;
  if Result > Len then
    Result := Len;
  Move(Batch[Pos + 1], Buf^, Result);
  Inc(Pos, Result);
  if Pos >= Length(Batch) then
  begin
    Armed := False;
    Pos := 0;
  end;
end;

function TMemTransport.Write(Buf: PByte; Len: SizeInt): SizeInt;
begin
  Inc(Written, QWord(Len));
  Inc(Writes);
  Result := Len;
end;

function TMemTransport.ShutdownWrite: SizeInt;
begin
  Result := 0;
end;

procedure TMemTransport.Close;
begin
end;

procedure TOwner.Run;
begin
end;

procedure TOwner.Abort;
begin
end;

var
  Loop: TLoop;
  Owner: TOwner;
  T: TMemTransport;
  Conn: TH1Conn;
  ReqHeaders, RespHeaders: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Wants: TWants;
  Err: THyperError;
  H: TResponseHead;
  BL: TBodyLength;
  Errno: cint;
  N, Depth, I, Done: Int64;
  T0, T1: Int64;
  R: TPollOpt;
begin
  N := 10000000;
  Depth := 16;
  if ParamCount >= 1 then N := StrToInt64(ParamStr(1));
  if ParamCount >= 2 then Depth := StrToInt64(ParamStr(2));
  Loop := TLoop.Create(0);
  Owner := TOwner.Create;
  Owner.Loop := Loop;
  T := TMemTransport.Create;
  T.Batch := '';
  for I := 1 to Depth do
    T.Batch := T.Batch + REQ;
  ReqHeaders := THttpHeaders.Create(16, 0);
  RespHeaders := THttpHeaders.Create(16, 1024);
  Conn.Init(T, @Loop.Blocks, Owner);
  Conn.SetFlushPipeline(True);
  Err := Default(THyperError);
  BL.Kind := blkKnown;
  BL.Len := 13;
  Done := 0;
  T0 := MonoNowNs;
  while Done < N do
  begin
    T.Armed := True;
    while True do
    begin
      R := Conn.PollReadHead(ReqHeaders, Msg, Head, Wants, Err);
      if R <> poSome then
        Break;
      Head.Release;                                   { ReleaseRequest }
      RespHeaders.Clear;
      RespHeaders.AddTrusted(@HN_SERVER[0], 6, @HV_WD40[0], 5);
      RespHeaders.AddTrusted(@HN_CTYPE[0], 12, @HV_TEXT[0], 10);
      H := DefaultResponseHead;
      H.Headers := RespHeaders;
      Conn.WriteHead(H, BL);
      Conn.WriteBodyAndEnd(BodyStatic(@HELLO[0], 13));
      if Conn.PollFlush(Errno) <> ipReady then
        raise Exception.Create('flush not ready');
      Inc(Done);
      Conn.WantsReadAgain;
    end;
    if R <> poPending then
      raise Exception.CreateFmt('unexpected poll result %d', [Ord(R)]);
  end;
  T1 := MonoNowNs;
  WriteLn(Format('bench_conn: %d requests, depth %d: %.1f ns/request, %d writes, %.1f bytes/response',
    [Done, Depth, (T1 - T0) / Done, T.Writes, T.Written / Done]));
  Conn.Done;
  ReqHeaders.Free;
  RespHeaders.Free;
  T.Free;
  Loop.Free;
  Owner.Free;
end.
