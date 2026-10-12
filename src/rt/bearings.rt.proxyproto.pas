{ bearings.rt.proxyproto - the PROXY protocol header (HAProxy), versions 1
  and 2: the client address a proxy or load balancer puts in front of the
  first bytes of a connection it forwards.

  A server behind HAProxy, a cloud load balancer, or nginx on a Unix
  socket (proxy_protocol on) otherwise sees the proxy's address as the
  peer. With the protocol, the proxy sends one header per connection
  before the first request:
    v1: a text line, "PROXY TCP4 <src> <dst> <srcport> <dstport>\r\n"
        (TCP6 for IPv6; "PROXY UNKNOWN ...\r\n" when it has no address),
        at most 107 bytes.
    v2: a 12-byte signature, a version/command byte, a family/protocol
        byte, a 16-bit length, then the addresses and optional TLVs.
  ParseProxyHeader reads one header from the start of a buffer. It is a
  pure function over the bytes: it needs no socket. The specification is
  https://www.haproxy.org/download/2.9/doc/proxy-protocol.txt.

  Security: the header is trusted, so the protocol must be on only for a
  listener that only the proxy can reach (a Unix socket, a private
  network, a firewall); a direct client could otherwise claim any address.
  When it is on, a connection must start with the header: a connection
  without one is refused (the bytes are not a request). This is HAProxy's
  "accept-proxy" and nginx's "proxy_protocol" behaviour. }
unit bearings.rt.proxyproto;

{$mode objfpc}{$H+}

interface

uses
  bearings.rt.sys;

const
  PROXY_V1_MAX = 107;              { the longest v1 line, CRLF included (the specification) }
  { the most bytes accepted for a v2 header (16 + addresses + TLVs); a
    longer one is an error. The specification's address blocks are at most
    216 bytes; TLVs (none are used here) add the rest. }
  PROXY_MAX = 4096;

type
  TProxyParse = (ppNeedMore, ppOk, ppError);

{ Parses one PROXY header at P[0..Len-1]. ppOk: Used is the header's
  length; when the header carried an address (v1 TCP4/TCP6, v2 PROXY with
  an IPv4 or IPv6 block), HasPeer is True and Peer holds the source address
  and port; otherwise (v1 UNKNOWN, v2 LOCAL, v2 with an unspecified or
  Unix address) HasPeer is False and Peer is untouched: the socket's own
  peer stays. ppNeedMore: the bytes so far are a valid prefix of a header;
  read more. ppError: not a PROXY header, or an invalid one. }
function ParseProxyHeader(P: PByte; Len: SizeInt; out Used: SizeInt; out HasPeer: Boolean;
  var Peer: TSockAddrStorage): TProxyParse;

implementation

uses
  Sockets, bearings.rt.net;

const
  V1_SIG: array[0..5] of AnsiChar = 'PROXY ';
  V2_SIG: array[0..11] of Byte = ($0D, $0A, $0D, $0A, $00, $0D, $0A, $51, $55, $49, $54, $0A);

{ the bytes so far agree with the signature (a prefix of it, or all of it) }
function PrefixOf(P: PByte; Len: SizeInt; Sig: PByte; SigLen: SizeInt): Boolean;
var
  N: SizeInt;
begin
  N := Len;
  if N > SigLen then
    N := SigLen;
  Result := CompareByte(P^, Sig^, N) = 0;
end;

{ ---- v1 ---- }

{ the next space-separated field of the line; False when there is none }
function NextField(const S: RawByteString; var Pos: SizeInt; out F: RawByteString): Boolean;
var
  Start: SizeInt;
begin
  Start := Pos;
  while (Pos <= Length(S)) and (S[Pos] <> ' ') do
    Inc(Pos);
  F := Copy(S, Start, Pos - Start);
  if Pos <= Length(S) then
    Inc(Pos);                        { the space }
  Result := F <> '';
end;

function PortOf(const F: RawByteString; out Port: Word): Boolean;
var
  I, V: Integer;
begin
  Result := False;
  if (F = '') or (Length(F) > 5) then
    Exit;
  V := 0;
  for I := 1 to Length(F) do
  begin
    if not (F[I] in ['0'..'9']) then
      Exit;
    V := V * 10 + (Ord(F[I]) - Ord('0'));
  end;
  if V > 65535 then
    Exit;
  Port := V;
  Result := True;
end;

function ParseV1(P: PByte; Len: SizeInt; out Used: SizeInt; out HasPeer: Boolean;
  var Peer: TSockAddrStorage): TProxyParse;
var
  I, Pos: SizeInt;
  Line, Proto, Src, Dst, SrcPort, DstPort: RawByteString;
  SPort, DPort: Word;
  A: TSockAddrStorage;
  ALen: Cardinal;
  Want: Word;
begin
  HasPeer := False;
  { the line ends with CRLF within PROXY_V1_MAX bytes }
  I := 0;
  while (I + 1 < Len) and (I + 1 < PROXY_V1_MAX) do
  begin
    if (P[I] = 13) and (P[I + 1] = 10) then
      Break;
    Inc(I);
  end;
  if (I + 1 >= Len) then
  begin
    if Len >= PROXY_V1_MAX then
      Exit(ppError);                 { no CRLF where the line must have ended }
    Exit(ppNeedMore);
  end;
  if not ((P[I] = 13) and (P[I + 1] = 10)) then
    Exit(ppError);
  Used := I + 2;
  SetString(Line, PAnsiChar(P) + 6, I - 6);  { after "PROXY " }
  Pos := 1;
  if not NextField(Line, Pos, Proto) then
    Exit(ppError);
  if Proto = 'UNKNOWN' then
    Exit(ppOk);                      { anything may follow; the socket's peer stays }
  if Proto = 'TCP4' then
    Want := AF_INET
  else if Proto = 'TCP6' then
    Want := AF_INET6
  else
    Exit(ppError);
  if not (NextField(Line, Pos, Src) and NextField(Line, Pos, Dst) and NextField(Line, Pos, SrcPort)
      and NextField(Line, Pos, DstPort)) or (Pos <= Length(Line)) then
    Exit(ppError);
  if not (PortOf(SrcPort, SPort) and PortOf(DstPort, DPort)) then
    Exit(ppError);
  { both addresses must parse in the named family; only the source is kept }
  if not MakeSockAddr(Dst, DPort, A, ALen) or (A.Family <> Want) then
    Exit(ppError);
  if not MakeSockAddr(Src, SPort, A, ALen) or (A.Family <> Want) then
    Exit(ppError);
  Peer := A;
  HasPeer := True;
  Result := ppOk;
end;

{ ---- v2 ---- }

function ParseV2(P: PByte; Len: SizeInt; out Used: SizeInt; out HasPeer: Boolean;
  var Peer: TSockAddrStorage): TProxyParse;
var
  Total, BodyLen: SizeInt;
  Cmd, Fam: Byte;
  S4: PInetSockAddr;
  S6: PInetSockAddr6;
begin
  HasPeer := False;
  if Len < 16 then
    Exit(ppNeedMore);
  if (P[12] shr 4) <> 2 then
    Exit(ppError);                   { not version 2 }
  Cmd := P[12] and $F;
  if Cmd > 1 then
    Exit(ppError);                   { 0 LOCAL, 1 PROXY }
  BodyLen := (SizeInt(P[14]) shl 8) or P[15];
  Total := 16 + BodyLen;
  if Total > PROXY_MAX then
    Exit(ppError);
  if Len < Total then
    Exit(ppNeedMore);
  Used := Total;
  if Cmd = 0 then
    Exit(ppOk);                      { LOCAL: the proxy's own connection (a health check); the socket's peer stays }
  Fam := P[13] shr 4;
  case Fam of
    1:                               { AF_INET: src, dst, src port, dst port }
      begin
        if BodyLen < 12 then
          Exit(ppError);
        FillChar(Peer, SizeOf(Peer), 0);
        S4 := PInetSockAddr(@Peer);
        S4^.sin_family := AF_INET;
        Move(P[16], S4^.sin_addr, 4);
        Move(P[24], S4^.sin_port, 2);            { already in network order }
        HasPeer := True;
      end;
    2:                               { AF_INET6 }
      begin
        if BodyLen < 36 then
          Exit(ppError);
        FillChar(Peer, SizeOf(Peer), 0);
        S6 := PInetSockAddr6(@Peer);
        S6^.sin6_family := AF_INET6;
        Move(P[16], S6^.sin6_addr, 16);
        Move(P[48], S6^.sin6_port, 2);
        HasPeer := True;
      end;
    0, 3:
      { AF_UNSPEC: no address; AF_UNIX: a path, not kept (the socket's peer
        stays) }
      ;
  else
    Exit(ppError);
  end;
  Result := ppOk;
end;

function ParseProxyHeader(P: PByte; Len: SizeInt; out Used: SizeInt; out HasPeer: Boolean;
  var Peer: TSockAddrStorage): TProxyParse;
begin
  Used := 0;
  HasPeer := False;
  if Len = 0 then
    Exit(ppNeedMore);
  if PrefixOf(P, Len, @V1_SIG[0], SizeOf(V1_SIG)) then
  begin
    if Len < SizeOf(V1_SIG) then
      Exit(ppNeedMore);
    Exit(ParseV1(P, Len, Used, HasPeer, Peer));
  end;
  if PrefixOf(P, Len, @V2_SIG[0], SizeOf(V2_SIG)) then
  begin
    if Len < SizeOf(V2_SIG) then
      Exit(ppNeedMore);
    Exit(ParseV2(P, Len, Used, HasPeer, Peer));
  end;
  Result := ppError;
end;

end.
