{ M3 step S4 tests for the request body channel (design m3-transport.md
  3.3, 7.3): ports of the tests of hyper v1.12.0 src/body/chan.rs
  (error_queued_behind_accepted_data, trailers_follow_data_close,
  drop_wakes_only_an_open_peer) and src/body/incoming.rs (size_hint,
  channel_abort, channel_abort_when_buffer_is_full, channel_buffers_one,
  channel_empty, channel_ready, channel_wanter, channel_notices_closure;
  test_size_of and the nightly benches are not ported), plus the want
  transitions and the pin rules of TBodyChan (Held, Item, ToRelease).

  Wakes: on the loop both chan.rs wakers are the connection task, so a wake
  is observed as the owner task being queued (one run of the loop's run
  queue counts it).

  Not here: the ToRelease invariant under a worker stress test (7.3) needs
  Share and the worker pool (S7).
  Run: test_body_chan --all --format=plain }
program test_body_chan;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, fpcunit, testregistry, consoletestrunner,
  bearings.rt.buf, bearings.rt.loop, bearings.http.headers, bearings.http1.parser, bearings.http1.role, bearings.http1.decode,
  bearings.http.error, bearings.http.exchange;

type
  TOwnerTask = class(TLoopTask)
  public
    Runs: Integer;
    procedure Run; override;
    procedure Abort; override;
  end;

  TChanCase = class(TTestCase)
  protected
    FLoop: TLoop;
    FTask: TOwnerTask;
    FEx: TExchange;
    FBuf: TReadBuf;
    FLastRuns: Integer;
    procedure SetUp; override;
    procedure TearDown; override;
    { a pinned view of S's bytes (a block of a read buffer) }
    function View(const S: RawByteString): TBytesView;
    { wakes of the owner task since the last call }
    function Wakes: Integer;
    function Recv(out S: RawByteString; out E: THyperError): TChanPoll;
  end;

  TTestChanRs = class(TChanCase)
  published
    procedure Error_queued_behind_accepted_data;
    procedure Trailers_follow_data_close;
    procedure Drop_wakes_only_an_open_peer;
  end;

  TTestIncomingRs = class(TChanCase)
  published
    procedure Size_hint;
    procedure Channel_abort;
    procedure Channel_abort_when_buffer_is_full;
    procedure Channel_buffers_one;
    procedure Channel_empty;
    procedure Channel_ready;
    procedure Channel_wanter;
    procedure Channel_notices_closure;
  end;

  TTestChanExtra = class(TChanCase)
  published
    procedure Want_transitions;
    procedure Send_after_receiver_closed;
    procedure Error_does_not_displace_data_and_only_one_pending;
    procedure Trailers_sent_once;
    procedure Close_receiver_releases_pins;
    procedure Poll_ready_releases_to_release;
    procedure Close_sender_twice_wakes_once;
    procedure Pending_error_wakes_sender_only_on_want_transition;
  end;

procedure TOwnerTask.Run;
begin
  Inc(Runs);
end;

procedure TOwnerTask.Abort;
begin
end;

procedure TChanCase.SetUp;
begin
  FLoop := TLoop.Create(0);
  FTask := TOwnerTask.Create;
  FTask.Loop := FLoop;
  FEx := TExchange.Create;
  FEx.BeginRequest(FTask);
  FBuf := Default(TReadBuf);
  FLastRuns := 0;
end;

procedure TChanCase.TearDown;
begin
  FEx.Free;
  FBuf.Done;
  FLoop.Free;                        { unlinks the task if it is still queued }
  FTask.Free;
end;

function TChanCase.View(const S: RawByteString): TBytesView;
begin
  FBuf.Reserve(Length(S), nil);
  Move(S[1], FBuf.SpareData^, Length(S));
  FBuf.AdvanceMut(Length(S));
  Result := FBuf.SplitTo(Length(S));
end;

function TChanCase.Wakes: Integer;
begin
  if FTask.Queued then
    FLoop.RunIteration;
  Result := FTask.Runs - FLastRuns;
  FLastRuns := FTask.Runs;
end;

function TChanCase.Recv(out S: RawByteString; out E: THyperError): TChanPoll;
var
  V: TBytesView;
begin
  S := '';
  E := Default(THyperError);
  Result := FEx.Chan.PollNext(V, E);
  if Result = cnData then
  begin
    SetString(S, PAnsiChar(V.P), V.Len);
    V.Release;
  end;
end;

{ ================= chan.rs ================= }

procedure TTestChanRs.Error_queued_behind_accepted_data;
var
  S: RawByteString;
  E: THyperError;
begin
  { chan.rs:250-259 }
  FEx.Chan.Open(False);
  AssertTrue('try_send_data', FEx.Chan.TrySendData(View('data')));
  FEx.Chan.SendError(NewIncomplete);
  FEx.Chan.CloseSender;
  AssertTrue(Recv(S, E) = cnData);
  AssertEquals('data', S);
  AssertTrue('error', Recv(S, E) = cnError);
  AssertTrue(E.IsIncompleteMessage);
  AssertTrue('none', Recv(S, E) = cnEnd);
end;

procedure TTestChanRs.Trailers_follow_data_close;
var
  S: RawByteString;
  E: THyperError;
  Ch: TByteSlice;
begin
  { chan.rs:261-270 }
  FEx.Chan.Open(False);
  FEx.ReqTrailers.Add('x-trailer', 'value');
  AssertTrue('try_send_trailers', FEx.Chan.TrySendTrailers);
  FEx.Chan.CloseSender;
  AssertTrue('none', Recv(S, E) = cnEnd);
  AssertTrue('take_trailers', FEx.Chan.TakeTrailers);
  AssertEquals('value', FEx.RequestTrailers.GetValue('x-trailer'));
  { the same through Incoming::poll_frame }
  FEx.Chan.Open(False);
  AssertTrue(FEx.Chan.TrySendTrailers);
  FEx.Chan.CloseSender;
  AssertTrue('trailers frame', FEx.TryRead(Ch) = brTrailers);
  AssertTrue('then end', FEx.TryRead(Ch) = brEnd);
  AssertTrue('still end', FEx.TryRead(Ch) = brEnd);
end;

procedure TTestChanRs.Drop_wakes_only_an_open_peer;
var
  Closed: Boolean;
  S: RawByteString;
  E: THyperError;
begin
  { chan.rs:272-311 }
  { A receiver dropped after the sender does not wake the sender's stale waker. }
  FEx.Chan.Open(True);
  AssertFalse('poll_ready pending', FEx.Chan.PollReady(Closed));
  FEx.Chan.CloseSender;
  FEx.Chan.CloseReceiver;
  AssertEquals(0, Wakes);
  { Nor does a sender dropped after the receiver. }
  FEx.Chan.Open(False);
  AssertTrue('poll_next pending', Recv(S, E) = cnPending);
  FEx.Chan.CloseReceiver;
  FEx.Chan.CloseSender;
  AssertEquals(0, Wakes);
  { An open peer is still woken to observe the close. }
  FEx.Chan.Open(True);
  AssertFalse(FEx.Chan.PollReady(Closed));
  FEx.Chan.CloseReceiver;
  AssertEquals(1, Wakes);
  FEx.Chan.CloseSender;
  FEx.Chan.Open(False);
  AssertTrue(Recv(S, E) = cnPending);
  FEx.Chan.CloseSender;
  AssertEquals(1, Wakes);
  FEx.Chan.CloseReceiver;
end;

{ ================= incoming.rs ================= }

procedure TTestIncomingRs.Size_hint;
var
  Msg: TParsedRequestHead;
  V: TBytesView;
  Ch: TByteSlice;
begin
  { incoming.rs:412-428: empty -> exact 0, channel (chunked) -> unknown,
    new_channel(4) -> exact 4; ContentLength is the size hint (-1 unknown) }
  V := Default(TBytesView);
  Msg := Default(TParsedRequestHead);
  Msg.Decode := DECODED_LENGTH_ZERO;
  FEx.FillHead(Msg, V, 1);
  AssertEquals('empty', 0, FEx.ContentLength);
  AssertTrue('Incoming::empty(): end at once', FEx.TryRead(Ch) = brEnd);
  Msg.Decode := DECODED_LENGTH_CHUNKED;
  FEx.FillHead(Msg, V, 1);
  AssertEquals('channel', -1, FEx.ContentLength);
  Msg.Decode := 4;
  FEx.FillHead(Msg, V, 1);
  AssertEquals('channel with length', 4, FEx.ContentLength);
end;

procedure TTestIncomingRs.Channel_abort;
var
  Ch: TByteSlice;
begin
  { incoming.rs:430-439: tx.abort() = send_error(new_body_write_aborted()), then drop }
  FEx.Chan.Open(False);
  FEx.Chan.SendError(NewBodyWriteAborted(0));
  FEx.Chan.CloseSender;
  AssertTrue('error', FEx.TryRead(Ch) = brError);
end;

procedure TTestIncomingRs.Channel_abort_when_buffer_is_full;
var
  Ch: TByteSlice;
  S: RawByteString;
begin
  { incoming.rs:441-461 }
  FEx.Chan.Open(False);
  AssertTrue('send 1', FEx.Chan.TrySendData(View('chunk 1')));
  { buffer is full, but can still send abort }
  FEx.Chan.SendError(NewBodyWriteAborted(0));
  FEx.Chan.CloseSender;
  AssertTrue('item 1', FEx.TryRead(Ch) = brData);
  SetString(S, PAnsiChar(Ch.P), Ch.Len);
  AssertEquals('chunk 1', S);
  AssertTrue('error', FEx.TryRead(Ch) = brError);
end;

procedure TTestIncomingRs.Channel_buffers_one;
var
  V2: TBytesView;
  S: RawByteString;
begin
  { incoming.rs:463-472 }
  FEx.Chan.Open(False);
  AssertTrue('send 1', FEx.Chan.TrySendData(View('chunk 1')));
  V2 := View('chunk 2');
  AssertFalse('buffer is now full', FEx.Chan.TrySendData(V2));
  SetString(S, PAnsiChar(V2.P), V2.Len);
  AssertEquals('chunk 2 comes back', 'chunk 2', S);
  V2.Release;
  FEx.Chan.CloseReceiver;
end;

procedure TTestIncomingRs.Channel_empty;
var
  Ch: TByteSlice;
begin
  { incoming.rs:474-481 }
  FEx.Chan.Open(False);
  FEx.Chan.CloseSender;
  AssertTrue('none', FEx.TryRead(Ch) = brEnd);
end;

procedure TTestIncomingRs.Channel_ready;
var
  Closed: Boolean;
begin
  { incoming.rs:483-491 }
  FEx.Chan.Open(False);
  AssertTrue('tx is ready immediately', FEx.Chan.PollReady(Closed));
  AssertFalse(Closed);
end;

procedure TTestIncomingRs.Channel_wanter;
var
  Closed: Boolean;
  Ch: TByteSlice;
begin
  { incoming.rs:493-513 }
  FEx.Chan.Open(True);
  AssertFalse('tx isn''t ready before rx has been polled', FEx.Chan.PollReady(Closed));
  AssertTrue('poll rx.data', FEx.TryRead(Ch) = brPending);
  AssertEquals('rx poll wakes tx', 1, Wakes);
  AssertTrue('tx is ready after rx has been polled', FEx.Chan.PollReady(Closed));
end;

procedure TTestIncomingRs.Channel_notices_closure;
var
  Closed: Boolean;
begin
  { incoming.rs:515-532 }
  FEx.Chan.Open(True);
  AssertFalse('tx isn''t ready before rx has been polled', FEx.Chan.PollReady(Closed));
  FEx.Chan.CloseReceiver;
  AssertEquals('dropping rx wakes tx', 1, Wakes);
  AssertTrue('ready', FEx.Chan.PollReady(Closed));
  AssertTrue('Err(closed)', Closed);
end;

{ ================= extra ================= }

procedure TTestChanExtra.Want_transitions;
var
  Closed: Boolean;
  S: RawByteString;
  E: THyperError;
begin
  { want starts as !wanter; poll_next sets it and wakes the sender only on
    the false -> true transition (and when it takes an item) }
  FEx.Chan.Open(True);
  AssertFalse(FEx.Chan.Want);
  AssertFalse('no data accepted while want is false', FEx.Chan.TrySendData(Default(TBytesView)));
  AssertFalse(FEx.Chan.PollReady(Closed));
  AssertTrue(Recv(S, E) = cnPending);
  AssertTrue(FEx.Chan.Want);
  AssertEquals('transition wakes', 1, Wakes);
  AssertTrue(Recv(S, E) = cnPending);
  AssertEquals('no transition, no item: no wake', 0, Wakes);
  AssertTrue(FEx.Chan.PollReady(Closed));
  AssertTrue(FEx.Chan.TrySendData(View('x')));
  AssertEquals('send wakes the registered receiver', 1, Wakes);
  AssertFalse('slot full', FEx.Chan.PollReady(Closed));
  AssertTrue(Recv(S, E) = cnData);
  AssertEquals('taking the item wakes the sender', 1, Wakes);
  AssertTrue('slot free', FEx.Chan.PollReady(Closed));
  FEx.Chan.CloseSender;
  AssertEquals('drop(tx) wakes the receiver', 1, Wakes);
  AssertTrue(Recv(S, E) = cnEnd);
  AssertTrue('terminated', FEx.Chan.Terminated);
  AssertEquals('terminated: no wake', 0, Wakes);
end;

procedure TTestChanExtra.Send_after_receiver_closed;
var
  V: TBytesView;
  Closed: Boolean;
begin
  FEx.Chan.Open(False);
  FEx.Chan.CloseReceiver;
  V := View('late');
  AssertFalse('try_send_data fails', FEx.Chan.TrySendData(V));
  V.Release;
  FEx.Chan.SendError(NewIncomplete);
  AssertTrue('send_error ignored', FEx.Chan.ItemKind = ciNone);
  AssertFalse('try_send_trailers fails', FEx.Chan.TrySendTrailers);
  AssertTrue(FEx.Chan.PollReady(Closed));
  AssertTrue(Closed);
end;

procedure TTestChanExtra.Error_does_not_displace_data_and_only_one_pending;
var
  S: RawByteString;
  E: THyperError;
begin
  FEx.Chan.Open(False);
  AssertTrue(FEx.Chan.TrySendData(View('d')));
  FEx.Chan.SendError(NewBodyIo(104));
  FEx.Chan.SendError(NewIncomplete);
  AssertTrue(Recv(S, E) = cnData);
  AssertTrue(Recv(S, E) = cnError);
  AssertEquals('the first pending error', 104, E.Errno);
  AssertTrue('sender still open', Recv(S, E) = cnPending);
  FEx.Chan.CloseSender;
  AssertTrue(Recv(S, E) = cnEnd);
end;

procedure TTestChanExtra.Pending_error_wakes_sender_only_on_want_transition;
var
  S: RawByteString;
  E: THyperError;
  Closed: Boolean;
begin
  { decision 13 (S4 survivor 4): chan.rs poll_next takes a pending error and
    wakes the sender only when want went false -> true in this call; taking
    an item always wakes it }
  FEx.Chan.Open(False);                       { want = true from the start }
  AssertTrue(FEx.Chan.TrySendData(View('d')));
  FEx.Chan.SendError(NewBodyIo(104));         { behind the data: pending error }
  AssertFalse('slot full: the sender registers its waker', FEx.Chan.PollReady(Closed));
  Wakes;
  AssertTrue(Recv(S, E) = cnData);
  AssertEquals('taking the item wakes the sender', 1, Wakes);
  AssertFalse('a pending error: not ready, the sender registers again', FEx.Chan.PollReady(Closed));
  AssertTrue('the pending error', Recv(S, E) = cnError);
  AssertEquals(104, E.Errno);
  AssertEquals('no want transition: no wake for the pending error', 0, Wakes);
  { with a transition (want was false), the pending error wakes the sender }
  FEx.Chan.CloseSender;
  FEx.Free;
  FEx := TExchange.Create;
  FEx.BeginRequest(FTask);
  FEx.Chan.Open(True);                        { want = false }
  FEx.Chan.SendError(NewBodyIo(5));           { slot empty: the item }
  FEx.Chan.SendError(NewBodyIo(7));           { pending }
  AssertFalse(FEx.Chan.PollReady(Closed));
  Wakes;
  AssertTrue(Recv(S, E) = cnError);
  AssertEquals('the item first', 5, E.Errno);
  AssertEquals('item taken (and want transition): one wake', 1, Wakes);
  AssertFalse(FEx.Chan.PollReady(Closed));
  AssertTrue(Recv(S, E) = cnError);
  AssertEquals(7, E.Errno);
  AssertEquals('want already true: no wake', 0, Wakes);
  FEx.Chan.CloseSender;
end;

procedure TTestChanExtra.Trailers_sent_once;
begin
  FEx.Chan.Open(False);
  AssertTrue(FEx.Chan.TrySendTrailers);
  AssertFalse('Err(None) the second time', FEx.Chan.TrySendTrailers);
end;

procedure TTestChanExtra.Close_receiver_releases_pins;
var
  V1, V2, V3: TBytesView;
  Ch: TByteSlice;
  B: PBufBlock;
  S: RawByteString;
begin
  { three views of one block }
  S := 'firstsecondthird';
  FBuf.Reserve(Length(S), nil);
  Move(S[1], FBuf.SpareData^, Length(S));
  FBuf.AdvanceMut(Length(S));
  V1 := FBuf.SplitTo(5);
  V2 := FBuf.SplitTo(6);
  V3 := FBuf.SplitTo(5);
  B := V1.Block;
  AssertTrue('one block', (V2.Block = B) and (V3.Block = B));
  AssertEquals(3, B^.Pins);
  FEx.Chan.Open(False);
  AssertTrue(FEx.Chan.TrySendData(V1));
  AssertTrue(FEx.TryRead(Ch) = brData);
  AssertEquals('held by the receiver (+ V2, V3)', 3, B^.Pins);
  AssertTrue(FEx.Chan.TrySendData(V2));
  AssertTrue(FEx.TryRead(Ch) = brData);
  AssertEquals('the previous chunk is released by the next body call', 2, B^.Pins);
  AssertTrue(FEx.Chan.TrySendData(V3));
  FEx.DiscardBody;
  { chan.rs:218-227: drop(Receiver) only clears receiver_open; the item it
    never took stays in the shared state (and pins its block) until the
    Sender is dropped too (corrected in S5: conformance/conn-diff found the
    read-capacity difference this makes) }
  AssertEquals('drop(receiver): held released, the untaken item stays', 1, B^.Pins);
  AssertTrue('item kept', FEx.Chan.ItemKind = ciData);
  FEx.Chan.CloseSender;
  AssertEquals('drop(sender) too: the item goes', 0, B^.Pins);
  AssertTrue('item gone', FEx.Chan.ItemKind = ciNone);
end;

procedure TTestChanExtra.Poll_ready_releases_to_release;
var
  Closed: Boolean;
  V: TBytesView;
begin
  FEx.Chan.Open(False);
  V := View('w');
  FEx.Chan.ToRelease := V;
  AssertEquals(1, V.Block^.Pins);
  AssertTrue(FEx.Chan.PollReady(Closed));
  AssertEquals('released by the loop before the slot is filled again', 0, V.Block^.Pins);
  AssertTrue(FEx.Chan.ToRelease.Block = nil);
end;

procedure TTestChanExtra.Close_sender_twice_wakes_once;
var
  S: RawByteString;
  E: THyperError;
begin
  FEx.Chan.Open(False);
  AssertTrue(Recv(S, E) = cnPending);
  FEx.Chan.CloseSender;
  FEx.Chan.CloseSender;
  AssertEquals(1, Wakes);
end;

begin
  RegisterTest(TTestChanRs);
  RegisterTest(TTestIncomingRs);
  RegisterTest(TTestChanExtra);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
end.
