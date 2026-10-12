{ bearings.ws.topics - pub/sub topics for WebSocket connections.

  A registry (TWsTopics, one per server) in which connections subscribe to
  topics and any thread publishes a message to a topic: the message is
  encoded once and sent to every subscribed connection, on every loop,
  without the application keeping lists of connections. Modelled on
  uWebSockets' subscribe / publish.

    Topics := TWsTopics.Create;                 // the application creates and frees it
    Topics.Subscribe(WS, 'chat/room1');         // loop thread of WS, or a worker handler
    Topics.Unsubscribe(WS, 'chat/room1');
    Topics.Publish('chat/room1', 'hola');       // text (UTF-8); any thread
    Topics.PublishBinary('sensors/x/temp', Data);
    Topics.PublishFrame('chat/room1', F);       // a prepared TWsFrame
    Topics.Publish('chat/room1', 'hola', WS);   // everyone but WS

  Topics are '/'-separated levels. A subscription may use the MQTT
  wildcards: '+' matches one level, '#' matches the rest of the levels
  (including none: 'chat/#' matches 'chat'). Each wildcard must be a whole
  level and '#' the last one. A publish names a concrete topic: no '+' or
  '#' in it. EArgumentException for anything else.

  Rules:
  - A connection's subscriptions are removed when it ends (through
    TWebSocket.Hook, called at the start of Finish); OnClose has nothing
    to do. A connection that is Closing cannot subscribe.
  - Subscribe and Unsubscribe on the connection's loop thread take effect
    at once. From another thread (a TWsWorkerHandler method) they are
    posted to the loop and take effect shortly after; a publish in between
    may miss the new subscriber. Same as uWebSockets.
  - Messages published by one thread reach each subscriber in that order.
    A connection subscribed to two patterns that both match gets the
    message once.
  - A subscriber whose output queue is at the mark (SendFrame returns
    wsFull) does not get the message: it is dropped for that connection and
    counted in TWebSocket.DroppedMessages. With CloseOnBackpressure the
    connection is aborted instead (TWebSocket.Abort: no close frame, since
    the client is not reading). Nothing is queued without a bound.
  - Exclusion of the sender is the explicit Exclude parameter. The caller
    must hold the connection (its loop thread, or a reference): a reference
    is taken for the publish and released when it is done.
  - Nothing is retained: a subscriber gets only what is published after it
    subscribed.
  - Publish needs the loops alive: not after the server stopped. The
    registry is freed after the server, when every connection has ended.

  How it works. Each loop has its own table, touched by its thread only:
  a trie keyed by level, where each node holds the subscribers whose
  pattern ends there, its named children in a small hash table, and the
  '+' and '#' children. A publish builds one prepared frame and one heap
  object (the frame, the topic's levels, the exclusion, a count of loops
  still to run it and one TLoopMsg per loop), posts an lmCall message to
  each loop (TLoop.Post allocates nothing), and each loop walks its trie
  with the topic's levels, following the exact child, the '+' child and
  the '#' child, and calls SendFrame for each subscriber found (the frame's
  bytes are shared by reference for frames of 1 KiB or more). A publish
  sequence number per loop marks the per-connection record, so a
  connection matched twice is sent to once. The last loop frees the publish
  object (an atomic count with the drd happens-before edge). The tables are
  found when a connection on a loop subscribes; they are kept in an array
  that only grows, under a spin lock that Publish takes to copy the array.

  Threading: Publish, PublishBinary, PublishFrame: any thread. Subscribe,
  Unsubscribe: the loop thread of WS, or any thread that holds WS (a
  worker handler; posted). CloseOnBackpressure: set before the first
  publish. Everything else runs on the loop threads. }
unit bearings.ws.topics;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, bearings.rt.sync, bearings.rt.loop, bearings.ws.frame, bearings.ws.conn;

