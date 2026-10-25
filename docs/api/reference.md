# 14. Reference tables

Threading rule abbreviations: **loop** = the loop thread that owns the
exchange or object; **worker** = a worker thread (or any thread holding a
`Share` reference, not the loop); **any** = any thread; **owner** = the
thread that owns the server. "internal" marks members that exist for the
dispatcher, the pool or the tests and that a program does not call;
members whose names start with `Dbg`, the test hooks (`ReleaseTestHook`,
`TryReadTestHook`, `AnswerTestHook`, `ReleaseBeforeDecrementHook`,
`PostAfterPushHook`, `PostBeforePushHook`) and the `TBodyChan` record's
methods are internal and are left out.

## bearings.server

Member | Description | Thread
------ | ----------- | ------
`TServerConfig` | the options (section 2) | plain value
`TServer.Create(Cfg, Factory, Observer = nil)` | stores the configuration, the service factory (a `TServiceFactory` method) and the observer | owner
`TServer.CreateWithProc(Cfg, Factory, Observer = nil)` | the same with a `TServiceProc` (a plain function) as the factory | owner
`TServer.Start` | binds, starts loops and workers; returns | owner
`TServer.StartCallerRunsLoop0` | `Start` without a thread for loop 0 | owner
`TServer.RunLoop0` | runs loop 0 on the calling thread until `Stop` | owner
`TServer.Stop(GraceMs)` | starts the graceful shutdown; returns at once | any
`TServer.Wait` | joins the loop threads, then shuts the worker pool down | owner
`TServer.RunUntilSignal(Started = nil): cint` | `Start`, wait for SIGTERM/SIGINT, `Stop`, `Wait`; the signal number or 0 | owner
`TServer.RunUntilSignalProc(Started: TServerProc): cint` | the same with a plain procedure as the `Started` callback | owner
`TServer.GracefulShutdownConnections` | closes every open connection after its current response; listeners keep accepting | any except a loop thread
`TServer.Destroy` | stops if needed, aborts what is left, frees loops and pools (or leaks them on purpose) | owner
`TServer.Port` | the bound port | any after `Start`
`TServer.Started` | `Start` completed | any
`TServer.Workers` | the worker pool, nil without one | any after `Start`
`TServer.Config`, `LoopCount`, `Loops[I]` | the configuration, the loops | any after `Start`
`TServerEvent` | `procedure(Server: TServer) of object`, the `Started` callback | owner
`TServerProc` | `procedure(Server: TServer)`, the `Started` callback of `RunUntilSignalProc` | owner
`NO_WORKER_POOL` | -1: the `Workers` value for a service that never offloads (no pool) | -
`TServerLoop` | one loop and what it owns: `Loop`, `Listener`, `Service`, `Pool`, `Conns`, `Index`, `Cpu`, `Thread`, `Running`, `Stopping`, `GraceMs`; `AbortConnections` and `Destroy` are internal | loop (read by tests after the loop stopped)
`EServerError` | `Start` / `RunLoop0` errors | -
`ProductionServerConfig`, `BenchmarkServerConfig` | the two presets | any
`TConnOutcome`, `TConnParts`, `TConnObserver` | re-exported from `bearings.http.error` and `bearings.http.exchange` | see there
`STALL_MS`, `StallReports` | `WD_STALL` builds only (section 12) | any (atomic)

## bearings.http.exchange

