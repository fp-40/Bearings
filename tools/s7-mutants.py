#!/usr/bin/env python3
"""Step S7 evidence (docs/design.md section 9): the worker tests of
tests/unit/test_workers.pas fail on mutants of the code they cover.

For each mutant: copy src/ and tests/ into <out>/<id>/, replace one exact
snippet (it must occur exactly once), build test_workers with the run_all.sh
flags, run the named test (fpcunit --suite=<test>, 120 s timeout) and record
whether it failed (a failure, an error, a crash or the timeout count as
detected). A test named "DRD:<test>" checks the drd run instead: the copy is
built with -dWD_DRD and the test runs under build/tools/bin/valgrind
--tool=drd with tools/drd.supp (WD_ITER=20); detected = drd reports an error
or the test fails (these show that the drd run of run_all.sh can find a
missing lock). The unmutated copy must pass every named test, and its drd
runs must report 0 errors. Exit status 0 only when every mutant was detected
and every snippet was found.

Usage: tools/s7-mutants.py [out dir (default build/s7-mutants)] [mutant id ...]"""
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ROOT, 'build', 's7-mutants')
ONLY = set(sys.argv[2:])
FPC_UNIT = ['fpc', '-Mobjfpc', '-Sh', '-O2', '-gl', '-Cr', '-Co', '-Ct', '-Sa']
EX = 'src/http/bearings.http.exchange.pas'
WK = 'src/rt/bearings.rt.workers.pas'
SY = 'src/rt/bearings.rt.sync.pas'
SV = 'src/server/bearings.server.pas'
DS = 'src/http1/bearings.http1.dispatch.pas'
LP = 'src/rt/bearings.rt.loop.pas'

