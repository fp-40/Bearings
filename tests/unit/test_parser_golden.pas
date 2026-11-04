{ Expected-value test driver for bearings.http1.parser.
  Usage: test_parser_golden <corpus> [--guard-end | --guard-start]
  --guard-end places each case so that it ends exactly at a PROT_NONE page,
  --guard-start so that it starts right after one: any read outside
  [Buf, Buf+Len) then crashes with SIGSEGV.
  Reads the corpus written by test_parser_corpus.py and prints two result
  lines for every case: with 4 header slots (configuration 0) and with 1
  (configuration 1). test_parser_golden.sh
  compares the lines with tests/golden/parser_expected.txt.xz. Those
  values were httparse 1.10.1's results for the same corpus when they
  were frozen (2026-11-04); they are now maintained here. }
program test_parser_golden;

{$mode objfpc}{$H+}

uses
  BaseUnix, SysUtils, Classes, bearings.http1.parser;

const
  ERR_NAMES: array[THttpParseError] of string = ('None', 'HeaderName',
    'HeaderValue', 'NewLine', 'Token', 'TooManyHeaders', 'Version');

var
  Data: TBytesStream;
  OutF: Text;
  OutBuf: array[0..65535] of Byte;

function SliceOpt(Has: Boolean; const S: TSlice): string;
begin
  if Has then
    Result := IntToStr(S.Off) + ',' + IntToStr(S.Len)
  else
    Result := '-';
end;

function HeadersStr(Hdrs: PHeaderSlice; N: Integer): string;
var
  I: Integer;
begin
  Result := ' h=' + IntToStr(N);
  for I := 0 to N - 1 do
    Result := Result + Format(' %d,%d:%d,%d', [Hdrs[I].Name.Off,
      Hdrs[I].Name.Len, Hdrs[I].Value.Off, Hdrs[I].Value.Len]);
end;

procedure RunCase(CaseNo: Integer; Buf: PByte; Len: SizeInt);
var
  Cfg, Slots, N: Integer;
  Req: TParsedRequest;
  Hdrs: array[0..3] of THeaderSlice;
  R: TParseResult;
  Line, V: string;
begin
  for Cfg := 0 to 1 do
  begin
    if Cfg = 1 then Slots := 1 else Slots := 4;
    R := ParseRequest(Buf, Len, Req, @Hdrs[0], Slots);
    if Req.HasVersion then V := IntToStr(Req.Version) else V := '-';
    Line := 'm=' + SliceOpt(Req.HasMethod, Req.Method) + ' p=' +
      SliceOpt(Req.HasPath, Req.Path) + ' v=' + V;
    case R.Status of
      psComplete:
        WriteLn(OutF, CaseNo, ' ', Cfg, ' C ', R.Consumed, ' ', Line,
          HeadersStr(@Hdrs[0], Req.NumHeaders));
      psPartial:
        WriteLn(OutF, CaseNo, ' ', Cfg, ' P ', Line);
    else
      WriteLn(OutF, CaseNo, ' ', Cfg, ' E ', ERR_NAMES[R.Error], ' ', Line);
    end;
  end;
  R := ParseHeaders(Buf, Len, @Hdrs[0], 4, N);
  case R.Status of
    psComplete:
      WriteLn(OutF, CaseNo, ' H C ', R.Consumed, HeadersStr(@Hdrs[0], N));
    psPartial:
      WriteLn(OutF, CaseNo, ' H P');
  else
    WriteLn(OutF, CaseNo, ' H E ', ERR_NAMES[R.Error]);
  end;
end;

const
  PAGE = 4096;
  REGION_PAGES = 64; // 1 guard page + 62 data pages + 1 guard page

var
  P: PByte;
  Pos, Total: SizeInt;
  N: LongWord;
  CaseNo: Integer;
  Copy: TBytes;
  Mode: string;
  Region, Dst: PByte;
begin
  Mode := '';
  if ParamCount >= 2 then
    Mode := ParamStr(2);
  Region := nil;
  if Mode <> '' then
  begin
    Region := Fpmmap(nil, REGION_PAGES * PAGE, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
    if (Region = nil) or (Region = PByte(-1)) then
    begin
      WriteLn(StdErr, 'mmap failed');
      Halt(2);
    end;
    if (Fpmprotect(Region, PAGE, PROT_NONE) <> 0) or
       (Fpmprotect(Region + (REGION_PAGES - 1) * PAGE, PAGE, PROT_NONE) <> 0) then
    begin
      WriteLn(StdErr, 'mprotect failed');
      Halt(2);
    end;
  end;
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'usage: test_parser_golden <corpus>');
    Halt(2);
  end;
  Assign(OutF, '');
  Rewrite(OutF);
  SetTextBuf(OutF, OutBuf, SizeOf(OutBuf));
  Data := TBytesStream.Create;
  try
    Data.LoadFromFile(ParamStr(1));
    P := PByte(Data.Bytes);
    Total := Data.Size;
    Pos := 0;
    CaseNo := 0;
    while Pos < Total do
    begin
      Move(P[Pos], N, 4);
      N := LEtoN(N);
      Inc(Pos, 4);
      { Copy each case into an exact-size heap block so that reads past
        Len would be caught by tools such as valgrind. }
      if Region <> nil then
      begin
        if N > (REGION_PAGES - 2) * PAGE then
        begin
          WriteLn(StdErr, 'case too large for guard region');
          Halt(2);
        end;
        if Mode = '--guard-start' then
          Dst := Region + PAGE
        else
          Dst := Region + (REGION_PAGES - 1) * PAGE - N;
        if N > 0 then
          Move(P[Pos], Dst^, N);
        RunCase(CaseNo, Dst, N);
      end
      else
      begin
        SetLength(Copy, N);
        if N > 0 then
          Move(P[Pos], Copy[0], N);
        if N > 0 then
          RunCase(CaseNo, @Copy[0], N)
        else
          RunCase(CaseNo, nil, 0);
      end;
      Inc(Pos, N);
      Inc(CaseNo);
    end;
  finally
    Data.Free;
  end;
  Close(OutF);
end.
