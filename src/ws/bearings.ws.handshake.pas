{ bearings.ws.handshake - the WebSocket opening handshake on the server
  (RFC 6455 section 4.2).

  A client opens a WebSocket with an ordinary HTTP/1.1 GET request that asks
  to switch the connection to the WebSocket protocol:
    GET /chat HTTP/1.1
    Upgrade: websocket
    Connection: Upgrade
    Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
    Sec-WebSocket-Version: 13
    Sec-WebSocket-Protocol: chat, superchat      (optional)
  The key is 16 random bytes in base64. The server proves that it
  understood the request by answering
    HTTP/1.1 101 Switching Protocols
    Upgrade: websocket
    Connection: Upgrade
    Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
  where the accept value is base64(SHA-1(key + a fixed GUID)). After the
  101 the connection carries WebSocket frames (bearings.ws.frame).

  CheckRequest checks the request: method GET, HTTP/1.1, an upgrade
  request (the exchange has an upgrade slot), "websocket" among the Upgrade
  tokens, "upgrade" among the Connection tokens (both case-insensitive), one
  Sec-WebSocket-Key that is the base64 form of exactly 16 bytes, and
  Sec-WebSocket-Version 13. It also picks the subprotocol: the first token
  of the client's Sec-WebSocket-Protocol fields that is in the
  application's list. No extension is negotiated, so
  Sec-WebSocket-Extensions is ignored.

  On success the application calls Respond101 (or AcceptWebSocket in
  bearings.ws.conn, which also creates the connection object); on failure
  RespondHandshakeError answers 426 Upgrade Required with
  "Sec-WebSocket-Version: 13" when only the version was wrong, and 400 Bad
  Request otherwise.

  SHA-1 comes from Free Pascal's sha1 unit (the hash package). The base64
  encoder and decoder are here: the handshake needs the standard alphabet
  with padding, and the key check must refuse any other character.

  Threading: the exchange calls run on the loop thread, inside the
  application's service call (the upgrade must be registered before the
  answer). }
unit bearings.ws.handshake;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  bearings.http.headers, bearings.http1.role, bearings.http.exchange;

const
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

type
  TWsHandshakeStatus = (whOk, whNotGet, whNotHttp11, whNotUpgrade, whNoUpgradeWebsocket,
    whNoConnectionUpgrade, whBadKey, whBadVersion);

  TWsHandshake = record
    Status: TWsHandshakeStatus;
    Accept: RawByteString;           { the Sec-WebSocket-Accept value (whOk) }
    Protocol: RawByteString;         { the chosen subprotocol; '' none }
    function Ok: Boolean; inline;
    function HttpStatus: Word;       { 101 for whOk, 426 for whBadVersion, else 400 }
    function Text: RawByteString;    { what was wrong, for the error body }
  end;

{ Checks the request of Ex (loop thread). Protocols: the subprotocols the
  application supports. }
function CheckRequest(Ex: TExchange; const Protocols: array of RawByteString): TWsHandshake;
{ The same checks on the parts of a request (for tests and other front ends).
  IsUpgrade: the HTTP layer treats the request as an upgrade request. }
function CheckHandshake(Method: THttpMethod; Version: THttpVersion; IsUpgrade: Boolean;
  Headers: THttpHeaders; const Protocols: array of RawByteString): TWsHandshake;
{ base64(SHA-1(Key + WS_GUID)) }
function AcceptValue(const Key: RawByteString): RawByteString;
{ Registers H with Ex.OnUpgrade and answers 101 with the handshake headers.
  False when the exchange refused the answer (canceled or already answered);
  H then gets UpgradeFailed from the exchange's cancel path, or never was
  registered when R is not Ok (then H.UpgradeFailed is called here). }
function Respond101(Ex: TExchange; const R: TWsHandshake; H: TUpgradeHandler): Boolean;
{ Answers 400, or 426 with Sec-WebSocket-Version: 13. }
function RespondHandshakeError(Ex: TExchange; const R: TWsHandshake): Boolean;

{ Standard base64 with padding. }
function Base64Encode(P: PByte; Len: SizeInt): RawByteString;
{ Strict decoder: the standard alphabet, padding only at the end, length a
  multiple of 4, unused bits zero. False on anything else. }
function Base64Decode(const S: RawByteString; out Bytes: RawByteString): Boolean;

implementation

uses
  sha1, bearings.rt.buf;

const
  B64: array[0..63] of AnsiChar =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function Base64Encode(P: PByte; Len: SizeInt): RawByteString;
var
  I, O: SizeInt;
  V: LongWord;
