{ crun.proxy - the in-process HTTP/1 proxy of the via_proxy cases, the
  equivalent of hyper's tests/support naive_proxy (h1 branch), which the
  ported "via proxy" tests ran through:
  - it serves the accepted connections one at a time, each until the client
    closes it, one request after another;
  - it rewrites the request target to http://127.0.0.1:<server port><path>
    (the path only, the query dropped) and sends the request upstream on a
    new connection, as HTTP/1.1, with the client's fields (names in
    lowercase) and body (Content-Length or chunked, as received);
  - it reads the whole response, removes the Connection field, adds a Date
    field when the response has none (as hyper's server does), and sends it
    back with the body's length in Content-Length (no body for HEAD, 1xx,
    204 and 304).

  It is the runner's own code, independent of the server under test.

  Test tooling only. }
unit crun.proxy;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, BaseUnix, Sockets, crun.bytes, crun.conn;

type
  TProxy = class(TThread)
  private
    FListen: cint;
    FServerPort: Word;
  protected
    procedure Execute; override;
  public
    Port: Word;
    { raises ECase }
    constructor Start(ServerPort: Word);
    destructor Destroy; override;
  end;

implementation

uses
  Linux;

const
  POLLIN_ = 1;

type
  { a blocking socket with a byte buffer }
  TSock = record
    Fd: cint;
    Buf: RawByteString;
    Eof: Boolean;
  end;

function SockFill(var S: TSock): Boolean;
var
  Tmp: array[0..65535] of Byte;
  N: SizeInt;
  Old: SizeInt;
begin
  Result := False;
  if S.Eof then
    Exit;
  repeat
    N := fpRecv(S.Fd, @Tmp[0], SizeOf(Tmp), 0);
  until (N >= 0) or (fpgeterrno <> ESysEINTR);
  if N <= 0 then
  begin
    S.Eof := True;
    Exit;
  end;
  Old := Length(S.Buf);
  SetLength(S.Buf, Old + N);
  Move(Tmp[0], S.Buf[Old + 1], N);
  Result := True;
end;

{ a line up to CRLF (without it); False at EOF before one }
function SockLine(var S: TSock; out Line: RawByteString): Boolean;
var
  P: SizeInt;