type
  TWsTopics = class;
  TTopicTable = class;
  TTopicNode = class;

  TTopicLevels = array of RawByteString;

  { the per-connection record (TWebSocket.HookData); its loop thread only }
  TTopicSub = class
  public
    WS: TWebSocket;
    Table: TTopicTable;
    Nodes: array of TTopicNode;      { the trie nodes this subscriber is in ... }
    Patterns: array of RawByteString; { ... and the pattern of each }
    Count: Integer;
    Seq: QWord;                      { the last publish delivered (Table.Seq) }
  end;

  { a trie node: one level of a pattern; its loop thread only }
  TTopicNode = class
  public
    Key: RawByteString;
    Hash: LongWord;
    Parent: TTopicNode;
    Chain: TTopicNode;               { next node in the parent's bucket }
    Buckets: array of TTopicNode;    { the named children; power-of-two size }
    ChildCount: Integer;
    Plus, Many: TTopicNode;          { the '+' and '#' children (also in Buckets) }
    Subs: array of TTopicSub;        { the subscribers whose pattern ends here }
    SubCount: Integer;
    destructor Destroy; override;
    function Find(const K: RawByteString): TTopicNode;
    function Child(const K: RawByteString): TTopicNode;   { finds or adds }
    procedure RemoveChild(N: TTopicNode);
    procedure AddSub(S: TTopicSub);
    procedure RemoveSub(S: TTopicSub);
    function Empty: Boolean; inline;
  end;

  TWsPublish = class;

  PPublishMsg = ^TPublishMsg;
  TPublishMsg = record
    Msg: TLoopMsg;                   { first: the inbox message }
    Pub: TWsPublish;
    Table: TTopicTable;
  end;

  { one publish; freed by the last loop that ran it }
  TWsPublish = class
  public
    Frame: TWsFrame;
    Levels: TTopicLevels;
    Exclude: TWebSocket;             { a reference is held until Destroy }
    Pending: LongInt;                { loops still to run it }
    Msgs: array of TPublishMsg;      { one per loop; not resized after the posts }
    destructor Destroy; override;
  end;

  { one loop's subscription table; that loop's thread only }
  TTopicTable = class
  private
    FDeferred: array of record WS: TWebSocket; Pattern: RawByteString; end;
    FDeferredCount: Integer;
  public
    Topics: TWsTopics;
    Loop: TLoop;
    Root: TTopicNode;
    Seq: QWord;                      { publishes run on this loop }
    Walking: Boolean;                { inside Deliver: an Unsubscribe is deferred }
    constructor Create(ATopics: TWsTopics; ALoop: TLoop);
    destructor Destroy; override;
    procedure Deliver(P: TWsPublish);
  end;

  TWsTopics = class(TWsConnHook)
  private
    FLock: TSpinLock;
    FTables: array of TTopicTable;   { only grows; copied under FLock by Publish }
    FCount: Integer;
    FCloseOnBackpressure: Boolean;
    function TableFor(Loop: TLoop): TTopicTable;
    function SubFor(WS: TWebSocket): TTopicSub;
    procedure DoSubscribe(WS: TWebSocket; const Pattern: RawByteString);
    procedure DoUnsubscribe(WS: TWebSocket; const Pattern: RawByteString);
    procedure Drop(S: TTopicSub; I: Integer);
    procedure PostOp(WS: TWebSocket; const Pattern: RawByteString; Add: Boolean);
    procedure Send(const Topic: RawByteString; const F: TWsFrame; Exclude: TWebSocket);
  public
    constructor Create;
    { after the server stopped (every connection ended) }
    destructor Destroy; override;
    procedure Finished(WS: TWebSocket); override;
    { Loop thread of WS, or a thread holding WS (posted). Pattern: a topic
      with '+' and '#' wildcards (the unit header). Nothing happens when WS
      is Closing, or when it is already subscribed to Pattern. }
    procedure Subscribe(WS: TWebSocket; const Pattern: RawByteString);
    procedure Unsubscribe(WS: TWebSocket; const Pattern: RawByteString);
    { Any thread. Topic: concrete (no wildcards). Text: UTF-8. Exclude:
      a connection that does not get the message. }
    procedure Publish(const Topic, Text: RawByteString; Exclude: TWebSocket = nil);
    procedure PublishBinary(const Topic, Data: RawByteString; Exclude: TWebSocket = nil);
    { F: WsTextFrame or WsBinaryFrame (not a control frame) }
    procedure PublishFrame(const Topic: RawByteString; const F: TWsFrame; Exclude: TWebSocket = nil);
    { True: a subscriber whose queue is at the mark is aborted instead of
      skipping the message. Default False. }
    property CloseOnBackpressure: Boolean read FCloseOnBackpressure write FCloseOnBackpressure;
  end;

{ The levels of Topic ('a/b/c' -> 'a', 'b', 'c'; '' -> one empty level). }
procedure SplitLevels(const Topic: RawByteString; out Levels: TTopicLevels);
{ True when Pattern is a valid subscription pattern (the unit header). }
function WsPatternValid(const Pattern: RawByteString): Boolean;
{ True when Topic is a valid publish topic (no '+' or '#'). }
function WsTopicValid(const Topic: RawByteString): Boolean;

implementation

procedure SplitLevels(const Topic: RawByteString; out Levels: TTopicLevels);
var
  I, N, Start: Integer;
begin
  N := 1;
  for I := 1 to Length(Topic) do
    if Topic[I] = '/' then
      Inc(N);
  SetLength(Levels, N);
  N := 0;
  Start := 1;
  for I := 1 to Length(Topic) + 1 do
    if (I > Length(Topic)) or (Topic[I] = '/') then
    begin
      Levels[N] := Copy(Topic, Start, I - Start);
      Inc(N);
      Start := I + 1;
    end;
end;

function WsPatternValid(const Pattern: RawByteString): Boolean;
var
  L: TTopicLevels;
  I, J: Integer;
begin
  SplitLevels(Pattern, L);
  for I := 0 to High(L) do
  begin
    if (L[I] = '#') then
      Exit(I = High(L));
    if L[I] = '+' then
      Continue;
    for J := 1 to Length(L[I]) do
      if L[I][J] in ['+', '#'] then
        Exit(False);
  end;
  Result := True;
end;

function WsTopicValid(const Topic: RawByteString): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(Topic) do
    if Topic[I] in ['+', '#'] then
      Exit(False);
  Result := True;
end;

{$push}{$Q-}{$R-}
function HashOf(const K: RawByteString): LongWord;   { FNV-1a }
var
  I: Integer;
begin
  Result := 2166136261;
  for I := 1 to Length(K) do
    Result := (Result xor Byte(K[I])) * 16777619;
end;
{$pop}

{ ---- TTopicNode ---- }

destructor TTopicNode.Destroy;
var
  I: Integer;
  N, Nx: TTopicNode;
begin
  for I := 0 to High(Buckets) do
  begin
    N := Buckets[I];
    while N <> nil do
    begin
      Nx := N.Chain;
      N.Free;
      N := Nx;
    end;
  end;
  inherited Destroy;
end;

function TTopicNode.Find(const K: RawByteString): TTopicNode;
begin
  if ChildCount = 0 then
    Exit(nil);
  Result := Buckets[HashOf(K) and LongWord(High(Buckets))];
  while (Result <> nil) and (Result.Key <> K) do
    Result := Result.Chain;
end;

function TTopicNode.Child(const K: RawByteString): TTopicNode;
var
  Old: array of TTopicNode;
  I, B: Integer;
  N, Nx: TTopicNode;
begin
  Result := Find(K);
  if Result <> nil then
    Exit;
  if ChildCount >= Length(Buckets) then
  begin
    { twice the buckets, the nodes rehashed }
    Old := Buckets;
    Buckets := nil;
    SetLength(Buckets, 8 + 2 * Length(Old));
    for I := 0 to High(Old) do
    begin
      N := Old[I];
      while N <> nil do
      begin
        Nx := N.Chain;
        B := N.Hash and LongWord(High(Buckets));
        N.Chain := Buckets[B];
        Buckets[B] := N;
        N := Nx;
      end;
    end;
  end;
  Result := TTopicNode.Create;
  Result.Key := K;
  Result.Hash := HashOf(K);
  Result.Parent := Self;
  B := Result.Hash and LongWord(High(Buckets));
  Result.Chain := Buckets[B];
  Buckets[B] := Result;
  Inc(ChildCount);
  if K = '+' then
    Plus := Result
  else if K = '#' then
    Many := Result;
end;

procedure TTopicNode.RemoveChild(N: TTopicNode);
var
  B: Integer;
  P: TTopicNode;
begin
  B := N.Hash and LongWord(High(Buckets));
  if Buckets[B] = N then
    Buckets[B] := N.Chain
  else
  begin
    P := Buckets[B];
    while P.Chain <> N do
      P := P.Chain;
    P.Chain := N.Chain;
  end;
  N.Chain := nil;
  N.Parent := nil;
  Dec(ChildCount);
  if N = Plus then
    Plus := nil;
  if N = Many then
    Many := nil;
end;

procedure TTopicNode.AddSub(S: TTopicSub);
begin
  if SubCount = Length(Subs) then
    SetLength(Subs, 4 + 2 * SubCount);
  Subs[SubCount] := S;
  Inc(SubCount);
end;

procedure TTopicNode.RemoveSub(S: TTopicSub);
var
  I: Integer;
begin
  for I := 0 to SubCount - 1 do
    if Subs[I] = S then
    begin
      Subs[I] := Subs[SubCount - 1];
      Subs[SubCount - 1] := nil;
      Dec(SubCount);
      Exit;
    end;
end;

function TTopicNode.Empty: Boolean;
begin
  Result := (ChildCount = 0) and (SubCount = 0);
end;

{ ---- TWsPublish ---- }

destructor TWsPublish.Destroy;
begin
  if Exclude <> nil then
    Exclude.Release;
  inherited Destroy;
end;

{ ---- TTopicTable ---- }

constructor TTopicTable.Create(ATopics: TWsTopics; ALoop: TLoop);
begin
  inherited Create;
  Topics := ATopics;
  Loop := ALoop;
  Root := TTopicNode.Create;
end;

destructor TTopicTable.Destroy;
begin
  Root.Free;
  inherited Destroy;
end;

{ Loop thread. Walks the trie with the publish's levels and sends the frame
  to each subscriber found, once per connection (Seq). An Unsubscribe from
  a handler that runs inside SendFrame (OnError after a write error) is
  deferred until the walk is done (Walking), so the nodes being walked are
  not freed under it. }
procedure TTopicTable.Deliver(P: TWsPublish);
var
  Last: Integer;
  CloseOnFull: Boolean;

  procedure Give(N: TTopicNode);
  var
    I: Integer;
    S: TTopicSub;
  begin
    I := 0;
    while I < N.SubCount do
    begin
      S := N.Subs[I];
      Inc(I);
      if S.Seq = Seq then
        Continue;                    { matched by another pattern already }
      S.Seq := Seq;
      if S.WS = P.Exclude then
        Continue;
      if S.WS.SendFrame(P.Frame) = wsFull then
      begin
        S.WS.DroppedMessages := S.WS.DroppedMessages + 1;
        if CloseOnFull then
          S.WS.Abort;
      end;
    end;
  end;

  procedure Walk(N: TTopicNode; I: Integer);
  var
    C: TTopicNode;
  begin
    if N.Many <> nil then
      Give(N.Many);                  { '#': the rest of the levels, or none }
    if I > Last then
    begin
      Give(N);
      Exit;
    end;
    C := N.Find(P.Levels[I]);
    if C <> nil then
      Walk(C, I + 1);
    if N.Plus <> nil then
      Walk(N.Plus, I + 1);
  end;

var
  I: Integer;
begin
  Inc(Seq);
  Last := High(P.Levels);
  CloseOnFull := Topics.FCloseOnBackpressure;
  Walking := True;
  try
    Walk(Root, 0);
  finally
    Walking := False;
  end;
  for I := 0 to FDeferredCount - 1 do
  begin
    Topics.DoUnsubscribe(FDeferred[I].WS, FDeferred[I].Pattern);
    FDeferred[I].WS := nil;
    FDeferred[I].Pattern := '';
  end;
  FDeferredCount := 0;
end;

{ ---- the loop messages ---- }

procedure PublishProc(Loop: TLoop; Arg: Pointer);
var
  M: PPublishMsg;
  P: TWsPublish;
begin
  M := PPublishMsg(Arg);
  P := M^.Pub;
  try
    M^.Table.Deliver(P);
  finally
    { this loop's accesses to the publish come before the free (drd) }
    HappensBefore(@P.Pending);
    if AtomicDec(P.Pending) = 0 then
    begin
      HappensAfter(@P.Pending);
      P.Free;
    end;
  end;
end;

type
  { a Subscribe / Unsubscribe posted from another thread }
  TTopicOp = class
  public
    Msg: TLoopMsg;
    Topics: TWsTopics;
    WS: TWebSocket;                  { a reference is held }
    Pattern: RawByteString;
    Add: Boolean;
  end;

procedure TopicOpProc(Loop: TLoop; Arg: Pointer);
var
  Op: TTopicOp;
begin
  Op := TTopicOp(Arg);
  try
    if not Op.WS.Closing then        { the connection may have ended meanwhile }
      if Op.Add then
        Op.Topics.DoSubscribe(Op.WS, Op.Pattern)
      else
        Op.Topics.DoUnsubscribe(Op.WS, Op.Pattern);
  finally
    Op.WS.Release;
    Op.Free;
  end;
end;

{ ---- TWsTopics ---- }

constructor TWsTopics.Create;
begin
  inherited Create;
end;

destructor TWsTopics.Destroy;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    FTables[I].Free;
  inherited Destroy;
end;

function TWsTopics.TableFor(Loop: TLoop): TTopicTable;
var
  I: Integer;
begin
  FLock.Acquire;
  for I := 0 to FCount - 1 do
    if FTables[I].Loop = Loop then
    begin
      Result := FTables[I];
      FLock.Release;
      Exit;
    end;
  Result := TTopicTable.Create(Self, Loop);
  if FCount = Length(FTables) then
    SetLength(FTables, 4 + 2 * FCount);   { a copy when Publish holds the old array }
  FTables[FCount] := Result;
  Inc(FCount);
  FLock.Release;
end;

{ Loop thread of WS: its record, made on the first subscription }
function TWsTopics.SubFor(WS: TWebSocket): TTopicSub;
begin
  Result := TTopicSub(WS.HookData);
  if Result <> nil then
    Exit;
  if (WS.Hook <> nil) and (WS.Hook <> Self) then
    raise EArgumentException.Create('TWsTopics.Subscribe: the connection has another hook');
  Result := TTopicSub.Create;
  Result.WS := WS;
  Result.Table := TableFor(WS.Loop);
  WS.Hook := Self;
  WS.HookData := Result;
end;

procedure TWsTopics.DoSubscribe(WS: TWebSocket; const Pattern: RawByteString);
var
  S: TTopicSub;
  N: TTopicNode;
  L: TTopicLevels;
  I: Integer;
begin
  if WS.Closing then
    Exit;
  S := SubFor(WS);
  for I := 0 to S.Count - 1 do
    if S.Patterns[I] = Pattern then
      Exit;
  SplitLevels(Pattern, L);
  N := S.Table.Root;
  for I := 0 to High(L) do
    N := N.Child(L[I]);
  N.AddSub(S);
  if S.Count = Length(S.Nodes) then
  begin
    SetLength(S.Nodes, 4 + 2 * S.Count);
    SetLength(S.Patterns, Length(S.Nodes));
  end;
  S.Nodes[S.Count] := N;
  S.Patterns[S.Count] := Pattern;
  Inc(S.Count);
end;

{ removes subscription I of S from the trie, pruning the nodes left empty }
procedure TWsTopics.Drop(S: TTopicSub; I: Integer);
var
  N, P: TTopicNode;
begin
  N := S.Nodes[I];
  N.RemoveSub(S);
  while (N.Parent <> nil) and N.Empty do
  begin
    P := N.Parent;
    P.RemoveChild(N);
    N.Free;
    N := P;
  end;
  S.Nodes[I] := S.Nodes[S.Count - 1];
  S.Patterns[I] := S.Patterns[S.Count - 1];
  S.Nodes[S.Count - 1] := nil;
  S.Patterns[S.Count - 1] := '';
  Dec(S.Count);
end;

procedure TWsTopics.DoUnsubscribe(WS: TWebSocket; const Pattern: RawByteString);
var
  S: TTopicSub;
  I: Integer;
begin
  S := TTopicSub(WS.HookData);
  if S = nil then
    Exit;
  if S.Table.Walking then
  begin
    with S.Table do
    begin
      if FDeferredCount = Length(FDeferred) then
        SetLength(FDeferred, 4 + 2 * FDeferredCount);
      FDeferred[FDeferredCount].WS := WS;
      FDeferred[FDeferredCount].Pattern := Pattern;
      Inc(FDeferredCount);
    end;
    Exit;
  end;
  for I := 0 to S.Count - 1 do
    if S.Patterns[I] = Pattern then
    begin
      Drop(S, I);
      Break;
    end;
  if S.Count = 0 then
  begin
    WS.HookData := nil;
    S.Free;
  end;
end;

{ TWebSocket.Finish, on the loop thread: every subscription goes }
procedure TWsTopics.Finished(WS: TWebSocket);
var
  S: TTopicSub;
begin
  S := TTopicSub(WS.HookData);
  if S = nil then
    Exit;
  Assert(not S.Table.Walking, 'TWsTopics.Finished: inside a publish');
  while S.Count > 0 do
    Drop(S, S.Count - 1);
  WS.HookData := nil;
  S.Free;
end;

procedure TWsTopics.PostOp(WS: TWebSocket; const Pattern: RawByteString; Add: Boolean);
var
  Op: TTopicOp;
begin
  Op := TTopicOp.Create;
  Op.Msg.Kind := lmCall;
  Op.Msg.Proc := @TopicOpProc;
  Op.Msg.Arg := Op;
  Op.Topics := Self;
  Op.WS := WS;
  Op.Pattern := Pattern;
  Op.Add := Add;
  WS.AddRef;                         { the caller holds WS; the message holds it until it ran }
  WS.Loop.Post(@Op.Msg);
end;

procedure TWsTopics.Subscribe(WS: TWebSocket; const Pattern: RawByteString);
begin
  if not WsPatternValid(Pattern) then
    raise EArgumentException.Create('TWsTopics.Subscribe: not a valid pattern: ' + Pattern);
  if GetCurrentThreadId = AtomicLoadThreadId(WS.Loop.ThreadId) then
    DoSubscribe(WS, Pattern)
  else
    PostOp(WS, Pattern, True);
end;

procedure TWsTopics.Unsubscribe(WS: TWebSocket; const Pattern: RawByteString);
begin
  if GetCurrentThreadId = AtomicLoadThreadId(WS.Loop.ThreadId) then
    DoUnsubscribe(WS, Pattern)
  else
    PostOp(WS, Pattern, False);
end;

{ Any thread: one publish object, one message per loop }
procedure TWsTopics.Send(const Topic: RawByteString; const F: TWsFrame; Exclude: TWebSocket);
var
  T: array of TTopicTable;
  N, I: Integer;
  P: TWsPublish;
begin
  if not WsTopicValid(Topic) then
    raise EArgumentException.Create('TWsTopics.Publish: not a valid topic: ' + Topic);
  FLock.Acquire;
  T := FTables;                      { the array is replaced, never changed, when it grows }
  N := FCount;
  FLock.Release;
  if N = 0 then
    Exit;                            { nobody subscribed yet, on any loop }
  P := TWsPublish.Create;
  P.Frame := F;
  SplitLevels(Topic, P.Levels);
  P.Exclude := Exclude;
  if Exclude <> nil then
    Exclude.AddRef;
  P.Pending := N;
  SetLength(P.Msgs, N);
  for I := 0 to N - 1 do
  begin
    P.Msgs[I].Msg.Kind := lmCall;
    P.Msgs[I].Msg.Proc := @PublishProc;
    P.Msgs[I].Msg.Arg := @P.Msgs[I];
    P.Msgs[I].Pub := P;
    P.Msgs[I].Table := T[I];
  end;
  { a posted message may run at once, but the object is freed only by
    the last of the N runs, so it is alive while the posts go on }
  for I := 0 to N - 1 do
    T[I].Loop.Post(@P.Msgs[I].Msg);
end;

procedure TWsTopics.Publish(const Topic, Text: RawByteString; Exclude: TWebSocket);
begin
  Send(Topic, WsTextFrame(Text), Exclude);
end;

procedure TWsTopics.PublishBinary(const Topic, Data: RawByteString; Exclude: TWebSocket);
begin
  Send(Topic, WsBinaryFrame(Data), Exclude);
end;

procedure TWsTopics.PublishFrame(const Topic: RawByteString; const F: TWsFrame; Exclude: TWebSocket);
var
  Op: Byte;
begin
  if not WsFrameValid(F, Op) or (Op >= 8) then
    raise EArgumentException.Create('TWsTopics.PublishFrame: not a prepared data frame');
  Send(Topic, F, Exclude);
end;

end.
