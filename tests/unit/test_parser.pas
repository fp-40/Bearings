{ fpcunit runner for the bearings.http1.parser tests.
  Run: test_parser --all --format=plain }
program test_parser;

{$mode objfpc}{$H+}

uses
  consoletestrunner,
  test_parser_lib_req, test_parser_lib, test_parser_uri, test_parser_simd,
  test_parser_extra;

var
  App: TTestRunner;
begin
  DefaultFormat := fPlain;
  DefaultRunAllTests := True;
  App := TTestRunner.Create(nil);
  App.Initialize;
  App.Title := 'bearings.http1.parser tests';
  App.Run;
  App.Free;
end.