# (id, file, old, new, expected failing test)
M = [
    # cross-thread wake (1.7, 3.2.3 rule 5)
    ('wake-no-post', EX,
     "  if InterlockedCompareExchange(FWakeQueued, 1, 0) = 0 then\n  begin",
     "  if False then\n  begin",
     'Answer_from_worker'),
    # round 4: a handler that returns after its answer also wakes the loop through its last Release
    # (it drops the request, decision 15); the test whose handler keeps running after the answer
    ('respond-no-wake', EX,
     "  if InterlockedCompareExchange(FState, Ord(xsAnswered), Ord(xsCalled)) <> Ord(xsCalled) then\n"
     "  begin\n    B := Resp.Body;\n    Resp.Body := BodyEmpty;\n    ReleaseBody(B);\n    Exit(False);\n"
     "  end;\n  Wake;",
     "  if InterlockedCompareExchange(FState, Ord(xsAnswered), Ord(xsCalled)) <> Ord(xsCalled) then\n"
     "  begin\n    B := Resp.Body;\n    Resp.Body := BodyEmpty;\n    ReleaseBody(B);\n    Exit(False);\n"
     "  end;",
     'V3_complete_while_parked_in_read'),
    ('wake-msg-no-owner-wake', EX,
     "  if Ex.FShared then\n    Ex.SyncShared;\n  if Ex.FOwner <> nil then\n    Ex.FOwner.Wake;",
     "  if Ex.FShared then\n    Ex.SyncShared;",
     'Answer_from_worker'),
    # reference count and recycle (3.2.3 rules 3, 4)
    ('release-no-free-post', EX,
     "      FLoop.Post(@FreeMsg);              { FIFO after a WakeMsg this thread posted }",
     "      ;",
     'Share_release_balance_16_threads'),
    ('final-release-ignores-queued-wake', EX,
     "  if AtomicLoad(FWakeQueued) <> 0 then\n  begin\n    FFreePending := True;",
     "  if False then\n  begin\n    FFreePending := True;",
     'Wake_queued_at_last_release_delays_recycle'),
    ('transport-release-no-decrement', EX,
     "  HappensBefore(@FRefCount);\n  if InterLockedDecrement(FRefCount) = 0 then\n  begin\n    HappensAfter(@FRefCount);\n    FinalRelease;",
     "  HappensBefore(@FRefCount);\n  if InterLockedDecrement(FRefCount) = -1 then\n  begin\n    HappensAfter(@FRefCount);\n    FinalRelease;",
     'Answer_from_worker'),
    # cancel at every point (3.2.3 rule 6)
    # round 5: the CAS decides whether the cancel closes the receiver (S7-31); the mutant
    # leaves the state xsCalled and closes it as before
    ('cancel-no-cas', EX,
     "  HappensBefore(@FState);\n  if InterlockedCompareExchange(FState, Ord(xsCanceled), Ord(xsCalled)) = Ord(xsCalled) then\n",
     "  HappensBefore(@FState);\n  if True then\n",
     'Cancel_while_running'),
    # S7 fix round 4: the unpark moved from CancelShared into CloseReceiverFromLoop (every
    # loop-side close of the receiver unparks a parked reader, docs/design.md 6.2)
    ('cancel-no-unpark-reader', EX,
     "  ReceiverOpen := False;\n  if ReceiverParks then\n  begin\n    ReceiverParks := False;\n    DeferUnpark := True;\n  end;\n",
     "  ReceiverOpen := False;\n",
     'Cancel_while_parked_in_read'),
    ('done-no-unpark-producer', EX,
     "  FLock.Release;\n  if P then\n    FSpace.NotifyAll;\nend;\n\n{ TUpgradeSlot",
     "  FLock.Release;\nend;\n\n{ TUpgradeSlot",
     'Cancel_while_parked_in_write_taken'),
    ('transport-release-keeps-untaken-source', EX,
     "    if Resp.Source <> nil then\n    begin\n      Resp.Source.Done(Self);\n      Resp.Source := nil;\n    end;",
     "",
     'Cancel_while_parked_in_write_not_taken'),
    ('queued-job-skips-cancel-check', EX,
     "  if AtomicLoad(FState) = Ord(xsCanceled) then\n  begin\n    Chan.Lock.Release;\n    HappensAfter(@FState);\n    Exit(brCanceled);\n  end;\n",
     "",
     'Cancel_while_queued'),
    # request body on a worker (3.3)
    ('worker-receiver-not-parked', EX,
     "  Chan.ParkingReceiver := not Loop_;",
     "  Chan.ParkingReceiver := False;",
     'Worker_reads_body_with_continue'),
    ('worker-drops-view-on-its-thread', EX,
     "  if (not Shared) or OnLoop then\n  begin\n    V.Release;\n    Exit;\n  end;",
     "  if True then\n  begin\n    ClearView(V);\n    Exit;\n  end;",
     'To_release_hand_back_stress'),
    ('to-release2-not-released', EX,
     "  if ToRelease2.Block <> nil then\n    ToRelease2.Release;\nend;",
     "end;",
     'To_release_hand_back_stress'),
    ('read-copies-from-start', EX,
     "  Move((Chan.Held.P + FHeldPos)^, Buf^, Result);",
     "  Move(Chan.Held.P^, Buf^, Result);",
     'Worker_read_and_read_all'),
    ('body-error-kind-lost', EX,
     "  E := EBodyError.Create(BodyErrorMessage);\n  E.Kind := BodyErrorKind;",
     "  E := EBodyError.Create(BodyErrorMessage);\n  E.Kind := bekIo;",
     'Body_error_raises_body_error'),
    # stream writer (3.4, 3.6)
    ('stream-no-backpressure', EX,
     "    if (FQueued = 0) or (FQueued + B.Len <= FHighWater) then",
     "    if True then",
     'Stream_backpressure_frames_and_trailers'),
    # round 5: 'stream-no-consumer-wake' (the same mutation, named test
    # Stream_backpressure_frames_and_trailers) was removed: that test detects it only when the
    # consumer happens to wait (S7-26), so the script's result depended on scheduling (the
    # fourth S7 verifiers: SURVIVED in one full run); its deterministic form is
    # 'stream-no-consumer-wake-2' below (Stream_frame_wakes_the_waiting_consumer)
    # S7 fix round 7 (S7-43): the end of the stream is decided in DropHolder
    ('stream-no-auto-finish', EX,
     "      HappensAfter(@FChannel);\n      C.AutoFinish;\n    end;\n  end;\nend;",
     "      HappensAfter(@FChannel);\n    end;\n  end;\nend;",
     'Stream_ends_when_last_producer_releases'),
    ('handler-exception-not-caught', EX,
     "    on E: Exception do\n      HandlerRaised(E);",
     "    on E: EAbort do\n      HandlerRaised(E);",
     'Handler_exception_and_no_answer_fail'),
    ('body-copy-uses-loop-pool', EX,
     "  if (Ex <> nil) and (Ex.FLoop <> nil) and ((not Ex.FShared) or Ex.OnOwnLoop) then",
     "  if (Ex <> nil) and (Ex.FLoop <> nil) then",
     'Body_copy_on_worker_uses_heap'),
    # pool and parker (3.5, 1.7)
    ('spinner-not-cleared', WK,
     "      EnterCriticalSection(FLock);\n      FSpinners := 0;",
     "      EnterCriticalSection(FLock);",
     'Spin_then_park_loses_no_item'),
    ('submit-never-wakes', WK,
     "  if (FSpinners = 0) and (FIdleCount > 0) then\n  begin\n    Dec(FIdleCount);\n    W := FIdle[FIdleCount];\n  end;\n  LeaveCriticalSection(FLock);\n  if W <> nil then\n    W^.Parker.Unpark;\n  Result := True;",
     "  LeaveCriticalSection(FLock);\n  Result := True;",
     'Spin_then_park_loses_no_item'),
    ('unpark-no-futex-wake', SY,
     "  if InterlockedExchange(State, 1) = 2 then\n    SysFutex(@State, FUTEX_WAKE_PRIVATE, 1, nil);",
     "  InterlockedExchange(State, 1);",
     'Ping_pong_has_no_lost_wakeup'),
    ('park-loses-notification', SY,
     "  if InterlockedCompareExchange(State, 2, 0) <> 0 then\n  begin\n    InterlockedExchange(State, 0);\n    HappensAfter(@State);\n    Exit;\n  end;",
     "  InterlockedExchange(State, 2);",
     'Unpark_at_park_entry'),
    # drd: a side that skips the lock is reported (docs/design.md section 9, "drd clean")
    # (an IN: snippet removes every FLock.Acquire / FLock.Release inside that routine: removing
    # only the Acquire would keep the happens-before edges of the Release annotation)
    ('drd-channel-push-unlocked', EX,
     "IN:function TChannelBody.Push(", None,
     'DRD:Stream_backpressure_frames_and_trailers'),
    ('drd-channel-poll-frame-unlocked', EX,
     "IN:function TChannelBody.PollFrame(", None,
     'DRD:Stream_backpressure_frames_and_trailers'),
    # the server's pool
    ('server-no-pool', SV,
     "  if (FCfg.Workers >= 0) and (FWorkers = nil) then",
     "  if False then",
     'Server_offloaded_requests'),
    # S7 fix: the S7 verifier's findings and its surviving mutants (v-*)
    # S7 fix round 7 (S7-43): the holder decrement (which may end the stream) moved after the
    # reference count decrement, the S7-16 order the S7 verifier found
    ('autofinish-after-decrement', EX,
     "  DropHolder;\n  { the edge is announced after everything this reference did, the end of\n"
     "    the stream (and the wake it may post) included (S7 fix round 5, drd) }\n"
     "  HappensBefore(@FRefCount);\n  {$ifopt C+}\n  if Assigned(ReleaseBeforeDecrementHook) then\n"
     "    ReleaseBeforeDecrementHook(Self);\n  {$endif}\n  N := InterLockedDecrement(FRefCount);\n"
     "  {$ifopt C+}\n  if Assigned(ReleaseTestHook) then\n"
     "    ReleaseTestHook(Self, N);            { tests: the window after the decrement }\n  {$endif}\n",
     "  N := InterLockedDecrement(FRefCount);\n  {$ifopt C+}\n  if Assigned(ReleaseTestHook) then\n"
     "    ReleaseTestHook(Self, N);\n  {$endif}\n  DropHolder;\n",
     'Release_after_recycle_leaves_the_new_stream'),
    # the S7 verifier's v-autofinish-at-any-count, in the round-7 form: every holder decrement
    # ends the stream
    ('v-autofinish-at-any-count', EX,
     "    ReleaseRequestShared;\n    C := TChannelBody(AtomicLoadPtr(Pointer(FChannel)));\n    if C <> nil then\n"
     "    begin\n      HappensAfter(@FChannel);\n      C.AutoFinish;\n    end;\n  end;\nend;",
     "    ReleaseRequestShared;\n  end;\n  C := TChannelBody(AtomicLoadPtr(Pointer(FChannel)));\n"
     "  if C <> nil then\n    C.AutoFinish;\nend;",
     'Stream_two_producers_one_releases'),
    ('v-push-no-first-frame-rule', EX,
     "    if (FQueued = 0) or (FQueued + B.Len <= FHighWater) then",
     "    if (FQueued + B.Len <= FHighWater) then",
     'Stream_first_frame_above_high_water'),
    ('event-count-wakes-one', SY,
     "    SysFutex(@Seq, FUTEX_WAKE_PRIVATE, High(LongInt), nil);",
     "    SysFutex(@Seq, FUTEX_WAKE_PRIVATE, 1, nil);",
     'Stream_two_blocked_producers'),
    ('finish-no-claim', EX,
     "  FLock.Acquire;\n  if Ended then\n  begin\n    FLock.Release;\n    Exit(False);\n  end;\n"
     "  FFinishing := True;\n  FLock.Release;\n  Has :=",
     "  Has :=",
     'Second_finish_leaves_the_trailers'),
    ('v-close-from-loop-unpins-held', EX,
     "  Chan.Lock.Acquire;\n  Chan.CloseReceiverFromLoop;",
     "  Chan.Lock.Acquire;\n  Chan.CloseReceiver;",
     'Cancel_keeps_the_chunk_a_worker_holds'),
    ('v-offload-pool-stopped-keeps-ref', EX,
     "    InterLockedDecrement(FRefCount);\n    RaisePoolStopped;",
     "    RaisePoolStopped;",
     'Offload_on_a_stopped_pool'),
    ('v-sync-shared-keeps-head', EX,
     "  if Rel and (Head.View.Block <> nil) then\n  begin\n    V := Head.View;",
     "  if False and Rel and (Head.View.Block <> nil) then\n  begin\n    V := Head.View;",
     'Released_head_unpinned_on_wake'),
    ('v-wakemsg-no-sync', EX,
     "  if Ex.FShared then\n    Ex.SyncShared;\n  if Ex.FOwner <> nil then",
     "  if Ex.FOwner <> nil then",
     'Released_head_unpinned_on_wake'),
    ('v-readall-no-limit', EX,
     "    if (Limit > 0) and (Result + C.Len > Limit) then",
     "    if False then",
     'Read_all_limit_without_content_length'),
    ('v-wake-always-post', EX,
     "  if InterlockedCompareExchange(FWakeQueued, 1, 0) = 0 then\n  begin",
     "  InterlockedExchange(FWakeQueued, 1);\n  begin",
     'Wake_posts_one_message_while_queued'),
    ('v-pop-no-chain-wake', WK,
     "  if (FHead <> nil) and (FSpinners = 0) and (FIdleCount > 0) then\n  begin\n    Dec(FIdleCount);\n    Wake := FIdle[FIdleCount];",
     "  if False then\n  begin\n    Dec(FIdleCount);\n    Wake := FIdle[FIdleCount];",
     'Burst_behind_a_spinner_runs_in_parallel'),
    ('v-server-no-process-inbox', SV,
     "        FLoops[I].Loop.ProcessInbox;",
     "        ;",
     'Server_destroy_recycles_what_workers_release'),
    ('v-respond-shared-no-state-check', EX,
     "function TExchange.FailShared(const Msg: RawByteString; CheckHead: Boolean): Boolean;\nbegin\n"
     "  if not ClaimAnswer(CheckHead) then\n  begin\n    {$ifopt C+}\n    DbgClaimRefused;\n    {$endif}\n"
     "    Exit(False);\n  end;",
     "function TExchange.FailShared(const Msg: RawByteString; CheckHead: Boolean): Boolean;\nbegin",
     'Answer_from_worker'),
    ('debug-no-poison', EX,
     "    FillChar(V.P^, V.Len, $DD);",
     "    ;",
     'Debug_checks_and_poison'),
    ('debug-wake-no-recycled-check', EX,
     "  Assert(FState <> Ord(xsIdle), 'TExchange.Wake: the exchange was recycled');",
     "",
     'Debug_checks_and_poison'),
    ('debug-try-read-no-thread-check', EX,
     "  Assert(OnOwnLoop, 'TExchange.TryRead: an unshared exchange off its loop thread');",
     "",
     'Debug_checks_and_poison'),
    # second S7 fix (S7-23, S7-24): the second S7 verifier's findings and surviving mutants (v2-*)
    # round 4/5: a receiver closed before its end reads as brCanceled (round 5: the channel's
    # own Terminated, round 4: LoopClosed), which also turns a cancel's close into brCanceled,
    # so moving the state check before the lock alone is an equivalent mutant; the mutant
    # also reads a closed receiver as the end (the S7-23 race comes back only without either)
    ('v2-try-read-state-before-lock', EX,
     "  Loop_ := OnOwnLoop;\n  {$ifopt C+}\n  if Assigned(TryReadTestHook) then\n    TryReadTestHook(Self);\n  {$endif}\n"
     "  Chan.Lock.Acquire;\n",
     "  if AtomicLoad(FState) = Ord(xsCanceled) then\n    Exit(brCanceled);\n  Loop_ := OnOwnLoop;\n"
     "  {$ifopt C+}\n  if Assigned(TryReadTestHook) then\n    TryReadTestHook(Self);\n  {$endif}\n"
     "  Chan.Lock.Acquire;\n  Chan.Terminated := True;\n  if False then\n",
     'Cancel_before_the_read_takes_the_lock'),
    ('v2-no-answer-claim', EX,
     "    and (InterlockedCompareExchange(FAnswerClaim, 1, 0) = 0);",
     ";",
     'Concurrent_terminal_calls_leave_the_winner'),
    # v2-complete-shared-no-close was removed in S7 fix round 4: decision 15 replaced the
    # close at completion it checked (its mutation is now the code); d15-* below check the
    # opposite
    ('v2-release-transport-keeps-owner', EX,
     "  FOwner := nil;\n  { an answer the dispatcher never took",
     "  { an answer the dispatcher never took",
     'Complete_keeps_body_and_transport_release_detaches'),
    ('v2-cancel-shared-no-close', EX,
     "  if InterlockedCompareExchange(FState, Ord(xsCanceled), Ord(xsCalled)) = Ord(xsCalled) then\n"
     "    CloseBodyFromLoop;                   { unparks a reader parked in a body read }\n",
     "  InterlockedCompareExchange(FState, Ord(xsCanceled), Ord(xsCalled));\n",
     'Cancel_releases_the_untaken_item'),
    ('stream-no-consumer-wake-2', EX,
     "      W := FConsumerWaiting;\n      FConsumerWaiting := False;\n      Ex := FEx;\n      FLock.Release;\n      if W and (Ex <> nil) then\n        Ex.Wake;\n      Exit(wrOk);",
     "      W := FConsumerWaiting;\n      FConsumerWaiting := False;\n      Ex := FEx;\n      FLock.Release;\n      Exit(wrOk);",
     'Stream_frame_wakes_the_waiting_consumer'),
    # S7 fix round 4: decision 15 (the request lives until the handler releases it; the
    # third S7 verifier's major finding), its surviving mutants B, C, D, decisions 16, 17
    ('d15-complete-shared-closes', EX,
     "  SyncShared;\n  if (FUpgrade <> nil) and (FUpgrade.Handler = nil) then\n"
     "    FUpgrade.RxAlive := False;\n  if InterlockedCompareExchange(FState, Ord(xsDone)",
     "  CloseBodyFromLoop;\n  SyncShared;\n  if (FUpgrade <> nil) and (FUpgrade.Handler = nil) then\n"
     "    FUpgrade.RxAlive := False;\n  if InterlockedCompareExchange(FState, Ord(xsDone)",
     'V3_complete_while_parked_in_read'),
    ('d15-complete-shared-closes-b', EX,
     "  SyncShared;\n  if (FUpgrade <> nil) and (FUpgrade.Handler = nil) then\n"
     "    FUpgrade.RxAlive := False;\n  if InterlockedCompareExchange(FState, Ord(xsDone)",
     "  CloseBodyFromLoop;\n  SyncShared;\n  if (FUpgrade <> nil) and (FUpgrade.Handler = nil) then\n"
     "    FUpgrade.RxAlive := False;\n  if InterlockedCompareExchange(FState, Ord(xsDone)",
     'Complete_keeps_body_and_transport_release_detaches'),
    # the code before round 4: the completion closes the receiver and unparks nobody
    ('d15-complete-shared-closes-no-unpark', EX,
     "  SyncShared;\n  if (FUpgrade <> nil) and (FUpgrade.Handler = nil) then\n"
     "    FUpgrade.RxAlive := False;\n  if InterlockedCompareExchange(FState, Ord(xsDone)",
     "  if Chan.Active then\n  begin\n    Chan.Lock.Acquire;\n    Chan.ReceiverOpen := False;\n"
     "    Chan.Lock.Release;\n  end;\n  SyncShared;\n  if (FUpgrade <> nil) and (FUpgrade.Handler = nil) then\n"
     "    FUpgrade.RxAlive := False;\n  if InterlockedCompareExchange(FState, Ord(xsDone)",
     'V3_stream_then_read_parked'),
    # S7 fix round 7: DropHolder also ends the stream at 0 (S7-43); the mutant drops the request
    # drop only
    ('d15-release-keeps-request', EX,
     "    HappensAfter(@FHolders);\n    ReleaseRequestShared;\n    C := TChannelBody(",
     "    HappensAfter(@FHolders);\n    C := TChannelBody(",
     'Last_release_drops_the_request'),
    # round 5: LoopClosed is gone (S7-31, S7-33); its mutant became: a receiver closed before
    # its end reads as the end, and the dispatcher's guard drops the body without the error
    ('d15-closed-reads-end', EX,
     "    if Chan.Terminated then\n      Result := brEnd\n    else\n      Result := brCanceled;\n",
     "    Result := brEnd;\n",
     'Second_holder_release_request_unparks_the_reader'),
    ('d15-loop-closed-reads-end', DS,
     "    BodyTx := False;\n    Ex.Chan.SendError(NewIncomplete);\n    Ex.Chan.CloseSender;",
     "    BodyTx := False;\n    Ex.Chan.CloseSender;",
     'Server_abort_after_answer_gives_body_error'),
    ('d15-dispatcher-keeps-ended-sender', DS,
     "    BodyTx := False;\n    Ex.Chan.CloseSender;\n  end;\n  if InFlight <> nil then",
     "  end;\n  if InFlight <> nil then",
     'Server_worker_reads_after_its_answer'),
    ('v3-respond-take-back-leaks-body', EX,
     "    B := Resp.Body;\n    Resp.Body := BodyEmpty;\n    ReleaseBody(B);\n    Exit(False);\n  end;\n  Wake;\n"
     "  Result := True;\nend;\n\nfunction TExchange.RespondStreamShared",
     "    B := Resp.Body;\n    Resp.Body := BodyEmpty;\n    Exit(False);\n  end;\n  Wake;\n"
     "  Result := True;\nend;\n\nfunction TExchange.RespondStreamShared",
     'Respond_take_back_releases_the_body'),
    ('v3-publish-take-back-no-done', EX,
     "    Resp.Source := nil;\n    if Source <> nil then\n      Source.Done(Self);\n    Exit(False);",
     "    Resp.Source := nil;\n    Exit(False);",
     'Stream_take_back_calls_done'),
    ('v3-begin-stream-claim-late', EX,
     "    if not ClaimAnswer(True) then\n    begin\n      {$ifopt C+}\n      DbgClaimRefused;\n      {$endif}\n"
     "      Exit(False);\n    end;\n  end\n  else\n  begin\n    {$ifopt C+}\n    DbgLoopOnly;",
     "    if AtomicLoad(FState) <> Ord(xsCalled) then\n      Exit(False);\n  end\n  else\n  begin\n"
     "    {$ifopt C+}\n    DbgLoopOnly;",
     'Begin_stream_claims_before_the_channel'),
    ('d16-head-two-threads', EX,
     "  Assert((Old = nil) or (Old = Me),\n",
     "  Assert(True,\n",
     'Head_built_by_one_thread'),
    ('d16-head-after-answer', EX,
     "  Assert(AtomicLoad(FAnswerClaim) = 0,\n"
     "    'TExchange: a response head write after",
     "  Assert(True,\n    'TExchange: a response head write after",
     'Head_built_by_one_thread'),
    ('d16-claim-no-check', EX,
     "  Result := (W = nil) or (W = Pointer(PtrUInt(GetCurrentThreadId)));\n",
     "  Result := True;\n",
     'Terminal_call_by_another_thread_than_the_head'),
    ('d17-loop-only-no-assert', EX,
     "    Assert(OnOwnLoop, 'TExchange: a loop-only method of an unshared exchange called off its loop thread');",
     "    ;",
     'Debug_loop_only_and_wake_generation'),
    ('d17-wake-msg-no-gen-check', EX,
     "  Assert(Ex.FWakeGen = Ex.FGen, 'ExchangeWakeMsg: the exchange was recycled while its WakeMsg was queued');\n",
     "",
     'Debug_loop_only_and_wake_generation'),
    ('d17-wake-no-gen-store', EX,
     "    FWakeGen := FGen;\n",
     "",
     'Answer_from_worker'),
    # S7 fix round 5: the fourth S7 verifiers' findings (S7-31 to S7-34) and their mutants
    ('r5-head-check-state', EX,
     "  Assert(AtomicLoad(FAnswerClaim) = 0,\n",
     "  Assert((AtomicLoad(FState) = Ord(xsCalled)) and (AtomicLoad(FAnswerClaim) = 0),\n",
     'Head_write_after_cancel_is_legal'),
    ('r5-close-receiver-no-unpark', EX,
     "    did not end (TExchange.TryReadShared) }\n  if ReceiverParks then\n  begin\n    ReceiverParks := False;\n"
     "    DeferUnpark := True;\n  end;\n",
     "    did not end (TExchange.TryReadShared) }\n",
     'Second_holder_release_request_unparks_the_reader'),
    ('r5-cancel-lost-closes', EX,
     "  if InterlockedCompareExchange(FState, Ord(xsCanceled), Ord(xsCalled)) = Ord(xsCalled) then\n"
     "    CloseBodyFromLoop;                   { unparks a reader parked in a body read }\n",
     "  InterlockedCompareExchange(FState, Ord(xsCanceled), Ord(xsCalled));\n  CloseBodyFromLoop;\n",
     'Cancel_lost_with_complete_body_keeps_the_chunk'),
    ('r5-cancel-lost-closes-b', EX,
     "  if InterlockedCompareExchange(FState, Ord(xsCanceled), Ord(xsCalled)) = Ord(xsCalled) then\n"
     "    CloseBodyFromLoop;                   { unparks a reader parked in a body read }\n",
     "  InterlockedCompareExchange(FState, Ord(xsCanceled), Ord(xsCalled));\n  CloseBodyFromLoop;\n",
     'Cancel_after_answer_while_parked_in_read'),
    ('r5-closed-check-before-active', EX,
     "  if not Chan.Active then\n  begin\n    { a request without a body (Incoming::empty()): its end is real }\n"
     "    Chan.Lock.Release;\n    Exit(brEnd);\n  end;\n",
     "",
     'Stale_cancel_does_not_end_the_next_request'),
    ('r5-share-no-call-holder', EX,
     "    FHolders := 2;                       { the call and the reference returned here }",
     "    FHolders := 1;",
     'Share_during_the_call_keeps_the_request'),
    ('r5-complete-keeps-call-holder', EX,
     "    InterlockedExchange(FState, Ord(xsDone));\n  DropHolder;\n",
     "    InterlockedExchange(FState, Ord(xsDone));\n",
     'Last_release_drops_the_request'),
    ('r5-share-no-raise', EX,
     "      if N <= 0 then\n        raise",
     "      if False then\n        raise",
     'Share_after_the_last_holder_raises'),
    ('r5-release-drops-at-one', EX,
     "  if InterLockedDecrement(FHolders) = 0 then\n",
     "  if InterLockedDecrement(FHolders) <= 1 then\n",
     'Release_leaving_another_holder_keeps_the_request'),
    ('r5-destroy-no-holder-wait', SV,
     "    if (Out = 0) and (Posts = 0) then\n      Break;",
     "    Break;",
     'Server_destroy_waits_for_an_outside_holder'),
    ('r5-discard-body-check-late', EX,
     "  {$ifopt C+}\n  DbgLoopOnly;\n  {$endif}\n  if not Chan.Active then\n    Exit;\n  if not FShared then\n  begin\n    Chan.CloseReceiver;",
     "  if not Chan.Active then\n    Exit;\n  {$ifopt C+}\n  DbgLoopOnly;\n  {$endif}\n  if not FShared then\n  begin\n    Chan.CloseReceiver;",
     'Debug_loop_only_and_wake_generation'),
    # S7 fix round 6: the fifth S7 verifiers' findings (S7-37 to S7-39)
    ('r6-destroy-no-post-wait', SV,
     "    if (Out = 0) and (Posts = 0) then\n      Break;",
     "    if Out = 0 then\n      Break;",
     'Server_destroy_waits_for_a_poster_to_leave_post'),
    ('r6-post-no-count', LP,
     "  AtomicInc(Posting);\n  {$ifopt C+}\n  if Assigned(PostBeforePushHook) then",
     "  {$ifopt C+}\n  if Assigned(PostBeforePushHook) then",
     'Server_destroy_waits_for_a_poster_to_leave_post'),
    # the round-5 code: FAbortMsg cleared after the lock was released
    ('r6-reset-abort-msg-unlocked', EX,
     "  if Pointer(FAbortMsg) <> nil then\n    FAbortMsg := '';\n  FLock.Release;\nend;",
     "  FLock.Release;\n  if Pointer(FAbortMsg) <> nil then\n    FAbortMsg := '';\nend;",
     'Reset_and_abort_race_keeps_the_message_counts'),
    ('r6-reset-abort-msg-unlocked-drd', EX,
     "  if Pointer(FAbortMsg) <> nil then\n    FAbortMsg := '';\n  FLock.Release;\nend;",
     "  FLock.Release;\n  if Pointer(FAbortMsg) <> nil then\n    FAbortMsg := '';\nend;",
     'DRD:Reset_and_abort_race_keeps_the_message_counts'),
    # the round-5 code (and the verifier's my5 in its weaker form)
    ('r6-empty-write-active', EX,
     "  if Ended then\n    Result := wrCanceled\n  else\n    Result := wrOk;\n  FLock.Release;",
     "  if FActive then\n    Result := wrOk\n  else\n    Result := wrCanceled;\n  FLock.Release;",
     'Empty_write_after_the_stream_ended'),
    ('r6-claim-not-undone', EX,
     "    InterLockedExchange(FAnswerClaim, 0);\n    DbgClaimRefusedFlag := True;",
     "    DbgClaimRefusedFlag := True;",
     'Claim_refused_by_the_head_check_lets_the_job_answer'),
    ('r6-job-fail-checks-head', EX,
     "  if not FailShared(Msg, False) then",
     "  if not FailShared(Msg, True) then",
     'Claim_refused_by_the_head_check_lets_the_job_answer'),
    ('r6-refused-respond-keeps-body', EX,
     "    B := Body;\n    ReleaseBody(B);\n    {$ifopt C+}\n    DbgClaimRefused;",
     "    {$ifopt C+}\n    DbgClaimRefused;",
     'Claim_refused_by_the_head_check_lets_the_job_answer'),
    ('r6-execute-no-finally', EX,
     "  try\n    RunHandler;\n  finally\n    Release;\n  end;",
     "  RunHandler;\n  Release;",
     'Job_error_path_exception_releases_the_reference'),
    # the round-5 code: an unshared closed receiver reads as the end
    ('r6-unshared-closed-reads-end', EX,
     "    if Chan.Terminated then\n      Exit(brEnd);\n    Exit(brCanceled);",
     "    Exit(brEnd);",
     'Read_after_the_request_was_dropped_is_not_the_end'),
    ('r6-unshared-closed-reads-end-b', EX,
     "    if Chan.Terminated then\n      Exit(brEnd);\n    Exit(brCanceled);",
     "    Exit(brEnd);",
     'Server_inline_echo_needs_share'),
    ('r6-unshared-closed-always-canceled', EX,
     "    if Chan.Terminated then\n      Exit(brEnd);\n    Exit(brCanceled);",
     "    Exit(brCanceled);",
     'Read_after_the_request_was_dropped_is_not_the_end'),
    # the contract verifier's my9
    ('r6-shared-closed-after-end-canceled', EX,
     "    if Chan.Terminated then\n      Result := brEnd\n    else\n      Result := brCanceled;\n",
     "    Result := brCanceled;\n",
     'Read_after_the_end_and_release_is_the_end'),
    # S7 fix round 7: the sixth S7 verifiers' findings (S7-43 to S7-46)
    # the round-6 rule: Release ends the stream when the reference count it loaded is 2 (itself
    # and the transport), then decrements with a CAS; DropHolder does not end it
    ('r7-round6-autofinish-rule', EX,
     "  Assert(FShared, 'TExchange.Release: the exchange was not shared');\n  DropHolder;\n  { the edge is announced after everything this reference did, the end of\n    the stream (and the wake it may post) included (S7 fix round 5, drd) }\n  HappensBefore(@FRefCount);\n  {$ifopt C+}\n  if Assigned(ReleaseBeforeDecrementHook) then\n    ReleaseBeforeDecrementHook(Self);\n  {$endif}\n  N := InterLockedDecrement(FRefCount);\n",
     "  Assert(FShared, 'TExchange.Release: the exchange was not shared');\n  DropHolder;\n"
     "  repeat\n    N := AtomicLoad(FRefCount);\n    if N = 2 then\n"
     "      if FChannel <> nil then\n        FChannel.AutoFinish;\n    HappensBefore(@FRefCount);\n"
     "    {$ifopt C+}\n    if Assigned(ReleaseBeforeDecrementHook) then\n      ReleaseBeforeDecrementHook(Self);\n"
     "    {$endif}\n  until InterlockedCompareExchange(FRefCount, N - 1, N) = N;\n  N := N - 1;\n",
     'Call_in_flight_keeps_the_stream_for_its_next_producer'),
    ('r7-round6-autofinish-rule-b', EX,
     [("  Assert(FShared, 'TExchange.Release: the exchange was not shared');\n  DropHolder;\n  { the edge is announced after everything this reference did, the end of\n    the stream (and the wake it may post) included (S7 fix round 5, drd) }\n  HappensBefore(@FRefCount);\n  {$ifopt C+}\n  if Assigned(ReleaseBeforeDecrementHook) then\n    ReleaseBeforeDecrementHook(Self);\n  {$endif}\n  N := InterLockedDecrement(FRefCount);\n",
     "  Assert(FShared, 'TExchange.Release: the exchange was not shared');\n  DropHolder;\n"
     "  repeat\n    N := AtomicLoad(FRefCount);\n    if N = 2 then\n"
     "      if FChannel <> nil then\n        FChannel.AutoFinish;\n    HappensBefore(@FRefCount);\n"
     "    {$ifopt C+}\n    if Assigned(ReleaseBeforeDecrementHook) then\n      ReleaseBeforeDecrementHook(Self);\n"
     "    {$endif}\n  until InterlockedCompareExchange(FRefCount, N - 1, N) = N;\n  N := N - 1;\n"),
      ("      HappensAfter(@FChannel);\n      C.AutoFinish;\n    end;\n  end;\nend;",
       "      HappensAfter(@FChannel);\n    end;\n  end;\nend;")],
     None,
     'Last_producer_is_decided_at_the_holder_decrement'),
    ('r7-unshared-completion-keeps-stream', EX,
     "  if FChannel <> nil then\n    FChannel.AutoFinish;\nend;",
     "end;",
     'Inline_stream_without_finish_ends_at_completion'),
    ('r7-second-offload-allowed', EX,
     "  if FHandler <> nil then\n    raise Exception.Create('TExchange.Offload: the request was already offloaded');",
     "",
     'Second_offload_raises'),
    ('r7-post-count-after-push', LP,
     "  AtomicInc(Posting);\n  {$ifopt C+}\n  if Assigned(PostBeforePushHook) then\n    PostBeforePushHook(Self);\n"
     "  {$endif}\n  First := Inbox.Push(@M^.Node);",
     "  {$ifopt C+}\n  if Assigned(PostBeforePushHook) then\n    PostBeforePushHook(Self);\n"
     "  {$endif}\n  First := Inbox.Push(@M^.Node);\n  AtomicInc(Posting);",
     'Post_counts_the_poster_before_the_push'),
    ('r7-call-not-marked', DS,
     "  Ex.DbgServiceCall(True);",
     "  Ex.DbgServiceCall(False);",
     'DISP:Call_that_answers_asserts'),
    ('r7-respond-in-call-unchecked', EX,
     "  Assert(not FInServiceCall, 'TExchange.Respond in THttpService.Call",
     "  Assert(True, 'TExchange.Respond in THttpService.Call",
     'DISP:Call_that_answers_asserts'),
    ('r7-try-read-in-call-unchecked', EX,
     "  Assert(not FInServiceCall, 'TExchange.TryRead in THttpService.Call",
     "  Assert(True, 'TExchange.TryRead in THttpService.Call",
     'DISP:Call_that_reads_asserts'),
]