Member | Description | Thread
------ | ----------- | ------
`THttpService.Call(Ex): TServiceCall` | picks the call of a request; must not answer or read the body | loop
`TServiceFactory` | `function(Loop: TLoop): THttpService of object`; one call per loop | owner (inside `Start`)
`TServiceProc` | `function(Loop: TLoop): THttpService`, the plain-function form (`TServer.CreateWithProc`) | owner (inside `Start`)
`TServiceCall.Poll(Ex): TCallPoll` | runs the handler; `cpReady` after a terminal call, else `cpPending` | loop
`TServiceCall.Drop(Ex, Completed)` | called exactly once at the end | loop
`TCallPoll` | `cpPending`, `cpReady` | -
`TBlockingHandler.Run(Ex)` | the handler of an offloaded request; may block | worker
`TOffloadCall` (`Pool`, `Handler`, `SaturatedStatus`, `Poll`) | a stateless call that offloads every request; `SaturatedStatus` <> 0 answers that status on the loop when the pool is saturated (section 4) | loop
`TExchangeAttachment.Detach(Ex)` | per-request state the exchange detaches at recycle or next request | loop
`TByteSlice` | `P: PByte; Len: SizeInt` | -
`SliceToStr(S): RawByteString` | a copy of the slice's bytes as a string | any holder, while the slice is valid
`SliceEquals(S, Text): Boolean` | the slice holds exactly the bytes of `Text` (byte for byte) | any holder, while the slice is valid
`PathIs(Ex, Text): Boolean` | `SliceEquals(Ex.Path, Text)` | same as `TExchange.Path`
`TRequestHead` (`Ex.Head`) | the parsed head: `View`, `Method`, `MethodSlice`, `Target`, `Uri`, `Version`, `Headers`, `ContentLength`, `ExpectContinue`, `WantsUpgrade`, `Peer`, `Local`, `ConnId`, `RequestNo`, `Released`; read through the accessors below | any holder, until the request is released
`TExchange.Method`, `MethodBytes`, `Target`, `Path`, `Query(out Q)`, `Version`, `Headers`, `Header(Name, out V)`, `ContentLength`, `ExpectsContinue`, `WantsUpgrade`, `ConnId`, `RequestNo`, `PeerAddr` | request head accessors; valid until the request is released; `Headers` is read-only by contract | loop when unshared; any holder when shared
`TExchange.ReleaseRequest` | the application is done with the request: body receiver closed, head unpinned | loop when unshared; any holder when shared
`TExchange.TryRead(out Chunk): TBodyReadStatus` | non-blocking body read | loop when unshared; any holder when shared
`TExchange.Read(Buf, Max): SizeInt` | blocking copy read; 0 = end | worker
`TExchange.ReadChunk(out Chunk): Boolean` | blocking zero-copy read; False = end; skips trailers | worker
`TExchange.ReadAll(var Dst, Limit): SizeInt` | blocking; appends the body to `Dst`; `EBodyTooLarge` | worker
`TExchange.ReadFrame(out Chunk): TBodyReadStatus` | `TryRead` that blocks instead of `brPending` | worker
`TExchange.DiscardBody` | closes the body receiver only | loop when unshared; any holder when shared
`TExchange.RequestTrailers: THttpHeaders` | the request trailers after `brTrailers` / `brEnd` | same as `TryRead`
`TExchange.BodyErrorKind`, `BodyErrorMessage`, `BodyErrorIsTimeout` | the last body error | same as `TryRead`
`TExchange.Status`, `ResponseVersion` | the status (default 200) and version (default `hv11`) | the answering thread, before the terminal call
`TExchange.SetReason(P, Len): Boolean` | a custom reason phrase; False for an invalid byte | the answering thread, before the terminal call
`TExchange.ResponseHeaders: THttpHeaders` | the response header list | the answering thread, before the terminal call
`TExchange.Respond(Body): Boolean` | terminal: known length or empty | any holder
`TExchange.RespondText(Status, Text, ContentType = 'text/plain; charset=utf-8'): Boolean` | terminal: `Status`, the `Content-Type` header and `Respond(BodyString(Text))` in one call; False (nothing touched) when canceled or already answered | any holder
`TExchange.RespondStream(Source): Boolean` | terminal: a `TBodySource` | any holder
`TExchange.BeginStream(HighWater = 65536): Boolean` | terminal: the exchange's own channel body | any holder
`TExchange.Fail(Msg): Boolean` | terminal: no response, the connection closes with a user error | any holder
`TExchange.Write(P, Len)`, `WriteString(S)`: `TWriteResult` | queue a chunk; park while full off the loop (`wrWouldBlock` on the loop) | any holder, after `BeginStream`
`TExchange.TryWrite(P, Len): TWriteResult` | queue a chunk; never parks | any holder, after `BeginStream`
`TExchange.Finish(Trailers = nil): Boolean` | end the streamed body | any holder, after `BeginStream`
`TExchange.AbortStream(Msg)` | end the streamed body with an error | any holder, after `BeginStream`
`TExchange.OnUpgrade(H)` | register the upgrade handler | loop, before answering
`TExchange.OnLoopThread: Boolean` | the caller is the loop thread (a query) | any
`TExchange.Offload(Pool, H)` | `Share` and queue on the pool; a worker runs `H.Run`; a second call raises `EExchangeState` | loop, from `Poll`, once per request
`TExchange.Share: TExchange` | switch to shared mode, +1 reference | loop
`TExchange.Release` | -1 reference; the last one recycles the exchange | any, after `Share`
`TExchange.Wake` | run the owning connection again | loop when unshared; any when shared
`TExchange.IsCanceled`, `Answered: Boolean` | the state | any (loop only when unshared)
`TExchange.SetBodyErrorText(Msg)` | the error text a `TBodySource` sets before `fpError` | loop
`TExchange.Loop: TLoop` | the owning loop | any
`TExchange.User: TObject`, `Tag: PtrInt` | per-request application state; nil / 0 at every request; not freed by the exchange | the holder
`TExchange.Attachment` | per-request state with a `Detach` callback | loop (set before `Offload` when a worker reads it)
`TExchange.Shared`, `RefCount`, `Offloaded`, `Owner`, `Generation`, `UpgradeSlot` | read-only state | any (`RefCount` atomic)
`TExchange.Head`, `Chan`, `Resp`, `ReqTrailers` | the public fields; `Chan` and `Resp` are the dispatcher's | internal except `Head` (read)
`TExchange.BeginRequest`, `FillHead`, `LinkUpgrade`, `CompleteCall`, `Cancel`, `Recycle`, `ReleaseTransport`, `Execute` | the dispatcher's and the pool's entry points | internal
`TBodyReadStatus` | `brData`, `brTrailers`, `brEnd`, `brPending`, `brError`, `brCanceled` | -
`TWriteResult` | `wrOk`, `wrWouldBlock`, `wrCanceled` | -
`TBodyErrorKind` | `bekUnexpectedEof`, `bekInvalidData`, `bekInvalidInput`, `bekIo`, `bekOther` | -
`EClientGone`, `EBodyError` (`Kind`), `EBodyTooLarge` | body read exceptions (section 6) | -
`EExchangeState` | a second `Offload`; `Share` in a state that does not allow it (section 9) | -
`TExchangeState` | `xsIdle`, `xsCalled`, `xsAnswered`, `xsCanceled`, `xsDone` | -
`TWakeTimer.Arm(Ex, DelayMs)`, `Fired`, `Cancel(Ex)` | an application timer that wakes the connection | loop
`TBodySource.SizeHint`, `IsEndStream`, `PollFrame`, `Done` | a response body produced piece by piece | loop (called by the dispatcher)
`TFramePoll` | `fpData`, `fpTrailers`, `fpEnd`, `fpError`, `fpPending` | -
`TChannelBody.Create(HighWater)`, `Reset(Ex, HighWater)`, `Push(var B, Block)`, `FinishStream(Trailers)`, `AbortWith(Msg)`, `Queued`, `EmptyWrite`, `Closed` | the bounded frame queue behind `BeginStream`; usable with `RespondStream` | producers: any; `PollFrame`/`Done`: loop
`TChannelBody.AutoFinish`, `WakeProducer`, `Deactivate` | called by the exchange | internal
`TUpgradeHandler.Upgraded(U)`, `UpgradeFailed(Msg)` | the upgrade callbacks | loop
`TUpgradeSlot`, `TUpgradeState`, `TUpgradePending` | the connection side of an upgrade | internal
`TExchangePool` (`Take`, `Give`, `FreeCount`, `Outstanding`) | the per-loop exchange pool | internal (loop)
`TConnObserver` hooks (section 11) | per-connection hooks | loop
`TConnParts` | `Transport`, `Rest`, `Src` handed over by `OnParts` | loop
`BodyCopy(Ex, P, Len): TBodyData` | a body that is a copy of `P^` in a pooled or heap block | any
`UpgradeSlotsLive`, `ExchangesLive` | object counters for tests | any (atomic)
`NoResponseFailures` | completions without a terminal call (section 12) | any (atomic)
`TExchange.NoResponseIsExpected` | keeps a `-Sa` build from raising for this request's completion without a terminal call (tests) | loop, or the worker before it returns
`TBodyChan`, `TChanItemKind`, `TChanPoll`, `TResponseSlot` | the body channel record and the response slot | internal

