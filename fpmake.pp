{ fpmake.pp - builds and installs bearings as an FPC package, so that a
  program can use its units without -Fu options (README.md, "Installing
  as a package").

  fpc fpmake.pp && ./fpmake install        # into ~/.fppkg (a user install)
  ./fpmake install --os=linux --cpu=aarch64 --compiler=build/tools/bin/fpc-aarch64

  fpmake is FPC's own build tool (the fpmkunit unit): this program
  declares the package and its units; fpmake compiles them into
  units/<cpu>-<os>/ next to this file and `install` copies the .ppu and
  .o files to <prefix>/lib/fpc/<version>/units/<cpu>-<os>/bearings/, a
  directory /etc/fpc.cfg searches (the ~/.fppkg line). The units are
  listed in a dependency order (tools/unit-graph.py prints one); fpmake
  compiles each with the package's source paths, so the compiler finds
  the units a unit uses either way. }
program fpmake;

{$mode objfpc}{$H+}

uses
  fpmkunit;

var
  P: TPackage;
begin
  with Installer do
  begin
    P := AddPackage('bearings');
    P.Version := '0.1.0';
    P.Author := 'Juan-Pablo Scaletti';
    P.License := 'MIT';
    P.Description := 'HTTP/1.1 and WebSocket server library: an event loop per CPU, a worker pool, raw Linux system calls';
    P.OSes := [linux];
    P.CPUs := [x86_64, aarch64];
    P.Options.Add('-Mobjfpc');
    P.Options.Add('-Sh');
    P.Options.Add('-O2');
    P.SourcePath.Add('src/rt');
    P.SourcePath.Add('src/http');
    P.SourcePath.Add('src/http1');
    P.SourcePath.Add('src/server');
    P.SourcePath.Add('src/ws');
    P.IncludePath.Add('src/rt');     { bearings.rt.sys.<cpu>.inc }
    { rt }
    P.Targets.AddUnit('bearings.version.pas');
    P.Targets.AddUnit('bearings.rt.sys.pas');
    P.Targets.AddUnit('bearings.rt.clock.pas');
    P.Targets.AddUnit('bearings.rt.cpu.pas');
    P.Targets.AddUnit('bearings.rt.sync.pas');
    P.Targets.AddUnit('bearings.rt.buf.pas');
    P.Targets.AddUnit('bearings.rt.timer.pas');
    P.Targets.AddUnit('bearings.rt.loop.pas');
    P.Targets.AddUnit('bearings.rt.workers.pas');
    P.Targets.AddUnit('bearings.rt.net.pas');
    P.Targets.AddUnit('bearings.rt.stream.pas');
    P.Targets.AddUnit('bearings.rt.sd.pas');
    { http and http1 }
    P.Targets.AddUnit('bearings.http.headers.pas');
    P.Targets.AddUnit('bearings.http.uri.pas');
    P.Targets.AddUnit('bearings.http.date.pas');
    P.Targets.AddUnit('bearings.http1.parser.pas');
    P.Targets.AddUnit('bearings.http1.reason.pas');
    P.Targets.AddUnit('bearings.http1.decode.pas');
    P.Targets.AddUnit('bearings.http1.encode.pas');
    P.Targets.AddUnit('bearings.http1.role.pas');
    P.Targets.AddUnit('bearings.http.error.pas');
    P.Targets.AddUnit('bearings.http.exchange.pas');
    P.Targets.AddUnit('bearings.http1.io.pas');
    P.Targets.AddUnit('bearings.http1.conn.pas');
    P.Targets.AddUnit('bearings.http1.config.pas');
    P.Targets.AddUnit('bearings.http1.dispatch.pas');
    { ws }
    P.Targets.AddUnit('bearings.ws.frame.pas');
    P.Targets.AddUnit('bearings.ws.handshake.pas');
    P.Targets.AddUnit('bearings.ws.conn.pas');
    { server }
    P.Targets.AddUnit('bearings.server.accesslog.pas');
    P.Targets.AddUnit('bearings.server.metrics.pas');
    P.Targets.AddUnit('bearings.server.pas');
    Run;
  end;
end.
