{ worker - every request is handed to a worker thread, which reads the
  whole request body and sends it back.

  The service returns one TOffloadCall for every request. Its first Poll
  calls Ex.Offload, which shares the exchange and queues it on the server's
  worker pool; a worker then runs TEchoHandler.Run, which may block: it
  reads the body with ReadAll (a blocking read; the loop keeps serving its
  other connections meanwhile) and answers with BodyString, a copy of the
  body in a string. The worker's terminal call wakes the connection through
  the loop's inbox, and the next Poll on the loop sees Ex.Answered and
  returns cpReady.

  Errors a handler must expect:
    EBodyTooLarge  ReadAll: the body is over the limit given to it (413)
    EBodyError     the body could not be read: malformed chunked encoding,
                   the body read timeout, the connection failed (400)
    EClientGone    the client disconnected while the handler was blocked in
                   a read: nothing can be sent, the handler just returns
  IsCanceled tells a handler that is not blocked in a body call that the
  client went away; a terminal call on a canceled exchange returns False and
  sends nothing.

  Usage: worker [port]       (default 8080)
  Try:   curl -s --data-binary 'some text' http://127.0.0.1:8080/
  Build: see examples/README.md }
program worker;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, bearings.rt.loop, bearings.rt.buf, bearings.http.headers, bearings.http.exchange, bearings.server;

const
  BODY_LIMIT = 1024 * 1024;        { ReadAll refuses a larger body }

type
  { Runs on a worker thread; may block. One instance is shared by every
    worker (it has no state of its own). }
  TEchoHandler = class(TBlockingHandler)
  public
    procedure Run(Ex: TExchange); override;
  end;

  TEchoService = class(THttpService)
  private
    FCall: TOffloadCall;
  public
    constructor Create(Srv: TServer; H: TBlockingHandler);
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TApp = class
    Srv: TServer;
    Handler: TEchoHandler;
    function NewService(Loop: TLoop): THttpService;
    procedure Started(Server: TServer);
  end;

procedure TEchoHandler.Run(Ex: TExchange);
var
  Body: TBytes;
  N: SizeInt;
  S: RawByteString;
  CType: TByteSlice;
begin
  try
    N := Ex.ReadAll(Body, BODY_LIMIT);        { blocks until the body ended }
  except
    on EBodyTooLarge do
    begin
      Ex.RespondText(413, 'request body too large'#10);   { status, content-type and body in one call }
      Exit;
    end;
    on E: EBodyError do
    begin
      Ex.RespondText(400, 'bad request body: ' + Ex.BodyErrorMessage + #10);
      Exit;
    end;
    on EClientGone do
      Exit;                                   { the client disconnected: nothing to send }
  end;
  { a handler that does slow work between body calls checks IsCanceled now
    and then; a canceled exchange refuses the terminal call anyway }
  if Ex.IsCanceled then
    Exit;
  SetString(S, PAnsiChar(Body), N);
  if Ex.Header('content-type', CType) then
    Ex.ResponseHeaders.Add('content-type', SliceToStr(CType))   { a copy: the slice dies with the request head }
  else
    Ex.ResponseHeaders.Add('content-type', 'application/octet-stream');
  Ex.ResponseHeaders.Add('x-echo-bytes', IntToStr(N));
  if not Ex.Respond(BodyString(S)) then
    WriteLn(StdErr, 'worker: request ', Ex.RequestNo, ' of connection ', Ex.ConnId, ' was canceled');
end;

constructor TEchoService.Create(Srv: TServer; H: TBlockingHandler);
begin
  inherited Create;
  FCall := TOffloadCall.Create;
  FCall.Pool := Srv.Workers;                  { created by Start before the services }
  FCall.Handler := H;
end;

destructor TEchoService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function TEchoService.Call(Ex: TExchange): TServiceCall;
begin
  { Call runs on the loop thread; it must not answer or read the body }
  Result := FCall;
end;

function TApp.NewService(Loop: TLoop): THttpService;
begin
  Result := TEchoService.Create(Srv, Handler);
end;

procedure TApp.Started(Server: TServer);
begin
  WriteLn(StdErr, 'worker: listening on port ', Server.Port, ', ', Server.LoopCount, ' loops, ',
    Server.Workers.ThreadCount, ' workers');
end;

var
  Cfg: TServerConfig;
  App: TApp;
  Sig: Integer;
begin
  Cfg := ProductionServerConfig;              { Workers = 0: a pool of Min(32, cpus + 4) threads }
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  App := TApp.Create;
  App.Handler := TEchoHandler.Create;
  App.Srv := TServer.Create(Cfg, @App.NewService);
  Sig := App.Srv.RunUntilSignal(@App.Started);
  WriteLn(StdErr, 'worker: stopped (signal ', Sig, ')');
  App.Srv.Free;                               { after this no worker runs the handler }
  App.Handler.Free;
  App.Free;
end.