## bearings.rt.buf (the body API)

Member | Description | Thread
------ | ----------- | ------
`TBodyData` | one piece of response body: `Kind: TBodyKind` (`bkEmpty`, `bkMem`, `bkFile`), `P`, `Len`, `Own: TBodyOwnership`, `Ctx`, `ReleaseProc`, `Fd`, `Offset`, `CloseFd` | build: any; release: loop
`TBodyOwnership` | `boStatic`, `boString`, `boHeap`, `boExchange`, `boCustom` (how the memory is released) | -
`TBodyReleaseProc` | `procedure(Ctx: Pointer; Data: PByte)` for `boCustom` | loop
`BodyEmpty` | no bytes | any
`BodyStatic(P, Len)` | memory that outlives the write | any
`BodyString(S)` | a string; one reference held until released | any
`BodyHeap(P, Len)` | `GetMem` memory; `FreeMem` after the write | any
`BodyFile(Fd, Offset, Len, CloseAfter)` | a file range sent with sendfile | any
`ReleaseBody(var B)` | releases per `Own`, closes the file if `CloseFd`; `B` becomes `BodyEmpty` | loop (the dispatcher)
`TBlockPool`, `TBufBlock`, `TReadBuf`, `TBytesView`, `TByteVec`, `BlockAlloc`, `BlockFree`, `PoolClassIndex`, `POOL_*` | the buffer pool and the connection buffers | internal (loop)