def copy_tree(dst):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    os.makedirs(dst)
    ign = shutil.ignore_patterns('target', '*.o', '*.ppu')
    for d in ('src', 'tests/support'):
        shutil.copytree(os.path.join(ROOT, d), os.path.join(dst, d), ignore=ign)
    os.makedirs(os.path.join(dst, 'tests', 'unit'))
    for t in ('test_workers.pas', 'test_h1_dispatch.pas'):
        shutil.copy(os.path.join(ROOT, 'tests', 'unit', t), os.path.join(dst, 'tests', 'unit'))


def mutate(tree, rel, old, new):
    if isinstance(old, list):
        # several (old, new) replacements in one file (S7 fix round 7: the round-6 code of two
        # routines)
        for o, n in old:
            err = mutate(tree, rel, o, n)
            if err:
                return err
        return None
    p = os.path.join(tree, rel)
    s = open(p, encoding='latin-1').read()
    if old.startswith('IN:'):
        head = old[3:]
        if s.count(head) != 1:
            return 'routine found %d times' % s.count(head)
        a = s.index(head)
        b = s.index('\nend;\n', a)
        body = s[a:b]
        n = body.count('FLock.Acquire;') + body.count('FLock.Release;')
        if n == 0:
            return 'no FLock call in the routine'
        body = body.replace('FLock.Acquire;', ';').replace('FLock.Release;', ';')
        open(p, 'w', encoding='latin-1').write(s[:a] + body + s[b:])
        return None
    n = s.count(old)
    if n != 1:
        return 'snippet found %d times' % n
    open(p, 'w', encoding='latin-1').write(s.replace(old, new))
    return None