begin
  SetLength(Result, ((Len + 2) div 3) * 4);
  I := 0;
  O := 1;
  while Len - I >= 3 do
  begin
    V := (LongWord(P[I]) shl 16) or (LongWord(P[I + 1]) shl 8) or P[I + 2];
    Result[O] := B64[V shr 18];
    Result[O + 1] := B64[(V shr 12) and 63];
    Result[O + 2] := B64[(V shr 6) and 63];
    Result[O + 3] := B64[V and 63];
    Inc(I, 3);
    Inc(O, 4);
  end;
  case Len - I of
    1:
      begin
        V := LongWord(P[I]) shl 16;
        Result[O] := B64[V shr 18];
        Result[O + 1] := B64[(V shr 12) and 63];
        Result[O + 2] := '=';
        Result[O + 3] := '=';
      end;
    2:
      begin
        V := (LongWord(P[I]) shl 16) or (LongWord(P[I + 1]) shl 8);
        Result[O] := B64[V shr 18];
        Result[O + 1] := B64[(V shr 12) and 63];
        Result[O + 2] := B64[(V shr 6) and 63];
        Result[O + 3] := '=';
      end;
  end;
end;

function B64Value(C: AnsiChar): Integer; inline;
begin
  case C of
    'A'..'Z': Result := Ord(C) - Ord('A');
    'a'..'z': Result := Ord(C) - Ord('a') + 26;
    '0'..'9': Result := Ord(C) - Ord('0') + 52;
    '+': Result := 62;
    '/': Result := 63;
  else
    Result := -1;
  end;
end;

function Base64Decode(const S: RawByteString; out Bytes: RawByteString): Boolean;
var
  N, Pad, I, O, K: SizeInt;
  V: LongWord;
  D: Integer;
begin
  Bytes := '';
  Result := False;
  N := Length(S);
  if (N mod 4) <> 0 then
    Exit;
  Pad := 0;
  if (N > 0) and (S[N] = '=') then
  begin
    Pad := 1;
    if S[N - 1] = '=' then
      Pad := 2;
  end;
  SetLength(Bytes, (N div 4) * 3 - Pad);
  O := 1;
  I := 1;
  while I <= N do
  begin
    V := 0;
    for K := 0 to 3 do
    begin
      if (I + K > N - Pad) then
        D := 0                         { a padding position }
      else
      begin
        D := B64Value(S[I + K]);
        if D < 0 then
          Exit;
      end;
      V := (V shl 6) or LongWord(D);
    end;
    if I + 4 > N then
    begin
      { the last group: the bits the padding leaves unused must be zero }
      if (Pad = 1) and ((V and $FF) <> 0) then
        Exit;
      if (Pad = 2) and ((V and $FFFF) <> 0) then
        Exit;
    end;
    if O <= Length(Bytes) then Bytes[O] := AnsiChar(V shr 16);
    if O + 1 <= Length(Bytes) then Bytes[O + 1] := AnsiChar((V shr 8) and $FF);
    if O + 2 <= Length(Bytes) then Bytes[O + 2] := AnsiChar(V and $FF);
    Inc(O, 3);
    Inc(I, 4);
  end;
  Result := True;
end;

function AcceptValue(const Key: RawByteString): RawByteString;
var
  D: TSHA1Digest;
begin
  D := SHA1String(Key + WS_GUID);
  Result := Base64Encode(@D[0], SizeOf(D));
end;

{ ---- TWsHandshake ---- }

function TWsHandshake.Ok: Boolean;
begin
  Result := Status = whOk;
end;

function TWsHandshake.HttpStatus: Word;
begin
  case Status of
    whOk: Result := 101;
    whBadVersion: Result := 426;
  else
    Result := 400;
  end;
end;

function TWsHandshake.Text: RawByteString;
begin
  case Status of
    whOk: Result := 'ok';
    whNotGet: Result := 'a WebSocket handshake must use GET';
    whNotHttp11: Result := 'a WebSocket handshake needs HTTP/1.1';
    whNotUpgrade: Result := 'not an upgrade request';
    whNoUpgradeWebsocket: Result := 'the Upgrade header does not list websocket';
    whNoConnectionUpgrade: Result := 'the Connection header does not list upgrade';
    whBadKey: Result := 'Sec-WebSocket-Key must be one base64 value of 16 bytes';
    whBadVersion: Result := 'unsupported Sec-WebSocket-Version (13 is supported)';
  end;
end;

{ ---- the checks ---- }

function Trimmed(P: PByte; Len: SizeInt): RawByteString;
begin
  while (Len > 0) and (P^ in [9, 32]) do
  begin
    Inc(P);
    Dec(Len);
  end;
  while (Len > 0) and (P[Len - 1] in [9, 32]) do
    Dec(Len);
  SetString(Result, PAnsiChar(P), Len);