## bearings.http.headers

Member | Description | Thread
------ | ----------- | ------
`THttpHeaders.Create(AEntryCapacity = 16, ADataCapacity = 1024)` | an empty list | any
`Clear` | removes every entry; keeps capacity | one thread at a time
`Add(Name, Value)` (2 overloads), `Append(Name, Value)` | append a field; validate; `EInvalidHeader` | one thread at a time
`Insert(Name, Value)` (2 overloads) | set the only value of `Name`; validate | one thread at a time
`SetValue(I, Value)` (2 overloads) | replace a value; validate | one thread at a time
`TryAdd`, `TryInsert`, `TrySetValue` | the same without exceptions: `THeaderCheck` | one thread at a time
`AddTrusted` (2 overloads), `InsertTrusted` (2 overloads), `SetValueTrusted` | no validation | one thread at a time
`AddExternal(NameOfs, NameLen, ValueOfs, ValueLen)` | a field whose bytes stay in the external buffer (the parser uses it) | one thread at a time
`Delete(I)`, `Remove(Name): SizeInt` | remove entries | one thread at a time
`SetExternalBase(Base)`, `Detach`, `ExternalBase` | the external buffer (parser side) | one thread at a time
`IndexOf` (2 overloads), `LastIndexOf`, `Contains`, `CountOf`, `Get`, `GetValue` | lookups (case-insensitive) | one thread at a time
`NamePtr`, `NameLen`, `ValuePtr`, `ValueLen`, `Name`, `Value`, `NameIs` | entry access | one thread at a time
`WireLength`, `WriteTo(Dst, NameCase)`, `AppendTo(var Buf, var Len, NameCase)` | serialization as `name: value\r\n` lines | one thread at a time
`Count`, `Entries[I]` | the entries (`THttpHeaderEntry`) | one thread at a time
`THeaderNameCase` | `hncLower`, `hncTitle`, `hncAsIs` | -
`THeaderCheck`, `EInvalidHeader` (`Check`) | the validation result and exception | -
`IsValidHeaderName`, `IsValidHeaderValue`, `CheckHeaderField`, `RaiseInvalidHeader`, `IsVisibleAscii` | the checks | any
`AsciiLower`, `AsciiEqualIgnoreCase`, `AsciiEqualIgnoreCaseStr`, `WriteTitleCase`, `WriteDecimal`, `FromDigits` | byte helpers | any
`ConnectionKeepAlive`, `ConnectionClose`, `ConnectionHas`, `ConnectionAnyClose`, `TeIsTrailers`, `HeaderValueListHas`, `ContentLengthParse`, `ContentLengthParseAll`, `TransferEncodingIsChunked`, `IsChunkedValue` | interpretation of header values | any
`HN_*` constants, `DEFAULT_MAX_HEADERS`, `MAX_HEADER_NAME_LEN` | lowercase header names and limits | -
`ValidatingMutatorCalls` | `-Sa` builds only: a counter for tests | any (atomic)

## bearings.http1.config

