{ crun.server - the server process of one case (SPEC.md section 3): starts
  `sh -c 'exec <cmd> "$@"' sh --config <file>`, waits for its first stdout
  line "LISTENING <port>", reads every later stdout line as a JSON event
  (a line that is not JSON becomes an invalid_line event with the line),
  keeps stderr, sends control lines on stdin, and stops it ("exit", then
  SIGKILL after 500 ms).

  The child is created with fork and execve; between them it only calls
  async-signal-safe functions: it moves the pipe ends to 0, 1 and 2, closes
  every other descriptor (so a server never holds a socket or a pipe of a
  case that runs in parallel), restores the default SIGPIPE action and an
  empty signal mask.

  Test tooling only. }
unit crun.server;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, BaseUnix, crun.bytes, crun.json, crun.conn;

type
  TJArrayList = array of TJValue;

  { the events of one server, appended by its stdout reader }
  TEventLog = class
  private
    FLock: TCriticalSection;
    FEvent: PRTLEvent;
    FEvents: array of TJValue;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(V: TJValue);
    function Count: Integer;
    { copies of the events (the caller frees them with FreeEvents) }
    function Snapshot: TJArrayList;
    { the events, with the log locked until UnlockEvents (do not keep them) }
    function LockEvents: TJArrayList;
    procedure UnlockEvents;
    { waits until something was added or TimeoutMs passed }
    procedure WaitChange(TimeoutMs: Int64);
  end;

  TServerProc = class
  private
    FPid: TPid;
    FStdin, FStdout, FErrFd: cint;
    FStdoutThread, FStderrThread: TThread;
    FConfigPath: string;
    FStderrLock: TCriticalSection;
    FErrText: RawByteString;
    FExited: Boolean;
    FExitStatus: cint;
  public
    Port: Word;
    Events: TEventLog;
    { raises ECase (the message names the problem and the server's stderr) }
    constructor Spawn(const Cmd: RawByteString; Spec: TJValue);
    destructor Destroy; override;
    function StderrText: RawByteString;
    procedure SendLine(const Line: RawByteString);
    { the exit status text when the process has exited, else '' }
    function Exited: RawByteString;
    procedure Stop;
    procedure AppendStderr(const S: RawByteString);
  end;

procedure FreeEvents(var L: TJArrayList);

implementation

uses
  Unix;

var
  { serializes fork with the creation of the pipes, so that only the right
    child gets them (they are closed above 2 in the child anyway) }
  SpawnLock: TCriticalSection;
  Counter: Integer = 0;

{ ---- TEventLog ---- }

constructor TEventLog.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEvent := RTLEventCreate;
end;

destructor TEventLog.Destroy;
var
  K: Integer;
begin
  for K := 0 to High(FEvents) do
    FEvents[K].Free;
  RTLEventDestroy(FEvent);
  FLock.Free;
  inherited Destroy;
end;

procedure TEventLog.Add(V: TJValue);
begin
  FLock.Acquire;
  try
    SetLength(FEvents, Length(FEvents) + 1);
    FEvents[High(FEvents)] := V;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FEvent);
end;

function TEventLog.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FEvents);
  finally
    FLock.Release;
  end;
end;

function TEventLog.Snapshot: TJArrayList;
var
  K: Integer;
begin
  FLock.Acquire;
  try
    Result := nil;
    SetLength(Result, Length(FEvents));
    for K := 0 to High(FEvents) do
      Result[K] := FEvents[K].Clone;
  finally
    FLock.Release;
  end;
end;

function TEventLog.LockEvents: TJArrayList;
begin
  FLock.Acquire;
  Result := FEvents;
end;

procedure TEventLog.UnlockEvents;
begin
  FLock.Release;
end;

procedure TEventLog.WaitChange(TimeoutMs: Int64);
begin
  if TimeoutMs < 1 then
    TimeoutMs := 1;
  RTLEventWaitFor(FEvent, TimeoutMs);
