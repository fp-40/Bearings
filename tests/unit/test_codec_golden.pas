{ Expected-value test of bearings.http1.decode and bearings.http.headers.

  Replays the cases of one file through the Pascal decoder or the header
  list (test_codec_replay) and prints one result line per case.
  test_codec_golden.sh compares the lines with tests/golden/decode_expected.txt.xz
  and headers_expected.txt.xz. The cases and the values were frozen on
  2026-11-04 from hyper v1.12.0's src/proto/h1/decode.rs and src/headers.rs,
  with the bare-LF trailer rule (docs/design/deviations.md) applied; they
  are now maintained here. The line formats are described in
  test_codec_replay.pas.

  Usage: test_codec_golden decode|headers <cases file> [--guard-end | --guard-start]
  The guard options place every decoder input against a PROT_NONE page, so
  a read outside the input crashes. }
program test_codec_golden;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, test_codec_replay;

var
  Cases: TStringList;
  IsDecode: Boolean;
  I: Integer;
  OutF: Text;
  OutBuf: array[0..65535] of Byte;
begin
  if (ParamCount < 2) or (ParamCount > 3)
      or ((ParamStr(1) <> 'decode') and (ParamStr(1) <> 'headers')) then
  begin
    WriteLn(StdErr, 'usage: test_codec_golden decode|headers <cases file> [--guard-end | --guard-start]');
    Halt(2);
  end;
  IsDecode := ParamStr(1) = 'decode';
  if ParamCount = 3 then
  begin
    if ParamStr(3) = '--guard-end' then
      SetGuardMode(gmEnd)
    else if ParamStr(3) = '--guard-start' then
      SetGuardMode(gmStart)
    else
    begin
      WriteLn(StdErr, 'unknown option ', ParamStr(3));
      Halt(2);
    end;
  end;
  Cases := TStringList.Create;
  Assign(OutF, '');
  Rewrite(OutF);
  SetTextBuf(OutF, OutBuf, SizeOf(OutBuf));
  try
    Cases.LoadFromFile(ParamStr(2));
    for I := 0 to Cases.Count - 1 do
      if IsDecode then
        WriteLn(OutF, ReplayDecodeLine(Cases[I]))
      else
        WriteLn(OutF, ReplayHeadersLine(Cases[I]));
  finally
    Close(OutF);
    Cases.Free;
  end;
end.
