{ stream - two response bodies that are not a block of memory: a body
  produced piece by piece from a worker thread, and a file sent with
  sendfile(2).

  Routes:
    /        a streamed body: BeginStream, then ten lines written one per
             100 ms with Write, then Finish. The body goes out with the
             chunked encoding (its length is unknown when the head is
             sent). Write copies the bytes into the exchange's queue and,
             on a worker thread, waits while about HighWater bytes are
             queued: a client that reads slowly slows the producer down
             instead of making the server buffer everything. A write on a
             canceled exchange (the client went away) returns wrCanceled;
             the producer stops then.
    /file    the file named on the command line (default /etc/os-release),
             sent with BodyFile: the kernel copies the file to the socket
             (sendfile), and the file descriptor is closed after the last
             byte (CloseAfter = True). Content-Length is the file size.
    other    404.

  Both routes run on a worker (TOffloadCall), because the stream producer
  sleeps and open(2) may block.

  Usage: stream [port [file]]      (default 8080, /etc/os-release)
  Try:   curl -N http://127.0.0.1:8080/      (-N: print each line as it arrives)
         curl -i http://127.0.0.1:8080/file
  Build: see examples/README.md }
program stream;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, BaseUnix, bearings.rt.loop, bearings.rt.buf, bearings.http.headers, bearings.http.exchange,
  bearings.server;

const
  O_CLOEXEC = $80000;              { Linux; BaseUnix does not declare it }

type
  TStreamHandler = class(TBlockingHandler)
  public
    FileName: RawByteString;
    procedure Run(Ex: TExchange); override;
    procedure ServeLines(Ex: TExchange);
    procedure ServeFile(Ex: TExchange);
  end;

  TStreamService = class(THttpService)
  private
    FCall: TOffloadCall;
  public
    constructor Create(Srv: TServer; H: TBlockingHandler);
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TApp = class
    Srv: TServer;
    Handler: TStreamHandler;
    function NewService(Loop: TLoop): THttpService;
    procedure Started(Server: TServer);
  end;

function PathIs(Ex: TExchange; const S: RawByteString): Boolean;
var
  P: TByteSlice;
begin
  P := Ex.Path;
  Result := (P.Len = Length(S)) and (CompareByte(P.P^, S[1], P.Len) = 0);
end;

procedure TStreamHandler.ServeLines(Ex: TExchange);
var
  I: Integer;
  Line: RawByteString;
begin
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  if not Ex.BeginStream then                  { the head goes out now, chunked }
    Exit;                                     { canceled or already answered }
  for I := 1 to 10 do
  begin
    Sleep(100);                               { a worker may block }
    Line := 'line ' + IntToStr(I) + #10;
    if Ex.Write(PByte(Line), Length(Line)) = wrCanceled then
    begin
      WriteLn(StdErr, 'stream: client gone after ', I - 1, ' lines');
      Exit;                                   { the exchange ends the body itself }
    end;
  end;
  Ex.Finish;                                  { the last chunk; no trailers }
end;

procedure TStreamHandler.ServeFile(Ex: TExchange);
var
  Fd: cint;
  St: Stat;
begin
  Fd := FpOpen(FileName, O_RDONLY or O_CLOEXEC);
  if Fd < 0 then
  begin
    Ex.Status := 404;
    Ex.Respond(BodyString('cannot open ' + FileName + #10));
    Exit;
  end;
  if FpFStat(Fd, St) <> 0 then
  begin
    FpClose(Fd);
    Ex.Status := 500;
    Ex.Respond(BodyString('fstat failed'#10));
    Exit;
  end;
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  { the server owns Fd from here: it is closed after the last byte was
    written, or when the connection dies before that (CloseAfter = True) }
  Ex.Respond(BodyFile(Fd, 0, St.st_size, True));
end;

procedure TStreamHandler.Run(Ex: TExchange);
begin
  if PathIs(Ex, '/') then
    ServeLines(Ex)
  else if PathIs(Ex, '/file') then
    ServeFile(Ex)
  else
  begin
    Ex.Status := 404;
    Ex.Respond(BodyString('not found'#10));
  end;
end;

constructor TStreamService.Create(Srv: TServer; H: TBlockingHandler);
begin
  inherited Create;
  FCall := TOffloadCall.Create;
  FCall.Pool := Srv.Workers;
  FCall.Handler := H;
end;

destructor TStreamService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function TStreamService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

function TApp.NewService(Loop: TLoop): THttpService;
begin
  Result := TStreamService.Create(Srv, Handler);
end;

procedure TApp.Started(Server: TServer);
begin
  WriteLn(StdErr, 'stream: listening on port ', Server.Port, '; /file serves ', Handler.FileName);
end;

var
  Cfg: TServerConfig;
  App: TApp;
  Sig: Integer;
begin
  Cfg := ProductionServerConfig;
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  App := TApp.Create;
  App.Handler := TStreamHandler.Create;
  App.Handler.FileName := ParamStr(2);
  if App.Handler.FileName = '' then
    App.Handler.FileName := '/etc/os-release';
  App.Srv := TServer.Create(Cfg, @App.NewService);
  Sig := App.Srv.RunUntilSignal(@App.Started);
  WriteLn(StdErr, 'stream: stopped (signal ', Sig, ')');
  App.Srv.Free;
  App.Handler.Free;
  App.Free;
end.