Member | Description | Thread
------ | ----------- | ------
`TH1Config` | the connection options (section 2) | plain value
`TH1ConnMode` | `cmPlain`, `cmWithUpgrades`, `cmWithoutShutdown` | -
`TTimeoutSetting` | `tsDefault`, `tsDisabled`, `tsMs` | -
`ConformanceH1Config`, `ProductionH1Config` | the presets | any
`ValidateH1Config(C, out Msg): Boolean` | checks a configuration | any
`ApplyH1Config(C, var Conn)` | applies it to a connection; `TServer` calls it | internal (loop)

## bearings.rt.stream

Member | Description | Thread
------ | ----------- | ------
`TRawListener.Readable(U)`, `Writable(U)` | callbacks of an attached stream | loop
`TRawListener.Shutdown(U)` | the server stops gracefully; default `U.Close` | loop
`TRawListener.Aborted(U)` | the stream is closed by force; release and do not use `U` after it | loop
`TUpgraded.Track(List)`, `Shutdown`, `TUpgradedList` | the server's per-loop list of upgraded streams and its graceful stop | loop
`TUpgraded.CreateFrom(Loop, Transport, Rest, FromSrc, OwnsTransport)` | the hand-off constructor (the dispatcher, or an `OnParts` receiver) | loop
`TUpgraded.Transport` | the transport | loop
`TUpgraded.Run`, `Abort` | the loop task's entry points | internal
`TUpgraded.Leftover(out P, out Len)`, `ConsumeLeftover(N)` | the bytes read before the hand-off | loop
`TUpgraded.Attach(L)` | stay on the loop with callbacks; nil removes them | loop
`TUpgraded.TryRead(Buf, Max)`, `TryWrite(Buf, Len)` | non-blocking socket calls; `> 0`, `0` EOF, `-errno` | loop
`TUpgraded.Detach(out Fd, out Rest): Boolean` | leave the loop; the caller owns the blocking `Fd` | loop (then `Fd`: any)
`TUpgraded.Close` | closes the socket and the task | loop
`TUpgraded.Taken: Boolean` | attached, detached or closed | loop

## bearings.ws.handshake, bearings.ws.conn, bearings.ws.frame

Member | Description | Thread
------ | ----------- | ------
`CheckRequest(Ex, Protocols): TWsHandshake` | checks the opening handshake; `Ok`, `Accept`, `Protocol`, `HttpStatus`, `Text` | loop
`CheckRequest(Ex, Protocols, Origins)` | the same, and refuses (403) an `Origin` not in `Origins` | loop
`CheckHandshake(Method, Version, IsUpgrade, Headers, Protocols)` | the same on the parts of a request | any
`AcceptValue(Key)` | base64(SHA-1(Key + GUID)) | any
`Respond101(Ex, R, H)`, `RespondHandshakeError(Ex, R)` | the answers | loop
`AcceptWebSocket(Ex, R, Handler, Cfg): Boolean` | 101 plus a `TWebSocket` for the connection | loop
`TWebSocketHandler.OnOpen`, `OnText`, `OnBinary`, `OnPong`, `OnWritable`, `OnError`, `OnClose` | the application's callbacks | loop
`TWebSocket.SendText`, `SendBinary`, `SendFrame`, `Ping`, `CloseWith`, `Abort`, `Queued`, `Closing`, `User` | sending and state | loop
`TWebSocket.PostText`, `PostBinary`, `PostFrame`, `AddRef`, `Release` | sending from another thread | any (`AddRef`: loop, or a holder)
`TWebSocket.DroppedMessages`, `Hook`, `HookData` | published messages missed; the hook of `bearings.ws.topics` | loop
`TWsFrame`, `WsTextFrame`, `WsBinaryFrame`, `WsMakeFrame`, `WsFrameValid` | prepared frames for broadcast | any
`TWsTopics.Create`, `Destroy` | the pub/sub registry (unit `bearings.ws.topics`), one per server | any (`Destroy`: after the server)
`TWsTopics.Subscribe(WS, Pattern)`, `Unsubscribe(WS, Pattern)` | topics with `+` and `#` wildcards | loop of WS, or a holder (posted)
`TWsTopics.Publish(Topic, Text, Exclude)`, `PublishBinary`, `PublishFrame` | one frame to every subscriber on every loop | any
`TWsTopics.CloseOnBackpressure` | abort a subscriber whose queue is at the mark, instead of dropping the message | set before the first publish
`WsPatternValid`, `WsTopicValid`, `SplitLevels` | the topic syntax | any
`TWebSocket.Create(Handler, Cfg, OwnsHandler)`, `Start(U)`, `TWsUpgradeHandler` | for an application with its own `TUpgradeHandler` | loop
`TWsConfig`, `DefaultWsConfig` | limits and timeouts | any
`TWsReader`, `WsEncodeHeader`, `TUtf8Check`, `WS_OP_*`, `WS_CLOSE_*` | the frame layer | any (one reader per connection)