end;

{ The first client token (over all Sec-WebSocket-Protocol fields, in order)
  that is in Protocols; '' none. Subprotocol names are compared exactly
  (RFC 6455 section 4.1: they are case-sensitive tokens). }
function ChooseProtocol(Headers: THttpHeaders; const Protocols: array of RawByteString): RawByteString;
var
  I, J: SizeInt;
  K, S: SizeInt;
  P: PByte;
  L: SizeInt;
  Tok: RawByteString;
begin
  Result := '';
  if Length(Protocols) = 0 then
    Exit;
  I := Headers.IndexOf('sec-websocket-protocol');
  while I >= 0 do
  begin
    P := Headers.ValuePtr(I);
    L := Headers.ValueLen(I);
    K := 0;
    while K <= L do
    begin
      S := K;
      while (K < L) and (P[K] <> Ord(',')) do
        Inc(K);
      Tok := Trimmed(P + S, K - S);
      if Tok <> '' then
        for J := 0 to High(Protocols) do
          if Protocols[J] = Tok then
            Exit(Tok);
      Inc(K);
    end;
    I := Headers.IndexOf('sec-websocket-protocol', I + 1);
  end;
end;

function CheckHandshake(Method: THttpMethod; Version: THttpVersion; IsUpgrade: Boolean;
  Headers: THttpHeaders; const Protocols: array of RawByteString): TWsHandshake;
var
  I: SizeInt;
  Key, Raw: RawByteString;
begin
  Result := Default(TWsHandshake);
  if Method <> hmGet then
    Result.Status := whNotGet
  else if Version <> hv11 then
    Result.Status := whNotHttp11
  else if not IsUpgrade then
    Result.Status := whNotUpgrade
  else if not HeaderValueListHas(Headers, 'upgrade', 'websocket') then
    Result.Status := whNoUpgradeWebsocket
  else if not HeaderValueListHas(Headers, 'connection', 'upgrade') then
    Result.Status := whNoConnectionUpgrade
  else
  begin
    { exactly one key field, base64 of 16 bytes }
    I := Headers.IndexOf('sec-websocket-key');
    if (I < 0) or (Headers.IndexOf('sec-websocket-key', I + 1) >= 0) then
      Result.Status := whBadKey
    else
    begin
      Key := Trimmed(Headers.ValuePtr(I), Headers.ValueLen(I));
      if (Length(Key) <> 24) or not Base64Decode(Key, Raw) or (Length(Raw) <> 16) then
        Result.Status := whBadKey
      else
      begin
        I := Headers.IndexOf('sec-websocket-version');
        if (I < 0) or (Headers.IndexOf('sec-websocket-version', I + 1) >= 0)
          or (Trimmed(Headers.ValuePtr(I), Headers.ValueLen(I)) <> '13') then
          Result.Status := whBadVersion
        else
        begin
          Result.Status := whOk;
          Result.Accept := AcceptValue(Key);
          Result.Protocol := ChooseProtocol(Headers, Protocols);
        end;
      end;
    end;
  end;
end;

function CheckRequest(Ex: TExchange; const Protocols: array of RawByteString): TWsHandshake;
begin
  Result := CheckHandshake(Ex.Method, Ex.Version, Ex.WantsUpgrade and (Ex.UpgradeSlot <> nil),
    Ex.Headers, Protocols);
end;

function Respond101(Ex: TExchange; const R: TWsHandshake; H: TUpgradeHandler): Boolean;
var
  RH: THttpHeaders;
begin
  if not R.Ok then
  begin
    if H <> nil then
      H.UpgradeFailed('the WebSocket handshake was refused');
    Exit(False);
  end;
  if Ex.Answered or Ex.IsCanceled then
  begin
    if H <> nil then
      H.UpgradeFailed('the exchange was already answered or canceled');
    Exit(False);
  end;
  Ex.Status := 101;
  RH := Ex.ResponseHeaders;
  RH.Insert('upgrade', 'websocket');
  RH.Insert('connection', 'Upgrade');
  RH.Insert('sec-websocket-accept', R.Accept);
  if R.Protocol <> '' then
    RH.Insert('sec-websocket-protocol', R.Protocol);
  Ex.OnUpgrade(H);
  Result := Ex.Respond(BodyEmpty);
end;

function RespondHandshakeError(Ex: TExchange; const R: TWsHandshake): Boolean;
begin
  if R.Status = whBadVersion then
    Ex.ResponseHeaders.Insert('sec-websocket-version', '13');
  Result := Ex.RespondText(R.HttpStatus, R.Text + #10);
end;

end.