begin
  while True do
  begin
    P := FindBytes(S.Buf, #13#10);
    if P >= 0 then
    begin
      Line := Copy(S.Buf, 1, P);
      Delete(S.Buf, 1, P + 2);
      Exit(True);
    end;
    if not SockFill(S) then
      Exit(False);
  end;
end;

function SockBytes(var S: TSock; N: SizeInt; out B: RawByteString): Boolean;
begin
  while Length(S.Buf) < N do
    if not SockFill(S) then
      Exit(False);
  B := Copy(S.Buf, 1, N);
  Delete(S.Buf, 1, N);
  Result := True;
end;

procedure SockSend(Fd: cint; const B: RawByteString);
var
  Done, N: SizeInt;
begin
  Done := 0;
  while Done < Length(B) do
  begin
    N := fpSend(Fd, @B[Done + 1], Length(B) - Done, $4000 { MSG_NOSIGNAL });
    if N < 0 then
    begin
      if fpgeterrno = ESysEINTR then
        Continue;
      raise ECase.CreateFmt('send failed: %s', [SysErrorMessage(fpgeterrno)]);
    end;
    Inc(Done, N);
  end;
end;

type
  THead = record
    Line: RawByteString;
    Names, Values: array of RawByteString;
  end;

{ a head: the first line and the fields up to the empty line }
function ReadHead(var S: TSock; out H: THead): Boolean;
var
  L: RawByteString;
  C: SizeInt;
begin
  H.Names := nil;
  H.Values := nil;
  if not SockLine(S, H.Line) then
    Exit(False);
  while True do
  begin
    if not SockLine(S, L) then
      raise ECase.Create('connection ended inside a head');
    if L = '' then
      Exit(True);
    C := Pos(':', L);
    if C = 0 then
      raise ECase.CreateFmt('malformed field line %s', [Show(L, 200)]);
    SetLength(H.Names, Length(H.Names) + 1);
    SetLength(H.Values, Length(H.Values) + 1);
    H.Names[High(H.Names)] := Copy(L, 1, C - 1);
    H.Values[High(H.Values)] := Trim(Copy(L, C + 1, MaxInt));
  end;
end;

function FieldOf(const H: THead; const Name: RawByteString; out V: RawByteString): Boolean;
var
  K: Integer;
begin
  for K := 0 to High(H.Names) do
    if LowerAscii(H.Names[K]) = Name then
    begin
      V := H.Values[K];
      Exit(True);
    end;
  V := '';
  Result := False;
end;

function IsChunked(const H: THead): Boolean;
var
  K, C: Integer;
  Joined: RawByteString;
begin
  Joined := '';
  for K := 0 to High(H.Names) do
    if LowerAscii(H.Names[K]) = 'transfer-encoding' then
    begin
      if Joined <> '' then
        Joined := Joined + ',';
      Joined := Joined + H.Values[K];
    end;
  if Joined = '' then
    Exit(False);
  C := Length(Joined);
  while (C >= 1) and (Joined[C] <> ',') do
    Dec(C);
  Result := LowerAscii(Trim(Copy(Joined, C + 1, MaxInt))) = 'chunked';
end;

{ the decoded body of a chunked message; the trailer section is dropped }
function ReadChunked(var S: TSock): RawByteString;
var
  L, Data: RawByteString;
  Semi: Integer;
  Size: QWord;
  Code: Integer;
begin
  Result := '';
  while True do
  begin
    if not SockLine(S, L) then
      raise ECase.Create('connection ended inside a chunked body');
    Semi := Pos(';', L);
    if Semi > 0 then
      L := Copy(L, 1, Semi - 1);
    Val('$' + Trim(L), Size, Code);
    if (Code <> 0) or (Trim(L) = '') then
      raise ECase.CreateFmt('invalid chunk size line %s', [Show(L, 200)]);
    if Size = 0 then
    begin
      repeat
        if not SockLine(S, L) then
          raise ECase.Create('connection ended inside a trailer section');
      until L = '';
      Exit;
    end;
    if not SockBytes(S, Size + 2, Data) then
      raise ECase.Create('connection ended inside a chunk');
    Result := Result + Copy(Data, 1, Size);
  end;
end;

{ the body by Content-Length, chunked, or (Close) until EOF }
function ReadBody(var S: TSock; const H: THead; Close: Boolean): RawByteString;
var
  V: RawByteString;
  N: Int64;
begin
  if IsChunked(H) then
    Exit(ReadChunked(S));
  if FieldOf(H, 'content-length', V) then
  begin
    N := StrToInt64Def(V, -1);
    if N < 0 then
      raise ECase.CreateFmt('invalid content-length %s', [Show(V, 50)]);
    if not SockBytes(S, N, Result) then
      raise ECase.Create('connection ended inside a body');
    Exit;
  end;
  Result := '';
  if Close then
  begin
    while SockFill(S) do ;
    Result := S.Buf;
    S.Buf := '';
  end;
end;

{ the path of a request target, without the query: "/" for none }
function TargetPath(const T: RawByteString): RawByteString;
var
  P, Q: SizeInt;
begin
  Result := T;
  P := Pos('://', Result);
  if P > 0 then
  begin
    Result := Copy(Result, P + 3, MaxInt);
    Q := Pos('/', Result);
    if Q = 0 then
      Result := ''
    else
      Result := Copy(Result, Q, MaxInt);
  end;
  Q := Pos('?', Result);
  if Q > 0 then
    Result := Copy(Result, 1, Q - 1);
  Q := Pos('#', Result);
  if Q > 0 then
    Result := Copy(Result, 1, Q - 1);
  if Result = '' then
    Result := '/';
end;

{ the current time as an IMF-fixdate }
function HttpDate: RawByteString;
const
  Days: array[1..7] of string = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  Months: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep',
    'Oct', 'Nov', 'Dec');
var
  T: TDateTime;
  Y, Mo, D, H, Mi, S, Ms: Word;
begin
  T := UnixToDateTime(fpTime);   { UTC }
  DecodeDate(T, Y, Mo, D);
  DecodeTime(T, H, Mi, S, Ms);
  Result := Format('%s, %.2d %s %.4d %.2d:%.2d:%.2d GMT', [Days[DayOfWeek(T)], D, Months[Mo], Y, H, Mi, S]);
end;

function ConnectTo(Port: Word): cint;
var
  A: TInetSockAddr;
begin
  Result := NewTcpSocket;
  if Result < 0 then
    raise ECase.Create('socket failed');
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  A.sin_addr.s_addr := htonl($7F000001);
  if fpConnect(Result, @A, SizeOf(A)) <> 0 then
  begin
    fpClose(Result);
    raise ECase.CreateFmt('connect to the server failed: %s', [SysErrorMessage(fpgeterrno)]);
  end;
end;

{ one request from Client, forwarded; False when the client closed }
function ProxyOne(var Client: TSock; ServerPort: Word): Boolean;
var
  Req, Resp: THead;
  Sp1, Sp2, K: SizeInt;
  Method, Target, Body, Out_, RBody, Code: RawByteString;
  Up: TSock;
  Chunked, NoBody: Boolean;
  Status: Integer;
