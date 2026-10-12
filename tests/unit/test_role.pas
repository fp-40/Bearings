{ fpcunit runner for the M2 server-role port: bearings.http1.role, bearings.http.uri.
  Run: test_role --all --format=plain }
program test_role;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, consoletestrunner,
  test_role_server, test_role_extra, test_role_verify;

var
  App: TTestRunner;

begin
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'bearings server role tests';
    App.Run;
  finally
    App.Free;
  end;
end.
