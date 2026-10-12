{ bearings.test.scriptio - a scripted, recording TTransport for dispatcher-level
  tests (design m3-transport.md 7.3). Step S5.

  Unlike bearings.test.mocktransport (a port of tokio_test::io, which asserts the
  exact bytes of every write), this transport records what is written and
  scripts only the transport's answers:

  Reads (one queue): Data(bytes) - reads take bytes from it, at most the
  caller's length per call (the rest stays for the next read); Pending -
  the next read returns -EAGAIN once and the transport is "read blocked"
  (Wakeable); Eof - every read from then on returns 0; Error(errno) - the
  next read returns -errno. With the queue empty a read returns -EAGAIN and
  nothing will wake the reader (an idle client).

  Writes (one queue): Limit(n) - the next write call accepts at most n bytes;
  Pending - the next write returns -EAGAIN once (write blocked, Wakeable);
  Error(errno) - the next write returns -errno. With the queue empty a write
  accepts every byte, or (BlockWritesWhenDone) returns -EAGAIN without
  becoming Wakeable. Optional WriteCap: every write accepts at most this
  many bytes (0 = no cap).

  Vectored(True): IsWriteVectored, and WriteV is one write of the
  concatenated slices (a writev). Otherwise WriteV writes the first
  non-empty slice only (Rust's default poll_write_vectored).

  Every call that moves bytes or changes state appends one line to Log
  (when assigned): "read <cap> -> <n>|pending|eof|error <e>",
  "write <n> <escaped bytes>", "writev <slices> <n> <escaped bytes>",
  "write pending", "write error <e>", "shutdown", "close". Written collects
  every accepted byte. WritesWhileBlocked counts the write calls made while
  WriteBlocked was set (no readiness edge delivered since the Pending): the
  hot-polling check of unbuffered_stream.rs. }
unit bearings.test.scriptio;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ctypes, bearings.rt.sys, bearings.rt.net, bearings.http1.encode;

type
  TScriptReadKind = (srData, srPending, srEof, srError);
  TScriptWriteKind = (swLimit, swPending, swError);

  TScriptRead = record
    Kind: TScriptReadKind;
    Data: RawByteString;
    Errno: cint;
  end;

  TScriptWrite = record
    Kind: TScriptWriteKind;
    Limit: SizeInt;
    Errno: cint;
  end;

  TScriptIo = class(TTransport)
  private
    FReads: array of TScriptRead;
    FReadHead: Integer;
    FWrites: array of TScriptWrite;
    FWriteHead: Integer;
    FVectored: Boolean;
    FEof: Boolean;
    FBlockedRun: Integer;
    procedure Emit(const S: string);
    function Accept(Src: PByte; Len: SizeInt; const Prefix: string): SizeInt;
  public
    Log: TStrings;                   { not owned; nil = no log }
    Written: RawByteString;
    WriteCap: SizeInt;
    ReadCalls, WriteCalls, ShutdownCalls: Integer;
    ReadBlocked, WriteBlocked: Boolean;
    { write calls made while WriteBlocked was still set, i.e. before the
      driver delivered the write readiness edge (ClearBlocked): a real
      socket returns EAGAIN without progress there, so a dispatcher that
      retries without waiting is hot polling (hyper unbuffered_stream.rs) }
    WritesWhileBlocked: Integer;
    { the longest run of such calls between two readiness edges }
    MaxBlockedRun: Integer;
    { True: a write while WriteBlocked returns -EAGAIN without consuming the
      script (logged "write blocked"), as a socket without write readiness
      or hyper's UnbufferedStream sleep; False (default): it takes
      the next write action like the Rust mock IO }
    StrictWriteBlock: Boolean;
    Closed: Boolean;
    { when the write script is used up: every write returns Pending and
      nothing wakes the writer (a peer that stopped reading) }
    BlockWritesWhenDone: Boolean;
    function AddRead(const Data: RawByteString): TScriptIo;
    function AddReadPending: TScriptIo;
    function AddReadEof: TScriptIo;
    function AddReadError(Errno: cint): TScriptIo;
    function AddWriteLimit(N: SizeInt): TScriptIo;
    function AddWritePending: TScriptIo;
    function AddWriteError(Errno: cint): TScriptIo;
    function Vectored(Enabled: Boolean): TScriptIo;
    function ReadsLeft: Integer;
    { a blocked read with more script, or a blocked write: delivering the
      readiness edge makes progress possible }
    function Wakeable: Boolean;
    procedure ClearBlocked;
    { TTransport }
    function Read(Buf: PByte; Len: SizeInt): SizeInt; override;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; override;
    function WriteV(Iov: PIoSlice; Count: Integer): SizeInt; override;
    function IsWriteVectored: Boolean; override;
    function ShutdownWrite: SizeInt; override;
    procedure Close; override;
  end;

{ C-like escaping used in transcripts: printable ASCII as is, \r \n \t \\ \"
  and \xHH otherwise. }
function EscapeBytes(P: PByte; Len: SizeInt): string;
function EscapeStr(const S: RawByteString): string;

implementation

function EscapeBytes(P: PByte; Len: SizeInt): string;
var
  I: SizeInt;
  C: Byte;
begin
  Result := '';
  for I := 0 to Len - 1 do
  begin
    C := P[I];
    case C of
      13: Result := Result + '\r';
      10: Result := Result + '\n';
      9: Result := Result + '\t';
      92: Result := Result + '\\';
      34: Result := Result + '\"';
      32..33, 35..91, 93..126: Result := Result + Chr(C);
    else
      Result := Result + '\x' + LowerCase(IntToHex(C, 2));
    end;
  end;
end;

function EscapeStr(const S: RawByteString): string;
begin
  Result := EscapeBytes(PByte(Pointer(S)), Length(S));
end;

procedure TScriptIo.Emit(const S: string);
begin
  if Log <> nil then
    Log.Add(S);
end;

function TScriptIo.AddRead(const Data: RawByteString): TScriptIo;
var
  N: Integer;
begin
  N := Length(FReads);
  SetLength(FReads, N + 1);
  FReads[N].Kind := srData;
  FReads[N].Data := Data;
  Result := Self;
end;

function TScriptIo.AddReadPending: TScriptIo;
var
  N: Integer;
begin
  N := Length(FReads);
  SetLength(FReads, N + 1);
  FReads[N].Kind := srPending;
  Result := Self;
end;

function TScriptIo.AddReadEof: TScriptIo;
var
  N: Integer;
begin
  N := Length(FReads);
  SetLength(FReads, N + 1);
  FReads[N].Kind := srEof;
  Result := Self;
end;

function TScriptIo.AddReadError(Errno: cint): TScriptIo;
var
  N: Integer;
begin
  N := Length(FReads);
  SetLength(FReads, N + 1);
  FReads[N].Kind := srError;
  FReads[N].Errno := Errno;
  Result := Self;
end;

function TScriptIo.AddWriteLimit(N: SizeInt): TScriptIo;
var
  I: Integer;
begin
  I := Length(FWrites);
  SetLength(FWrites, I + 1);
  FWrites[I].Kind := swLimit;
  FWrites[I].Limit := N;
  Result := Self;
end;

function TScriptIo.AddWritePending: TScriptIo;
var
  I: Integer;
begin
  I := Length(FWrites);
  SetLength(FWrites, I + 1);
  FWrites[I].Kind := swPending;
  Result := Self;
end;

function TScriptIo.AddWriteError(Errno: cint): TScriptIo;
var
  I: Integer;
begin
  I := Length(FWrites);
  SetLength(FWrites, I + 1);
  FWrites[I].Kind := swError;
  FWrites[I].Errno := Errno;
  Result := Self;
end;

function TScriptIo.Vectored(Enabled: Boolean): TScriptIo;
begin
  FVectored := Enabled;
  Result := Self;
end;

function TScriptIo.ReadsLeft: Integer;
begin
  Result := Length(FReads) - FReadHead;
end;

function TScriptIo.Wakeable: Boolean;
begin
  Result := (ReadBlocked and (ReadsLeft > 0)) or WriteBlocked;
end;

procedure TScriptIo.ClearBlocked;
begin
  ReadBlocked := False;
  WriteBlocked := False;
  FBlockedRun := 0;
end;

function TScriptIo.Read(Buf: PByte; Len: SizeInt): SizeInt;
var
  A: ^TScriptRead;
  N: SizeInt;
begin
  Inc(ReadCalls);
  if FEof then
  begin
    Emit(Format('read %d -> eof', [Len]));
    Exit(0);
  end;
  if FReadHead >= Length(FReads) then
  begin
    Emit(Format('read %d -> pending', [Len]));
    Exit(-ESysEAGAIN);                         { idle client: no wake }
  end;
  A := @FReads[FReadHead];
  case A^.Kind of
    srData:
      begin
        N := Length(A^.Data);
        if N > Len then
          N := Len;
        if N > 0 then
          Move(A^.Data[1], Buf^, N);
        Delete(A^.Data, 1, N);
        if A^.Data = '' then
          Inc(FReadHead);
        Emit(Format('read %d -> %d', [Len, N]));
        Result := N;
      end;
    srPending:
      begin
        Inc(FReadHead);
        ReadBlocked := True;
        Emit(Format('read %d -> pending', [Len]));
        Result := -ESysEAGAIN;
      end;
    srEof:
      begin
        FEof := True;
        Emit(Format('read %d -> eof', [Len]));
        Result := 0;
      end;
  else
    begin
      Inc(FReadHead);
      Emit(Format('read %d -> error %d', [Len, A^.Errno]));
      Result := -A^.Errno;
    end;
  end;
end;

function TScriptIo.Accept(Src: PByte; Len: SizeInt; const Prefix: string): SizeInt;
var
  A: ^TScriptWrite;
  N: SizeInt;
  S: RawByteString;
begin
  Inc(WriteCalls);
  if WriteBlocked then
  begin
    Inc(WritesWhileBlocked);
    Inc(FBlockedRun);
    if FBlockedRun > MaxBlockedRun then
      MaxBlockedRun := FBlockedRun;
    if StrictWriteBlock then
    begin
      Emit('write blocked');
      Exit(-ESysEAGAIN);
    end;
  end;
  N := Len;
  if BlockWritesWhenDone and (FWriteHead >= Length(FWrites)) then
  begin
    Emit('write pending');
    Exit(-ESysEAGAIN);
  end;
  if FWriteHead < Length(FWrites) then
  begin
    A := @FWrites[FWriteHead];
    case A^.Kind of
      swPending:
        begin
          Inc(FWriteHead);
          WriteBlocked := True;
          Emit('write pending');
          Exit(-ESysEAGAIN);
        end;
      swError:
        begin
          Inc(FWriteHead);
          Emit(Format('write error %d', [A^.Errno]));
          Exit(-A^.Errno);
        end;
    else
      begin
        Inc(FWriteHead);
        if A^.Limit < N then
          N := A^.Limit;
      end;
    end;
  end;
  if (WriteCap > 0) and (N > WriteCap) then
    N := WriteCap;
  SetLength(S, N);
  if N > 0 then
    Move(Src^, S[1], N);
  Written := Written + S;
  if Log <> nil then
    Emit(Prefix + IntToStr(N) + ' "' + EscapeStr(S) + '"');
  Result := N;
end;

function TScriptIo.Write(Buf: PByte; Len: SizeInt): SizeInt;
begin
  Result := Accept(Buf, Len, 'write ');
end;

function TScriptIo.WriteV(Iov: PIoSlice; Count: Integer): SizeInt;
var
  All: RawByteString;
  I: Integer;
  Off: SizeInt;
begin
  if not FVectored then
    Exit(inherited WriteV(Iov, Count));
  Off := 0;
  for I := 0 to Count - 1 do
    Inc(Off, SizeInt(Iov[I].Len));
  SetLength(All, Off);
  Off := 0;
  for I := 0 to Count - 1 do
    if Iov[I].Len > 0 then
    begin
      Move(Iov[I].Base^, All[Off + 1], Iov[I].Len);
      Inc(Off, SizeInt(Iov[I].Len));
    end;
  Result := Accept(PByte(Pointer(All)), Length(All), 'writev ' + IntToStr(Count) + ' ');
end;

function TScriptIo.IsWriteVectored: Boolean;
begin
  Result := FVectored;
end;

function TScriptIo.ShutdownWrite: SizeInt;
begin
  Inc(ShutdownCalls);
  Emit('shutdown');
  Result := 0;
end;

procedure TScriptIo.Close;
begin
  if Closed then
    Exit;
  Closed := True;
  Emit('close');
end;

end.
