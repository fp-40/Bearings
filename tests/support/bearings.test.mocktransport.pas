{ bearings.test.mocktransport - a port of tokio_test::io::Builder (tokio-test
  0.4, src/io.rs) as a TTransport (design m3-transport.md 7.1). Step S3.

  The script is one ordered list of actions, as in tokio_test:
  - Read(bytes): reads take bytes from it (at most the caller's length per
    call; the rest stays for the next read), the action ends when empty.
  - ReadPending / ReadEof / ReadError(e): the next read returns -EAGAIN /
    0 / -e (one read each).
  - Write(bytes): written bytes must equal these bytes. A write call takes
    bytes from consecutive Write actions (Read actions in between are
    skipped, as tokio_test does), up to a WritePending, WriteError or
    WriteLimit action. A mismatch raises EMockTransport.
  - WritePending / WriteError(e): the next write returns -EAGAIN / -e.
  - WriteLimit(n): the next write call accepts at most n bytes (it still
    matches them against the Write actions).
  As in tokio_test: a read whose next action is a write-side action
  returns -EAGAIN; a read with no action left is EOF (0); a write with no
  action left raises EMockTransport ("unexpected write"); a write that
  matched nothing while actions remain returns -EAGAIN.

  Like Rust's default poll_write_vectored, a non-vectored mock's WriteV
  writes only the first non-empty slice (TTransport.WriteV). A vectored
  mock (Vectored(True)) treats a writev as one write of the concatenated
  slices.

  Counters for assertions: ReadCalls, ReadLens, WriteCalls (Write and WriteV calls,
  including Pending/error ones), WriteLog (the bytes accepted by each
  successful write call, in order), IovCounts (the slice count of every WriteV
  call of a vectored mock), ShutdownCalls, Closed. }
unit bearings.test.mocktransport;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ctypes, bearings.rt.net, bearings.http1.encode;

type
  EMockTransport = class(Exception);

  TMockActionKind = (makRead, makReadPending, makReadEof, makReadError,
    makWrite, makWriteLimit, makWritePending, makWriteError);

  TMockAction = record
    Kind: TMockActionKind;
    Data: RawByteString;           { makRead / makWrite: the bytes still to read / expect }
    Errno: cint;
    Limit: SizeInt;
  end;

  TMockTransport = class(TTransport)
  private
    FActions: array of TMockAction;
    FHead: Integer;                { first unconsumed action }
    FVectored: Boolean;
    procedure AddAction(Kind: TMockActionKind; const Data: RawByteString; Errno: cint; Limit: SizeInt);
    function WriteBytes(Src: PByte; Len: SizeInt): SizeInt;
    function Describe(I: Integer): string;
  public
    ReadCalls: Integer;
    ReadLens: array of SizeInt;    { the Len of every Read call (the spare capacity hyper reads into) }
    WriteCalls: Integer;
    ShutdownCalls: Integer;
    ShutdownResult: SizeInt;       { what ShutdownWrite returns; default 0 }
    Closed: Boolean;
    WriteLog: TStringList;         { one line per successful write call: its bytes }
    IovCounts: array of Integer;   { vectored mock: the slice count of every WriteV call }
    constructor Create;
    destructor Destroy; override;
    function Read(const Data: RawByteString): TMockTransport; overload;   { next read returns these bytes }
    function ReadPending: TMockTransport;                       { next read returns -EAGAIN }
    function ReadEof: TMockTransport;
    function ReadError(Errno: cint): TMockTransport;
    function Write(const Data: RawByteString): TMockTransport; overload;  { next write must match exactly }
    function WriteLimit(N: SizeInt): TMockTransport;            { next write accepts at most N bytes }
    function WritePending: TMockTransport;
    function WriteError(Errno: cint): TMockTransport;
    function Vectored(Enabled: Boolean): TMockTransport;        { IsWriteVectored; default False }
    procedure AssertDone;                                       { every scripted action consumed }
    function Remaining: Integer;                                { actions not consumed yet }
    { all accepted bytes, concatenated }
    function Written: RawByteString;
    { TTransport }
    function Read(Buf: PByte; Len: SizeInt): SizeInt; override; overload;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; override; overload;
    function WriteV(Iov: PIoSlice; Count: Integer): SizeInt; override;
    function IsWriteVectored: Boolean; override;
    function ShutdownWrite: SizeInt; override;
    procedure Close; override;
  end;

