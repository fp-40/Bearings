{ Differential test of bearings.http1.decode and bearings.http.headers against hyper.

  test_codec_diff_rs (Rust test tooling, never shipped) runs hyper v1.12.0's
  own src/proto/h1/decode.rs and src/headers.rs over random cases and writes
  the cases and hyper's results. This program replays the cases through the
  Pascal port (test_codec_replay) and compares the results line by line.

  Usage: test_codec_diff <dir> [--guard-end | --guard-start]
  (see test_codec_diff.sh). The guard options place every decoder input
  against a PROT_NONE page, so a read outside the input crashes.
  Exit code 0 when every case matches, 1 otherwise. The file formats are
  described in test_codec_diff_rs/src/main.rs and test_codec_replay.pas. }
program test_codec_diff;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, test_codec_replay;

function RunFile(const CasesFile, ExpectedFile, What: string; IsDecode: Boolean): Integer;
var
  Cases, Expected: TStringList;
  I, Shown: Integer;
  Got: string;
begin
  Result := 0;
  Cases := TStringList.Create;
  Expected := TStringList.Create;
  try
    Cases.LoadFromFile(CasesFile);
    Expected.LoadFromFile(ExpectedFile);
    if Cases.Count <> Expected.Count then
    begin
      WriteLn(What, ': cases and expected differ in length');
      Exit(1);
    end;
    Shown := 0;
    for I := 0 to Cases.Count - 1 do
    begin
      if IsDecode then
        Got := ReplayDecodeLine(Cases[I])
      else
        Got := ReplayHeadersLine(Cases[I]);
      if Got <> Expected[I] then
      begin
        Inc(Result);
        if Shown < 20 then
        begin
          Inc(Shown);
          WriteLn(What, ' MISMATCH case ', I + 1, ':');
          WriteLn('  case:     ', Copy(Cases[I], 1, 400));
          WriteLn('  hyper:    ', Copy(Expected[I], 1, 400));
          WriteLn('  pascal:   ', Copy(Got, 1, 400));
        end;
      end;
    end;
    WriteLn(What, ': ', Cases.Count, ' cases, ', Result, ' mismatches');
  finally
    Expected.Free;
    Cases.Free;
  end;
end;

var
  Dir: string;
  Bad: Integer;
begin
  if (ParamCount < 1) or (ParamCount > 2) then
  begin
    WriteLn('usage: test_codec_diff <dir> [--guard-end | --guard-start]');
    Halt(2);
  end;
  Dir := IncludeTrailingPathDelimiter(ParamStr(1));
  if ParamCount = 2 then
  begin
    if ParamStr(2) = '--guard-end' then
      SetGuardMode(gmEnd)
    else if ParamStr(2) = '--guard-start' then
      SetGuardMode(gmStart)
    else
    begin
      WriteLn('unknown option ', ParamStr(2));
      Halt(2);
    end;
    WriteLn('guard mode ', ParamStr(2));
  end;
  Bad := RunFile(Dir + 'decode_cases.txt', Dir + 'decode_expected.txt', 'decode', True);
  Inc(Bad, RunFile(Dir + 'headers_cases.txt', Dir + 'headers_expected.txt', 'headers', False));
  if Bad > 0 then
    Halt(1);
end.
