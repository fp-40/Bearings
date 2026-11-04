{ crun.conn - a client connection of the conformance runner: a blocking
  TCP socket with a timeout per read and per write, the bytes received but
  not yet used by a step, and the end state, which stays once reached (EOF:
  the peer sent FIN; reset: ECONNRESET or ECONNABORTED).

  Sockets are created with SOCK_CLOEXEC; server processes are started with
  every descriptor above 2 closed anyway (crun.server).

  Also: the monotonic clock used for every time in the runner.

  Test tooling only. }
unit crun.conn;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, BaseUnix, Unix, Sockets, crun.bytes;

const
  DEFAULT_TIMEOUT_MS = 1000;

type
  TEnd = (endOpen, endEof, endReset);
  TReadOutcome = (roData, roEof, roReset, roTimeout);

  TConn = class
  private
    FFd: cint;
  public
    Buf: RawByteString;              { received, not yet used by a step }
    End_: TEnd;
    ConnectedAt: Int64;              { NowUs }
    { connects to 127.0.0.1:Port; raises ECase }
    constructor Connect(Port: Word; NoDelay: Boolean);
    destructor Destroy; override;
    procedure WriteAll(const Data: RawByteString; TimeoutMs: Int64);
    procedure ShutdownWrite;
    procedure Close;
    function IsClosedLocally: Boolean;
    { one recv into Buf, waiting at most TimeoutMs }
    function ReadSome(TimeoutMs: Int64): TReadOutcome;
    { up to Max bytes from the front of Buf }
    function Take(Max: SizeInt): RawByteString;
  end;

function EndName(E: TEnd): RawByteString;
{ microseconds of CLOCK_MONOTONIC }
function NowUs: Int64;
procedure SleepMs(Ms: Int64);
{ a socket with SOCK_CLOEXEC; -1 on failure }
function NewTcpSocket: cint;

implementation

uses
  Linux;

const
  SOCK_CLOEXEC_FLAG = $80000;        { SOCK_CLOEXEC = O_CLOEXEC on Linux }
  IPPROTO_TCP_ = 6;
  TCP_NODELAY_ = 1;
  MSG_NOSIGNAL_ = $4000;

function EndName(E: TEnd): RawByteString;
begin
  case E of
    endOpen: Result := 'open';
    endEof: Result := 'eof';
    endReset: Result := 'reset';
  end;
end;

function NowUs: Int64;
var
  Ts: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @Ts);
  Result := Int64(Ts.tv_sec) * 1000000 + Ts.tv_nsec div 1000;
end;

procedure SleepMs(Ms: Int64);
var
  Req, Rem: TTimeSpec;
begin
  if Ms <= 0 then
    Exit;
  Req.tv_sec := Ms div 1000;
  Req.tv_nsec := (Ms mod 1000) * 1000000;
  while fpNanoSleep(@Req, @Rem) <> 0 do
  begin
    if fpgeterrno <> ESysEINTR then
      Break;
    Req := Rem;
  end;
end;

function NewTcpSocket: cint;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM or SOCK_CLOEXEC_FLAG, 0);
end;

procedure SetTimeout(Fd: cint; Opt: cint; Ms: Int64);
var
  Tv: TTimeVal;
begin
  if Ms < 1 then
    Ms := 1;
  Tv.tv_sec := Ms div 1000;
  Tv.tv_usec := (Ms mod 1000) * 1000;
  fpSetSockOpt(Fd, SOL_SOCKET, Opt, @Tv, SizeOf(Tv));
end;

constructor TConn.Connect(Port: Word; NoDelay: Boolean);
var
  A: TInetSockAddr;
  One: cint;
  E: cint;