## bearings.http.error

Member | Description | Thread
------ | ----------- | ------
`THyperError` and its predicates (`IsParse`, `IsParseTooLarge`, `IsParseVersionH2`, `IsUser`, `IsCanceled`, `IsClosed`, `IsIncompleteMessage`, `IsBodyWriteAborted`, `IsShutdown`, `IsTimeout`, `HasIoSource`) | why an HTTP message failed (section 9) | any (plain value)
`THyperErrorKind`, `THyperUserKind`, `TErrorCause` | its enumerations | -
`TPollResult` (`prOk`, `prErr`, `prPending`), `TPollOpt` (`poSome`, `poErr`, `poNone`, `poPending`) | results of the connection code's poll routines | internal
`EH1Panic` | a program error inside the HTTP/1 code | -
`TConnOutcome` | how a connection ended | -
`New*` (`NewParse`, `NewIncomplete`, `NewTooLarge`, `NewVersionH2`, `NewIo`, `NewHeaderTimeout`, `NewBodyDecode`, `NewBodyIo`, `NewBodyStatic`, `NewBodyWrite`, `NewBodyWriteAborted`, `NewShutdown`, `NewUserService`, `NewUserBody`, `NewUserHeader`, `NewUserUnsupportedStatusCode`, `NewUserManualUpgrade`, `NewClosed`) | constructors of error values (the connection code uses them) | any
`ErrorDescription(E, ConnText): string` | the log text of an error | any
`OutcomeOf(R, E): TConnOutcome` | maps a result to an outcome | any

## Also used directly

- `bearings.rt.loop`: `TLoop` (the loop a `TServiceFactory` receives:
  `Index`, `NowMs`, `NowNs`, `Timers`, `Blocks`, `Post(M)` from any
  thread, `Register` / `Unregister` on the loop thread), `TLoopTask`,
  `TIoTask`, `TLoopMsg` (`lmCall` runs `Proc(Loop, Arg)` on the loop),
  `LoopErrorProc` (the exception logger; default one line on stderr),
  `LoopTickProc` (assigned by `bearings.http.date`), `ReadyFromEpoll`.
  Everything runs on the loop thread except `Post`, `RequestStop` and
  `PostsInProgress`.
- `bearings.rt.workers`: `TWorkerPool`, `TWorkItem`, `TWorkerHooks`,
  `EWorkerPoolStopped`, `DEFAULT_SPIN_NS`, `CurrentWorkerIndex` (section
  4). `Submit`, `TrySubmit`, `QueueLength`, `Saturated`, `Alive`,
  `Executed`, `SpinNs`: any thread; `Shutdown`, `Destroy`: the owner, never
  a worker.
- `bearings.rt.net`: `TListenSpec`, `TAcceptMode`, `TSockAddrStorage`,
  `SockAddrToStr(Addr)` (the text of `Ex.PeerAddr^`), `RaiseFdLimit`
  (the soft descriptor limit up to the hard one; `Start` calls it with
  `TServerConfig.RaiseFdLimit`).
- `bearings.rt.cpu`: `DefaultLoopCount`, `UsableCpus`, `CgroupCpuLimit`,
  `PinCurrentThread`.
- `bearings.http1.role`: `THttpMethod` (`hmNone`, `hmOptions`, `hmGet`,
  `hmPost`, `hmPut`, `hmDelete`, `hmHead`, `hmTrace`, `hmConnect`,
  `hmPatch`, `hmExtension`), `THttpVersion` (`hv09`, `hv10`, `hv11`,
  `hv2`, `hv3`), `TResponseHead` (the record behind `Ex.Resp.Head`).
- `bearings.version`: `BEARINGS_VERSION`, `FPC_VERSION_TEXT`.