VG = os.path.join(ROOT, 'build', 'tools', 'bin', 'valgrind')
SUPP = os.path.join(ROOT, 'tools', 'drd.supp')


def build(tree, work, drd=False, disp=False):
    # disp (S7 fix round 7): test_h1_dispatch, built as run_all.sh builds it (-dWD_DEBUG, its own
    # unit directory)
    u = os.path.join(work, 'ud' if disp else 'u')
    os.makedirs(u, exist_ok=True)
    fu = ['-Fu' + os.path.join(tree, d) for d in ('src/rt', 'src/http', 'src/http1', 'src/server',
                                                  'tests/support', 'tests/unit')]
    prog = 'test_h1_dispatch.pas' if disp else 'test_workers.pas'
    b = subprocess.run(FPC_UNIT + (['-dWD_DRD'] if drd else []) + (['-dWD_DEBUG'] if disp else []) + fu
                       + ['-FU' + u, '-FE' + work, os.path.join(tree, 'tests', 'unit', prog)],
                       capture_output=True, text=True)
    return b.returncode == 0, (b.stdout + b.stderr)[-300:]


def run_test(work, test):
    drd = test.startswith('DRD:')
    if test.startswith('DISP:'):
        test = test[5:]
        cmd = [os.path.join(work, 'test_h1_dispatch'), '--suite=' + test, '--format=plain']
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            out = r.stdout + r.stderr
        except subprocess.TimeoutExpired:
            return True, 'timeout: the test did not finish'
        m = re.search(r'Number of errors:\s+(\d+)\s+Number of failures:\s+(\d+)', out)
        if not m:
            return True, 'crashed (exit %d)' % r.returncode
        errs, fails = int(m.group(1)), int(m.group(2))
        if errs + fails == 0:
            return False, 'passed'
        msg = re.search(r'(?:Exception message|Message):\s+(.*)', out)
        return True, '%d error(s), %d failure(s): %s' % (errs, fails, msg.group(1).strip()[:150] if msg else '')
    if drd:
        test = test[4:]
        cmd = [VG, '--tool=drd', '--fair-sched=yes', '--suppressions=' + SUPP, os.path.join(work, 'test_workers'),
               '--suite=' + test, '--format=plain']
    else:
        cmd = [os.path.join(work, 'test_workers'), '--suite=' + test, '--format=plain']
    env = dict(os.environ, WD_ITER='20') if drd else None
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600 if drd else 120, env=env)
        out = r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return True, 'timeout: the test did not finish'
    if drd:
        m = re.search(r'ERROR SUMMARY: (\d+) errors', out)
        if m and int(m.group(1)) > 0:
            c = re.search(r'Conflicting (?:load|store) by thread \d+ at \S+ size \d+\n\S+\s+at \S+: (\S+)', out)
            return True, 'drd: %s error(s)%s' % (m.group(1), (', first in ' + c.group(1)[:90]) if c else '')
        if not m:
            return True, 'drd: no ERROR SUMMARY (exit %d)' % r.returncode
    m = re.search(r'Number of errors:\s+(\d+)\s+Number of failures:\s+(\d+)', out)
    if not m:
        return True, 'crashed (exit %d)' % r.returncode
    errs, fails = int(m.group(1)), int(m.group(2))
    if errs + fails == 0:
        return False, 'passed'
    msg = re.search(r'(?:Exception message|Message):\s+(.*)', out)
    return True, '%d error(s), %d failure(s): %s' % (errs, fails, msg.group(1).strip()[:150] if msg else '')


