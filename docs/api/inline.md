# 3. Answering inline on the loop

The cheapest way to answer: do it inside `Poll`, on the loop thread.

```pascal
function THelloCall.Poll(Ex: TExchange): TCallPoll;
begin
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  Ex.Respond(BodyStatic(@GREETING[0], Length(GREETING)));
  Result := cpReady;
end;
```

Rules on the loop thread:

- Never block. The only body read allowed is `TryRead`, which returns
  `brPending` instead of waiting; the call is polled again when data
  arrives, so a call that reads the body inline keeps its position in the
  body between polls (the `Ex.User` or `Ex.Tag` field, or the call object,
  can hold that state).
- `Write` on the loop thread never parks: when the stream queue is full it
  returns `wrWouldBlock`, like `TryWrite`. A streaming producer on the
  loop is better written as a `TBodySource` (section 5).
- An exception that escapes `Poll` aborts the connection task: the loop
  catches it, logs it through `LoopErrorProc` (default: one line on
  stderr) and closes the connection without a response.
- A call that returns `cpPending` must arrange a wake. `TWakeTimer` is the
  application timer for this: `Arm(Ex, DelayMs)` on the loop thread wakes
  the exchange's connection after `DelayMs`, so `Poll` runs again;
  `Fired` tells whether it did; `Cancel(Ex)` removes it. The record must
  not move while armed, and a timer armed for one request does not wake a
  later request on the same exchange (it checks the exchange's
  generation).
- Once the call completes (`Poll` returned `cpReady` and the connection
  took the response), the request is released: the head accessors are
  invalid and the body receiver is closed. A body that was not read is
  read and discarded, or the connection is closed.

Per-request state: `Ex.User: TObject` and `Ex.Tag: PtrInt` are free for
the application and are reset to nil / 0 at every request; the exchange
does not free `User`. `Ex.Attachment: TExchangeAttachment` is for state
the connection must detach itself: the exchange calls `Detach(Ex)` on the
loop thread when it is recycled or begins its next request.
