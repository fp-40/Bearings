{ fpcunit runner for the M2 codec ports: bearings.http1.decode, bearings.http1.encode,
  bearings.http.date, bearings.http1.reason, bearings.http.headers.
  Run: test_codec --all --format=plain }
program test_codec;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, consoletestrunner,
  test_codec_decode, test_codec_encode, test_codec_misc, test_codec_extra;

var
  App: TTestRunner;

begin
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'bearings codec tests';
    App.Run;
  finally
    App.Free;
  end;
end.
