{ Tests for bearings.ws.handshake: the RFC 6455 accept value (section 1.3
  vector), the base64 codec, every refusal of the opening handshake with
  its HTTP status, and the subprotocol choice. The 101 answer on a real
  connection is tested by test_ws_echo.
  Run: test_ws_handshake --all --format=plain }
program test_ws_handshake;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, fpcunit, testregistry, consoletestrunner, bearings.http.headers,
  bearings.http1.role, bearings.ws.handshake;

type
  TTestHandshake = class(TTestCase)
  private
    H: THttpHeaders;
    function Check(Method: THttpMethod = hmGet; Version: THttpVersion = hv11;
      IsUpgrade: Boolean = True): TWsHandshake;
    procedure Good;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Rfc_accept_vector;
    procedure Base64_vectors;
    procedure Base64_decoder_is_strict;
    procedure Valid_request;
    procedure Header_tokens_are_case_insensitive_lists;
    procedure Refuses_other_methods;
    procedure Refuses_http10;
    procedure Refuses_non_upgrade_request;
    procedure Refuses_missing_upgrade_websocket;
    procedure Refuses_missing_connection_upgrade;
    procedure Refuses_bad_keys;
    procedure Refuses_other_versions_with_426;
    procedure Subprotocol_choice;
  end;

const
  KEY = 'dGhlIHNhbXBsZSBub25jZQ==';

procedure TTestHandshake.SetUp;
begin
  H := THttpHeaders.Create;
end;

procedure TTestHandshake.TearDown;
begin
  H.Free;
end;

procedure TTestHandshake.Good;
begin
  H.Clear;
  H.Add('Host', 'server.example.com');
  H.Add('Upgrade', 'websocket');
  H.Add('Connection', 'Upgrade');
  H.Add('Sec-WebSocket-Key', KEY);
  H.Add('Sec-WebSocket-Version', '13');
end;

function TTestHandshake.Check(Method: THttpMethod; Version: THttpVersion; IsUpgrade: Boolean): TWsHandshake;
begin
  Result := CheckHandshake(Method, Version, IsUpgrade, H, ['chat', 'superchat']);
end;

procedure TTestHandshake.Rfc_accept_vector;
begin
  AssertEquals('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', AcceptValue(KEY));
end;

procedure TTestHandshake.Base64_vectors;
const
  { RFC 4648 section 10 }
  Plain: array[0..6] of RawByteString = ('', 'f', 'fo', 'foo', 'foob', 'fooba', 'foobar');
  Coded: array[0..6] of RawByteString = ('', 'Zg==', 'Zm8=', 'Zm9v', 'Zm9vYg==', 'Zm9vYmE=', 'Zm9vYmFy');
var
  I: Integer;
  D: RawByteString;
begin
  for I := 0 to High(Plain) do
  begin
    AssertEquals('encode ' + Plain[I], Coded[I], Base64Encode(PByte(Plain[I]), Length(Plain[I])));
    AssertTrue('decode ' + Coded[I], Base64Decode(Coded[I], D));
    AssertEquals('decoded ' + Coded[I], Plain[I], D);
  end;
end;

procedure TTestHandshake.Base64_decoder_is_strict;
var
  D: RawByteString;
begin
  AssertFalse('length', Base64Decode('Zm9', D));
  AssertFalse('character', Base64Decode('Zm9!', D));
  AssertFalse('url alphabet', Base64Decode('Zm-_', D));
  AssertFalse('padding inside', Base64Decode('Zg==Zg==', D));
  AssertFalse('unused bits (1 pad)', Base64Decode('Zm9=', D));
  AssertFalse('unused bits (2 pads)', Base64Decode('Zh==', D));
  AssertFalse('space', Base64Decode('Zm9 ', D));
end;

procedure TTestHandshake.Valid_request;
var
  R: TWsHandshake;
begin
  Good;
  R := Check;
  AssertTrue(R.Ok);
  AssertEquals(101, R.HttpStatus);
  AssertEquals('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', R.Accept);
  AssertEquals('no subprotocol asked for', '', R.Protocol);
end;

procedure TTestHandshake.Header_tokens_are_case_insensitive_lists;
var
  R: TWsHandshake;