end;

procedure FreeEvents(var L: TJArrayList);
var
  K: Integer;
begin
  for K := 0 to High(L) do
    L[K].Free;
  L := nil;
end;

{ ---- readers ---- }

type
  TStdoutReader = class(TThread)
  public
    Fd: cint;
    Proc: TServerProc;
    PortEvent: PRTLEvent;
    PortResult: RawByteString;       { '' = OK, else the error; valid once Ready }
    PortValue: Word;
    Ready: Boolean;                  { the first line was read (or stdout ended) }
    procedure Execute; override;
  end;

  TStderrReader = class(TThread)
  public
    Fd: cint;
    Proc: TServerProc;
    procedure Execute; override;
  end;

procedure TStderrReader.Execute;
var
  Buf: array[0..4095] of AnsiChar;
  N: TSsize;
  S: RawByteString;
begin
  while True do
  begin
    N := fpRead(Fd, Buf[0], SizeOf(Buf));
    if (N < 0) and (fpgeterrno = ESysEINTR) then
      Continue;
    if N <= 0 then
      Break;
    SetString(S, PAnsiChar(@Buf[0]), N);
    Proc.AppendStderr(S);
  end;
end;

procedure TStdoutReader.Execute;
var
  Buf: array[0..65535] of AnsiChar;
  N: TSsize;
  Pending, Line, Text: RawByteString;
  Nl, Code: SizeInt;
  First: Boolean;
  V: TJValue;
  P: Integer;