def main():
    os.makedirs(OUT, exist_ok=True)
    ok = True
    base = os.path.join(OUT, 'base')
    copy_tree(base)
    built, log = build(base, base)
    if not built:
        print('base build FAILED: ' + log)
        return 1
    built, log = build(base, base, disp=True)
    if not built:
        print('base dispatch build FAILED: ' + log)
        return 1
    based = os.path.join(OUT, 'base-drd')
    copy_tree(based)
    built, log = build(based, based, True)
    if not built:
        print('base drd build FAILED: ' + log)
        return 1
    tests = sorted({m[4] for m in M})
    for t in tests:
        det, why = run_test(based if t.startswith('DRD:') else base, t)
        print('base %-45s %s' % (t, 'FAILS: ' + why if det else 'passes'))
        if det:
            ok = False
    for mid, rel, old, new, test in M:
        if ONLY and mid not in ONLY:
            continue
        tree = os.path.join(OUT, mid)
        copy_tree(tree)
        err = mutate(tree, rel, old, new)
        if err:
            print('%-40s %s: %s' % (mid, 'SNIPPET', err))
            ok = False
            continue
        built, log = build(tree, tree, test.startswith('DRD:'), test.startswith('DISP:'))
        if not built:
            print('%-40s build failed (counts as not detected): %s' % (mid, log.strip().splitlines()[-1:]))
            ok = False
            continue
        det, why = run_test(tree, test)
        print('%-40s %-45s %s  %s' % (mid, test, 'KILLED' if det else 'SURVIVED', why))
        if not det:
            ok = False
        shutil.rmtree(tree)
    print('s7-mutants: %s' % ('passed (every mutant detected)' if ok else 'FAILED'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