begin
  H.Clear;
  H.Add('upgrade', 'WebSocket');
  H.Add('connection', 'keep-alive');
  H.Add('connection', 'keep-alive, UPGRADE');
  H.Add('sec-websocket-key', KEY);
  H.Add('sec-websocket-version', ' 13 ');
  R := Check;
  AssertTrue(R.Text, R.Ok);
end;

procedure TTestHandshake.Refuses_other_methods;
begin
  Good;
  AssertTrue(Check(hmPost).Status = whNotGet);
  AssertEquals(400, Check(hmPost).HttpStatus);
  AssertTrue(Check(hmConnect).Status = whNotGet);
end;

procedure TTestHandshake.Refuses_http10;
begin
  Good;
  AssertTrue(Check(hmGet, hv10).Status = whNotHttp11);
  AssertEquals(400, Check(hmGet, hv10).HttpStatus);
end;

procedure TTestHandshake.Refuses_non_upgrade_request;
begin
  Good;
  AssertTrue(Check(hmGet, hv11, False).Status = whNotUpgrade);
end;

procedure TTestHandshake.Refuses_missing_upgrade_websocket;
begin
  Good;
  H.Remove('Upgrade');
  AssertTrue('missing', Check.Status = whNoUpgradeWebsocket);
  H.Add('Upgrade', 'h2c');
  AssertTrue('other protocol', Check.Status = whNoUpgradeWebsocket);
  AssertEquals(400, Check.HttpStatus);
end;

procedure TTestHandshake.Refuses_missing_connection_upgrade;
begin
  Good;
  H.Remove('Connection');
  AssertTrue('missing', Check.Status = whNoConnectionUpgrade);
  H.Add('Connection', 'keep-alive');
  AssertTrue('without upgrade', Check.Status = whNoConnectionUpgrade);
end;

procedure TTestHandshake.Refuses_bad_keys;

  procedure BadKey(const V: RawByteString; const Why: string);
  begin
    Good;
    H.Remove('Sec-WebSocket-Key');
    H.Add('Sec-WebSocket-Key', V);
    AssertTrue(Why, Check.Status = whBadKey);
    AssertEquals(Why, 400, Check.HttpStatus);
  end;

begin
  Good;
  H.Remove('Sec-WebSocket-Key');
  AssertTrue('missing', Check.Status = whBadKey);
  BadKey('', 'empty');
  BadKey('Zm9vYmFy', '6 bytes');
  BadKey('AAAAAAAAAAAAAAAAAAAAAAAAAA==', '19 bytes');
  BadKey('dGhlIHNhbXBsZSBub25jZQ', 'no padding');
  BadKey('dGhlIHNhbXBsZSBub25jZQ!=', 'bad character');
  Good;
  H.Add('Sec-WebSocket-Key', KEY);
  AssertTrue('two key fields', Check.Status = whBadKey);
end;

procedure TTestHandshake.Refuses_other_versions_with_426;

  procedure Version(const V: RawByteString);
  begin
    Good;
    H.Remove('Sec-WebSocket-Version');
    if V <> '-' then
      H.Add('Sec-WebSocket-Version', V);
    AssertTrue('version ' + V, Check.Status = whBadVersion);
    AssertEquals('version ' + V, 426, Check.HttpStatus);
  end;

begin
  Version('-');
  Version('8');
  Version('12');
  Version('14');
  Version('13, 8');
  Good;
  H.Add('Sec-WebSocket-Version', '13');
  AssertTrue('two fields', Check.Status = whBadVersion);
end;

procedure TTestHandshake.Subprotocol_choice;
begin
  Good;
  H.Add('Sec-WebSocket-Protocol', 'superchat, chat');
  AssertEquals('the client''s order decides', 'superchat', Check.Protocol);
  Good;
  H.Add('Sec-WebSocket-Protocol', 'mqtt');
  H.Add('Sec-WebSocket-Protocol', ' foo ,chat');
  AssertEquals('over several fields', 'chat', Check.Protocol);
  Good;
  H.Add('Sec-WebSocket-Protocol', 'CHAT');
  AssertEquals('names are case-sensitive', '', Check.Protocol);
  AssertTrue('no common subprotocol is not a refusal', Check.Ok);
  Good;
  H.Add('Sec-WebSocket-Protocol', 'chat');
  AssertEquals('the application supports none', '',
    CheckHandshake(hmGet, hv11, True, H, []).Protocol);
end;

begin
  RegisterTest(TTestHandshake);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
end.