implementation

const
  EAGAIN_ = 11;
  EPIPE_ = 32;

function Printable(const S: RawByteString): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if (S[I] >= ' ') and (S[I] < #127) and (S[I] <> '\') then
      Result := Result + S[I]
    else if S[I] = #13 then
      Result := Result + '\r'
    else if S[I] = #10 then
      Result := Result + '\n'
    else
      Result := Result + '\x' + IntToHex(Ord(S[I]), 2);
end;

constructor TMockTransport.Create;
begin
  inherited Create;
  WriteLog := TStringList.Create;
end;

destructor TMockTransport.Destroy;
begin
  WriteLog.Free;
  inherited Destroy;
end;

procedure TMockTransport.AddAction(Kind: TMockActionKind; const Data: RawByteString; Errno: cint;
  Limit: SizeInt);
var
  N: Integer;
begin
  N := Length(FActions);
  SetLength(FActions, N + 1);
  FActions[N].Kind := Kind;
  FActions[N].Data := Data;
  FActions[N].Errno := Errno;
  FActions[N].Limit := Limit;
end;

function TMockTransport.Describe(I: Integer): string;
begin
  WriteStr(Result, FActions[I].Kind);
  if FActions[I].Kind in [makRead, makWrite] then
    Result := Result + '("' + Printable(FActions[I].Data) + '")';
end;

function TMockTransport.Read(const Data: RawByteString): TMockTransport;
begin
  if Data <> '' then   { tokio_test ignores empty reads }
    AddAction(makRead, Data, 0, 0);
  Result := Self;
end;

function TMockTransport.ReadPending: TMockTransport;
begin
  AddAction(makReadPending, '', 0, 0);
  Result := Self;
end;

function TMockTransport.ReadEof: TMockTransport;
begin
  AddAction(makReadEof, '', 0, 0);
  Result := Self;
end;

function TMockTransport.ReadError(Errno: cint): TMockTransport;
begin
  AddAction(makReadError, '', Errno, 0);
  Result := Self;
end;

function TMockTransport.Write(const Data: RawByteString): TMockTransport;
begin
  if Data <> '' then   { tokio_test ignores empty writes }
    AddAction(makWrite, Data, 0, 0);
  Result := Self;
end;

function TMockTransport.WriteLimit(N: SizeInt): TMockTransport;
begin
  AddAction(makWriteLimit, '', 0, N);
  Result := Self;
end;

function TMockTransport.WritePending: TMockTransport;
begin
  AddAction(makWritePending, '', 0, 0);
  Result := Self;
end;

function TMockTransport.WriteError(Errno: cint): TMockTransport;
begin
  AddAction(makWriteError, '', Errno, 0);
  Result := Self;
end;

function TMockTransport.Vectored(Enabled: Boolean): TMockTransport;
begin
  FVectored := Enabled;
  Result := Self;
end;

function TMockTransport.Remaining: Integer;
begin
  Result := Length(FActions) - FHead;
end;

procedure TMockTransport.AssertDone;
var
  I: Integer;
  S: string;
begin
  if FHead < Length(FActions) then
  begin
    S := '';
    for I := FHead to High(FActions) do
      S := S + ' ' + Describe(I);
    raise EMockTransport.Create('mock: actions not consumed:' + S);
  end;
end;

function TMockTransport.Written: RawByteString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to WriteLog.Count - 1 do
    Result := Result + WriteLog[I];
end;

function TMockTransport.Read(Buf: PByte; Len: SizeInt): SizeInt;
var
  A: ^TMockAction;
  N: SizeInt;
begin
  Inc(ReadCalls);
  SetLength(ReadLens, Length(ReadLens) + 1);
  ReadLens[High(ReadLens)] := Len;
  if FHead >= Length(FActions) then
    Exit(0);                                  { no action: EOF }
  A := @FActions[FHead];
  case A^.Kind of
    makRead:
      begin
        N := Length(A^.Data);
        if N > Len then
          N := Len;
        if N > 0 then
          Move(A^.Data[1], Buf^, N);
        Delete(A^.Data, 1, N);
        if A^.Data = '' then
          Inc(FHead);
        Result := N;
      end;
    makReadPending:
      begin
        Inc(FHead);
        Result := -EAGAIN_;
      end;
    makReadEof:
      begin
        Inc(FHead);
        Result := 0;
      end;
    makReadError:
      begin
        Inc(FHead);
        Result := -A^.Errno;
      end;
  else
    Result := -EAGAIN_;                       { waiting for a write }
  end;
end;

function TMockTransport.WriteBytes(Src: PByte; Len: SizeInt): SizeInt;
var
  I, N: SizeInt;
  A: ^TMockAction;
  Got: RawByteString;
begin
  Inc(WriteCalls);
  if FHead >= Length(FActions) then
  begin
    SetString(Got, PAnsiChar(Src), Len);
    raise EMockTransport.Create('mock: unexpected write "' + Printable(Got) + '"');
  end;
  A := @FActions[FHead];
  case A^.Kind of
    makWritePending:
      begin
        Inc(FHead);
        Exit(-EAGAIN_);
      end;
    makWriteError:
      begin
        Inc(FHead);
        Exit(-A^.Errno);
      end;
    makWriteLimit:
      begin
        if Len > A^.Limit then
          Len := A^.Limit;
        Inc(FHead);
      end;
  end;
  Result := 0;
  I := FHead;
  while (Len > 0) and (I < Length(FActions)) do
  begin
    A := @FActions[I];
    case A^.Kind of
      makWrite:
        begin
          N := Length(A^.Data);
          if N > Len then
            N := Len;
          if CompareByte(A^.Data[1], Src^, N) <> 0 then
          begin
            SetString(Got, PAnsiChar(Src), N);
            raise EMockTransport.Create('mock: write mismatch: got "' + Printable(Got) +
              '", expected "' + Printable(Copy(A^.Data, 1, N)) + '"');
          end;
          Delete(A^.Data, 1, N);
          Inc(Src, N);
          Dec(Len, N);
          Inc(Result, N);
        end;
      makWritePending, makWriteError, makWriteLimit:
        Break;
    end;
    Inc(I);
  end;
  { drop the Write actions that are done; Read actions stay in place }
  I := FHead;
  while I < Length(FActions) do
  begin
    if (FActions[I].Kind = makWrite) and (FActions[I].Data = '') then
    begin
      Delete(FActions, I, 1);
      Continue;
    end;
    if FActions[I].Kind in [makWritePending, makWriteError, makWriteLimit] then
      Break;
    Inc(I);
  end;
  if Result = 0 then
  begin
    if Len = 0 then
      Exit(0);                                { a write of nothing }
    if FHead < Length(FActions) then
      Exit(-EAGAIN_);                          { tokio_test: Ok(0) with actions left is Pending }
    raise EMockTransport.Create('mock: unexpected write (no Write action)');
  end;
end;

function TMockTransport.Write(Buf: PByte; Len: SizeInt): SizeInt;
var
  S: RawByteString;
begin
  Result := WriteBytes(Buf, Len);
  if Result > 0 then
  begin
    SetString(S, PAnsiChar(Buf), Result);
    WriteLog.Add(S);
  end;
end;

function TMockTransport.WriteV(Iov: PIoSlice; Count: Integer): SizeInt;
var
  All: RawByteString;
  I: Integer;
  P: SizeInt;
begin
  if not FVectored then
    Exit(inherited WriteV(Iov, Count));
  SetLength(IovCounts, Length(IovCounts) + 1);
  IovCounts[High(IovCounts)] := Count;
  P := 0;
  for I := 0 to Count - 1 do
    Inc(P, SizeInt(Iov[I].Len));
  SetLength(All, P);
  P := 0;
  for I := 0 to Count - 1 do
    if Iov[I].Len > 0 then
    begin
      Move(Iov[I].Base^, All[P + 1], Iov[I].Len);
      Inc(P, SizeInt(Iov[I].Len));
    end;
  if P = 0 then
    Result := WriteBytes(nil, 0)
  else
    Result := WriteBytes(@All[1], P);
  if Result > 0 then
    WriteLog.Add(Copy(All, 1, Result));
end;

function TMockTransport.IsWriteVectored: Boolean;
begin
  Result := FVectored;
end;

function TMockTransport.ShutdownWrite: SizeInt;
begin
  Inc(ShutdownCalls);
  Result := ShutdownResult;
end;

procedure TMockTransport.Close;
begin
  Closed := True;
end;

end.