begin
  inherited Create;
  End_ := endOpen;
  Buf := '';
  FFd := NewTcpSocket;
  if FFd < 0 then
    raise ECase.CreateFmt('connect to 127.0.0.1:%d failed: socket: errno %d', [Port, fpgeterrno]);
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  A.sin_addr.s_addr := htonl($7F000001);
  { to 127.0.0.1 a connect completes or fails at once; SO_SNDTIMEO bounds it }
  SetTimeout(FFd, SO_SNDTIMEO, 5000);
  if fpConnect(FFd, @A, SizeOf(A)) <> 0 then
  begin
    E := fpgeterrno;
    fpClose(FFd);
    FFd := -1;
    raise ECase.CreateFmt('connect to 127.0.0.1:%d failed: %s', [Port, SysErrorMessage(E)]);
  end;
  ConnectedAt := NowUs;
  One := Ord(NoDelay);
  if fpSetSockOpt(FFd, IPPROTO_TCP_, TCP_NODELAY_, @One, SizeOf(One)) <> 0 then
    raise ECase.CreateFmt('set_nodelay: %s', [SysErrorMessage(fpgeterrno)]);
end;

destructor TConn.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure NeedOpen(Fd: cint);
begin
  if Fd < 0 then
    raise ECase.Create('connection was closed by a previous close step');
end;

procedure TConn.WriteAll(const Data: RawByteString; TimeoutMs: Int64);
var
  Done, N: SizeInt;
  E: cint;
begin
  NeedOpen(FFd);
  SetTimeout(FFd, SO_SNDTIMEO, TimeoutMs);
  Done := 0;
  while Done < Length(Data) do
  begin
    N := fpSend(FFd, @Data[Done + 1], Length(Data) - Done, MSG_NOSIGNAL_);
    if N < 0 then
    begin
      E := fpgeterrno;
      if E = ESysEINTR then
        Continue;
      raise ECase.CreateFmt('write failed: %s (errno %d)', [SysErrorMessage(E), E]);
    end;
    Inc(Done, N);
  end;
end;

procedure TConn.ShutdownWrite;
begin
  NeedOpen(FFd);
  if fpShutdown(FFd, SHUT_WR) <> 0 then
    raise ECase.CreateFmt('shutdown(Write) failed: %s', [SysErrorMessage(fpgeterrno)]);
end;

procedure TConn.Close;
begin
  if FFd >= 0 then
  begin
    fpClose(FFd);
    FFd := -1;
  end;
end;

function TConn.IsClosedLocally: Boolean;
begin
  Result := FFd < 0;
end;

function TConn.ReadSome(TimeoutMs: Int64): TReadOutcome;
var
  Tmp: array[0..65535] of Byte;
  N: SizeInt;
  E: cint;
  Old: SizeInt;
begin
  case End_ of
    endEof: Exit(roEof);
    endReset: Exit(roReset);
  end;
  NeedOpen(FFd);
  SetTimeout(FFd, SO_RCVTIMEO, TimeoutMs);
  while True do
  begin
    N := fpRecv(FFd, @Tmp[0], SizeOf(Tmp), 0);
    if N = 0 then
    begin
      End_ := endEof;
      Exit(roEof);
    end;
    if N > 0 then
    begin
      Old := Length(Buf);
      SetLength(Buf, Old + N);
      Move(Tmp[0], Buf[Old + 1], N);
      Exit(roData);
    end;
    E := fpgeterrno;
    if (E = ESysEAGAIN) or (E = ESysEWOULDBLOCK) or (E = ESysETIMEDOUT) then
      Exit(roTimeout);
    if E = ESysEINTR then
      Continue;
    if (E = ESysECONNRESET) or (E = ESysECONNABORTED) then
    begin
      End_ := endReset;
      Exit(roReset);
    end;
    raise ECase.CreateFmt('read failed: %s (errno %d)', [SysErrorMessage(E), E]);
  end;
end;

function TConn.Take(Max: SizeInt): RawByteString;
var
  N: SizeInt;
begin
  N := Length(Buf);
  if Max < N then
    N := Max;
  Result := Copy(Buf, 1, N);
  Delete(Buf, 1, N);
end;

end.
