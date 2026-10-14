# WebSocket

A WebSocket starts as an HTTP request that asks to upgrade the connection.
Bearings handles the handshake and hands the socket to a `TWebSocket` that
runs on the loop and calls your handler for each message. It needs the
connection mode `cmWithUpgrades`, which `ProductionServerConfig` sets.

## Echo

The service's call sees `Ex.WantsUpgrade`, checks the handshake and
accepts it with a handler (`examples/ws_echo.pas` is the full program,
with backpressure handling):

```pascal
uses ..., bearings.ws.frame, bearings.ws.handshake, bearings.ws.conn;

type
  TChat = class(TWebSocketHandler)
  public
    procedure OnText(WS: TWebSocket; P: PByte; Len: SizeInt); override;
    procedure OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString); override;
  end;

procedure TChat.OnText(WS: TWebSocket; P: PByte; Len: SizeInt);
begin
  WS.SendText(P, Len);               { wsOk, wsFull (wait for OnWritable) or wsClosed }
end;

procedure TChat.OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString);
begin
  { the last call; WS and this handler are freed after it }
end;

function TMyCall.Poll(Ex: TExchange): TCallPoll;
var
  R: TWsHandshake;
begin
  if Ex.WantsUpgrade and PathIs(Ex, '/chat') then
  begin
    R := CheckRequest(Ex, ['chat.v1']);        { the subprotocols it supports }
    if R.Ok then
      AcceptWebSocket(Ex, R, TChat.Create, DefaultWsConfig)
    else
      RespondHandshakeError(Ex, R);            { 400, or 426 for a wrong version }
  end
  else
    Ex.RespondText(404, 'not found');
  Result := cpReady;
end;
```

The handler's methods run on the loop thread, one event at a time per
connection: `OnOpen`, `OnText` and `OnBinary` (a complete message; the
bytes are valid during the call only), `OnPong`, `OnWritable`, `OnError`
and `OnClose`, which is always the last. `AcceptWebSocket` owns the
handler from the call on and frees it after `OnClose`.

A send returns `wsFull` when the connection's output queue holds
`SendHighWater` bytes (1 MiB by default), which means the client is not
reading. Nothing was queued; the handler keeps the message and sends it
from `OnWritable`, which runs when the queue went down. The connection
also stops reading while the queue is full, so a client that does not
read cannot make the server buffer without bound.

`DefaultWsConfig` allows messages up to 16 MiB, pings every 25 seconds,
closes an idle connection after 60 seconds (the pongs keep a live client
from reaching it), and waits 5 seconds for the close handshake.

## A handler that blocks

A handler that queries a database per message derives from
`TWsWorkerHandler` instead and is accepted with the server's pool:

```pascal
type
  TStore = class(TWsWorkerHandler)
  public
    procedure OnText(WS: TWebSocket; const Msg: RawByteString); override;
  end;

procedure TStore.OnText(WS: TWebSocket; const Msg: RawByteString);
begin
  Db.Insert(Msg);                    { blocks: this runs on a worker thread }
  WS.PostText('stored');             { sends from any thread }
end;

  ...
  AcceptWebSocket(Ex, R, TStore.Create, Server.Workers, DefaultWsConfig);
```

Its events run on a worker, one at a time per connection and in order,
and an idle connection holds no thread. `Msg` is the handler's own copy.
From a worker the handler sends with `PostText` and `PostBinary`, never
`SendText`, which is a loop-thread call.

## Pub/sub: a chat with rooms

To send one message to every connection interested in something, the
application keeps no list of connections. It creates one `TWsTopics` for
the server, subscribes connections to topics and publishes to a topic:

```pascal
Topics := TWsTopics.Create;                    { the application creates and frees it }
Topics.Subscribe(WS, 'chat/room1');            { in OnOpen or OnText; from a worker handler too }
Topics.Subscribe(WS, 'sensors/+/temp');        { + matches one level, # the rest }
Topics.Publish('chat/room1', 'hola');          { any thread }
Topics.Publish('chat/room1', 'hola', WS);      { everyone but WS }
Topics.Unsubscribe(WS, 'chat/room1');
```

A publish encodes the message once and posts one message to each loop;
each loop sends the frame to its own subscribers. This is the per-loop
state with messages design from [Shared state](shared-state.md): no lock on any connection
list, and a connection's subscriptions go away with it. A subscriber
whose output queue is full misses the message (counted in
`TWebSocket.DroppedMessages`); with `Topics.CloseOnBackpressure := True`
it is disconnected instead. Nothing is queued without a bound, and nothing
is retained for late subscribers.

`examples/ws_chat.pas` is a chat with rooms on it. Its handler subscribes
in `OnOpen` to the room named in the path, and `OnText` publishes to that
room with the sender excluded:

```pascal
procedure TChatHandler.OnText(WS: TWebSocket; P: PByte; Len: SizeInt);
var
  Msg: RawByteString;
begin
  SetString(Msg, PAnsiChar(P), Len);
  if Copy(Msg, 1, 5) = 'join ' then
    Join(WS, Copy(Msg, 6, MaxInt))
  else if Msg = 'leave' then
    Join(WS, '')
  else if FRoom = '' then
    WS.SendText('join a room first: join <name>')
  else if not WsTopicValid(FRoom) then
    WS.SendText('not a valid room name')
  else
    Topics.Publish('chat/' + FRoom, Msg, WS);   { everyone in the room but the sender }
end;
```

Try it with two terminals:

```sh
$ build/examples/ws_chat 9002 &
$ websocat ws://127.0.0.1:9002/room/general   # what one terminal types, the other sees
```