begin
  if not ReadHead(Client, Req) then
    Exit(False);
  Result := True;
  Sp1 := Pos(' ', Req.Line);
  Sp2 := Pos(' ', Copy(Req.Line, Sp1 + 1, MaxInt));
  if (Sp1 = 0) or (Sp2 = 0) then
    raise ECase.CreateFmt('malformed request line %s', [Show(Req.Line, 200)]);
  Method := Copy(Req.Line, 1, Sp1 - 1);
  Target := Copy(Req.Line, Sp1 + 1, Sp2 - 1);
  Chunked := IsChunked(Req);
  Body := ReadBody(Client, Req, False);

  Out_ := Method + ' http://127.0.0.1:' + IntToStr(ServerPort) + TargetPath(Target) + ' HTTP/1.1'#13#10;
  for K := 0 to High(Req.Names) do
    Out_ := Out_ + LowerAscii(Req.Names[K]) + ': ' + Req.Values[K] + #13#10;
  Out_ := Out_ + #13#10;
  if Chunked then
  begin
    if Body <> '' then
      Out_ := Out_ + LowerCase(IntToHex(Length(Body), 1)) + #13#10 + Body + #13#10;
    Out_ := Out_ + '0'#13#10#13#10;
  end
  else
    Out_ := Out_ + Body;

  Up.Fd := ConnectTo(ServerPort);
  Up.Buf := '';
  Up.Eof := False;
  try
    SockSend(Up.Fd, Out_);
    { skip interim (1xx) responses other than 101 }
    repeat
      if not ReadHead(Up, Resp) then
        raise ECase.Create('the server closed the connection without a response');
      Code := Copy(Resp.Line, 10, 3);
      Status := StrToIntDef(Code, 0);
    until (Status < 100) or (Status >= 200) or (Status = 101);
    NoBody := (UpperCase(Method) = 'HEAD') or (Status < 200) or (Status = 204) or (Status = 304);
    if NoBody then
      RBody := ''
    else
      RBody := ReadBody(Up, Resp, True);
  finally
    fpClose(Up.Fd);
  end;

  Out_ := 'HTTP/1.1 ' + Copy(Resp.Line, 10, MaxInt) + #13#10;
  for K := 0 to High(Resp.Names) do
    if not InList(LowerAscii(Resp.Names[K]), ['connection', 'content-length', 'transfer-encoding']) then
      Out_ := Out_ + LowerAscii(Resp.Names[K]) + ': ' + Resp.Values[K] + #13#10;
  if not FieldOf(Resp, 'date', Code) then
    Out_ := Out_ + 'date: ' + HttpDate + #13#10;
  if not NoBody then
    Out_ := Out_ + 'content-length: ' + IntToStr(Length(RBody)) + #13#10;
  Out_ := Out_ + #13#10 + RBody;
  SockSend(Client.Fd, Out_);
end;

{ ---- TProxy ---- }

constructor TProxy.Start(ServerPort: Word);
var
  A: TInetSockAddr;
  L: TSockLen;
begin
  FServerPort := ServerPort;
  FListen := NewTcpSocket;
  if FListen < 0 then
    raise ECase.Create('proxy bind failed: socket');
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_port := 0;
  A.sin_addr.s_addr := htonl($7F000001);
  if (fpBind(FListen, @A, SizeOf(A)) <> 0) or (fpListen(FListen, 16) <> 0) then
  begin
    fpClose(FListen);
    raise ECase.CreateFmt('proxy bind failed: %s', [SysErrorMessage(fpgeterrno)]);
  end;
  L := SizeOf(A);
  fpGetSockName(FListen, @A, @L);
  Port := ntohs(A.sin_port);
  inherited Create(False);
end;

procedure TProxy.Execute;
var
  Pfd: array[0..0] of TPollFd;
  Fd: cint;
  Client: TSock;
begin
  while not Terminated do
  begin
    Pfd[0].fd := FListen;
    Pfd[0].events := POLLIN_;
    Pfd[0].revents := 0;
    if fpPoll(@Pfd[0], 1, 50) <= 0 then
      Continue;
    Fd := fpAccept(FListen, nil, nil);
    if Fd < 0 then
    begin
      WriteLn(StdErr, 'runner proxy: accept error: ', SysErrorMessage(fpgeterrno));
      Continue;
    end;
    { the child processes close every descriptor above 2, so the missing
      FD_CLOEXEC on the accepted socket does not leak it }
    Client.Fd := Fd;
    Client.Buf := '';
    Client.Eof := False;
    try
      while not Terminated and ProxyOne(Client, FServerPort) do ;
    except
      on E: Exception do
        WriteLn(StdErr, 'runner proxy: ', E.Message);
    end;
    fpClose(Fd);
  end;
end;

destructor TProxy.Destroy;
begin
  Terminate;
  WaitFor;
  fpClose(FListen);
  inherited Destroy;
end;

end.