begin
  Pending := '';
  First := True;
  PortResult := 'server closed stdout before LISTENING';
  while True do
  begin
    N := fpRead(Fd, Buf[0], SizeOf(Buf));
    if (N < 0) and (fpgeterrno = ESysEINTR) then
      Continue;
    if N <= 0 then
      Break;
    SetLength(Pending, Length(Pending) + N);
    Move(Buf[0], Pending[Length(Pending) - N + 1], N);
    while True do
    begin
      Nl := Pos(#10, Pending);
      if Nl = 0 then
        Break;
      Line := Copy(Pending, 1, Nl - 1);
      Delete(Pending, 1, Nl);
      if First then
      begin
        First := False;
        Text := TrimRight(Line);
        if StartsWith(Text, 'LISTENING ') then
        begin
          Val(Trim(Copy(Text, 11, MaxInt)), P, Code);
          if (Code = 0) and (P >= 0) and (P <= 65535) then
          begin
            PortValue := P;
            PortResult := '';
          end
          else
            PortResult := 'first stdout line must be "LISTENING <port>", got ' + JsonStr(Line + #10);
        end
        else
          PortResult := 'first stdout line must be "LISTENING <port>", got ' + JsonStr(Line + #10);
        WriteBarrier;
        Ready := True;
        RTLEventSetEvent(PortEvent);
        if PortResult <> '' then
          Exit;
        Continue;
      end;
      Text := TrimRight(Line);
      if Text = '' then
        Continue;
      try
        V := ParseJson(Text);
      except
        on EJsonError do
        begin
          V := TJValue.CreateKind(jkObj);
          V.Put('event', TJValue.CreateStr('invalid_line'));
          V.Put('line', TJValue.CreateStr(Text));
        end;
      end;
      Proc.Events.Add(V);
    end;
  end;
  if First then
  begin
    WriteBarrier;
    Ready := True;
    RTLEventSetEvent(PortEvent);
  end;
end;

{ ---- TServerProc ---- }

function MakePipe(out R, W: cint): Boolean;
var
  Fds: TFilDes;
begin
  Result := fpPipe(Fds) = 0;
  if Result then
  begin
    R := Fds[0];
    W := Fds[1];
    fpFcntl(R, F_SETFD, 1);   { FD_CLOEXEC }
    fpFcntl(W, F_SETFD, 1);
  end;
end;

constructor TServerProc.Spawn(const Cmd: RawByteString; Spec: TJValue);
var
  F: TextFile;
  InR, InW, OutR, OutW, ErrR, ErrW: cint;
  Argv: array[0..6] of PAnsiChar;
  A0, A1, A2, A3, A4, A5: RawByteString;
  Pid: TPid;
  Fd: cint;
  Empty: TSigSet;
  Rd: TStdoutReader;
  Er: TStderrReader;
  Deadline: Int64;
  Msg: RawByteString;
begin
  inherited Create;
  FPid := -1;
  FStdin := -1;
  FStdout := -1;
  FErrFd := -1;
  FStderrLock := TCriticalSection.Create;
  Events := TEventLog.Create;
  FConfigPath := Format('%sbearings-conformance-%d-%d.json',
    [IncludeTrailingPathDelimiter(GetTempDir(False)), fpGetPid, InterLockedIncrement(Counter)]);
  AssignFile(F, FConfigPath);
  try
    Rewrite(F);
    Write(F, JsonText(Spec));
    CloseFile(F);
  except
    on E: Exception do
      raise ECase.CreateFmt('cannot write %s: %s', [FConfigPath, E.Message]);
  end;

  A0 := 'sh';
  A1 := '-c';
  A2 := 'exec ' + Cmd + ' "$@"';
  A3 := 'sh';
  A4 := '--config';
  A5 := FConfigPath;
  Argv[0] := PAnsiChar(A0);
  Argv[1] := PAnsiChar(A1);
  Argv[2] := PAnsiChar(A2);
  Argv[3] := PAnsiChar(A3);
  Argv[4] := PAnsiChar(A4);
  Argv[5] := PAnsiChar(A5);
  Argv[6] := nil;
  fpSigEmptySet(Empty);

  SpawnLock.Acquire;
  try
    if not MakePipe(InR, InW) or not MakePipe(OutR, OutW) or not MakePipe(ErrR, ErrW) then
      raise ECase.CreateFmt('cannot spawn server %s: pipe: %s', [JsonStr(Cmd), SysErrorMessage(fpgeterrno)]);
    Pid := fpFork;
    if Pid = 0 then
    begin
      { the child: only async-signal-safe calls until execve }
      fpDup2(InR, 0);
      fpDup2(OutW, 1);
      fpDup2(ErrW, 2);
      for Fd := 3 to 65535 do
        fpClose(Fd);
      fpSignal(SIGPIPE, SignalHandler(SIG_DFL));
      fpSigProcMask(SIG_SETMASK, @Empty, nil);
      fpExecve('/bin/sh', @Argv[0], envp);
      fpExit(127);
    end;
    fpClose(InR);
    fpClose(OutW);
    fpClose(ErrW);
    if Pid < 0 then
    begin
      fpClose(InW);
      fpClose(OutR);
      fpClose(ErrR);
      raise ECase.CreateFmt('cannot spawn server %s: fork: %s', [JsonStr(Cmd), SysErrorMessage(fpgeterrno)]);
    end;
  finally
    SpawnLock.Release;
  end;
  FPid := Pid;
  FStdin := InW;
  FStdout := OutR;
  FErrFd := ErrR;

  Er := TStderrReader.Create(True);
  Er.Fd := ErrR;
  Er.Proc := Self;
  Er.FreeOnTerminate := False;
  FStderrThread := Er;
  Er.Start;

  Rd := TStdoutReader.Create(True);
  Rd.Fd := OutR;
  Rd.Proc := Self;
  Rd.PortEvent := RTLEventCreate;
  Rd.FreeOnTerminate := False;
  FStdoutThread := Rd;
  Rd.Start;

  Deadline := NowUs + 10 * 1000000;
  while not Rd.Ready and (NowUs < Deadline) do
    RTLEventWaitFor(Rd.PortEvent, 100);
  if not Rd.Ready then
    raise ECase.Create('server did not print LISTENING within 10 s');
  ReadBarrier;
  Msg := Rd.PortResult;
  if Msg = '' then
  begin
    Port := Rd.PortValue;
    Exit;
  end;
  SleepMs(100);
  raise ECase.CreateFmt('%s; server stderr:'#10'%s', [Msg, StderrText]);
end;

procedure TServerProc.AppendStderr(const S: RawByteString);
begin
  FStderrLock.Acquire;
  try
    FErrText := FErrText + S;
  finally
    FStderrLock.Release;
  end;
end;

function TServerProc.StderrText: RawByteString;
begin
  FStderrLock.Acquire;
  try
    Result := FErrText;
    UniqueString(Result);
  finally
    FStderrLock.Release;
  end;
end;

procedure TServerProc.SendLine(const Line: RawByteString);
var
  S: RawByteString;
  Done, N: SizeInt;
begin
  if FStdin < 0 then
    raise ECase.Create('server stdin is closed');
  S := Line + #10;
  Done := 0;
  while Done < Length(S) do
  begin
    N := fpWrite(FStdin, S[Done + 1], Length(S) - Done);
    if N < 0 then
    begin
      if fpgeterrno = ESysEINTR then
        Continue;
      raise ECase.CreateFmt('cannot write to server stdin: %s', [SysErrorMessage(fpgeterrno)]);
    end;
    Inc(Done, N);
  end;
end;

function StatusText(St: cint): RawByteString;
begin
  if wifexited(St) then
    Result := Format('exit status: %d', [wexitstatus(St)])
  else if wifsignaled(St) then
    Result := Format('signal: %d', [wtermsig(St)])
  else
    Result := Format('status %d', [St]);
end;

function TServerProc.Exited: RawByteString;
var
  St: cint;
  R: TPid;
begin
  Result := '';
  if FPid <= 0 then
    Exit;
  if not FExited then
  begin
    R := fpWaitPid(FPid, St, WNOHANG);
    if R = FPid then
    begin
      FExited := True;
      FExitStatus := St;
    end;
  end;
  if FExited then
    Result := StatusText(FExitStatus);
end;

procedure TServerProc.Stop;
var
  Deadline: Int64;
  St: cint;
begin
  if FPid <= 0 then
    Exit;
  try
    SendLine('exit');
  except
    on ECase do ;
  end;
  if FStdin >= 0 then
  begin
    fpClose(FStdin);
    FStdin := -1;
  end;
  Deadline := NowUs + 500000;
  while (Exited = '') and (NowUs < Deadline) do
    SleepMs(10);
  if not FExited then
  begin
    fpKill(FPid, SIGKILL);
    if fpWaitPid(FPid, St, 0) = FPid then
    begin
      FExited := True;
      FExitStatus := St;
    end;
  end;
  { stdout ends when the process is gone (it was started with exec), so the
    reader has logged every line once it ends }
  if FStdoutThread <> nil then
  begin
    FStdoutThread.WaitFor;
    RTLEventDestroy(TStdoutReader(FStdoutThread).PortEvent);
    FreeAndNil(FStdoutThread);
  end;
  if FStderrThread <> nil then
  begin
    FStderrThread.WaitFor;
    FreeAndNil(FStderrThread);
  end;
  if FStdout >= 0 then
  begin
    fpClose(FStdout);
    FStdout := -1;
  end;
  if FErrFd >= 0 then
  begin
    fpClose(FErrFd);
    FErrFd := -1;
  end;
end;

destructor TServerProc.Destroy;
begin
  if (FPid > 0) and not FExited then
  begin
    fpKill(FPid, SIGKILL);
  end;
  Stop;
  if FConfigPath <> '' then
    DeleteFile(FConfigPath);
  Events.Free;
  FStderrLock.Free;
  inherited Destroy;
end;

initialization
  SpawnLock := TCriticalSection.Create;
finalization
  SpawnLock.Free;
end.
