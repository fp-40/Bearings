{ Tests for bearings.ws.frame: the incremental UTF-8 check, the server frame
  header encoder, and the client frame reader (every length form, masking,
  every protocol error with its close code, UTF-8 across fragment
  boundaries, control frames between fragments, the message size limit),
  plus a split fuzz: the same frames delivered in random pieces must give
  the same events as when delivered whole.
  Run: test_ws_frame --all --format=plain }
program test_ws_frame;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, fpcunit, testregistry, consoletestrunner, bearings.ws.frame, bearings.test.ws;

type
  TTestUtf8 = class(TTestCase)
  published
    procedure Valid_texts;
    procedure Invalid_texts;
    procedure Split_at_every_position;
  end;

  TTestEncoder = class(TTestCase)
  published
    procedure Length_forms;
    procedure Prepared_frames;
  end;

  TTestReader = class(TTestCase)
  published
    procedure Length_forms_and_masks;
    procedure Non_minimal_length_is_accepted;
    procedure Empty_messages;
    procedure Fragmented_message_with_control_frames_between;
    procedure Unmasked_frame_is_1002;
    procedure Reserved_bits_are_1002;
    procedure Reserved_opcodes_are_1002;
    procedure Fragmented_control_frame_is_1002;
    procedure Long_control_frame_is_1002;
    procedure Length_top_bit_is_1002;
    procedure Continuation_without_message_is_1002;
    procedure New_message_inside_fragmented_is_1002;
    procedure Message_size_limit_is_1009;
    procedure Utf8_across_fragments;
    procedure Invalid_utf8_is_1007;
    procedure Close_payload_rules;
    procedure Reader_stays_failed;
  end;

  TTestSplitFuzz = class(TTestCase)
  published
    procedure Random_splits_give_the_same_events;
  end;

{ ---- UTF-8 ---- }

function U8(const S: RawByteString): Boolean;
begin
  Result := WsValidUtf8(PByte(S), Length(S));
end;

procedure TTestUtf8.Valid_texts;
begin
  AssertTrue('empty', U8(''));
  AssertTrue('ascii', U8('Hello, world 0123456789 abcdefghijklmnop'));
  AssertTrue('2-byte', U8(#$C2#$A9));
  AssertTrue('3-byte', U8(#$E2#$82#$AC));
  AssertTrue('U+0800', U8(#$E0#$A0#$80));
  AssertTrue('U+D7FF', U8(#$ED#$9F#$BF));
  AssertTrue('U+E000', U8(#$EE#$80#$80));
  AssertTrue('U+10000', U8(#$F0#$90#$80#$80));
  AssertTrue('U+10FFFF', U8(#$F4#$8F#$BF#$BF));
  AssertTrue('Hello-µ@ßöäüàá-UTF-8!!',
    U8('Hello-'#$C2#$B5'@'#$C3#$9F#$C3#$B6#$C3#$A4#$C3#$BC#$C3#$A0#$C3#$A1'-UTF-8!!'));
end;

procedure TTestUtf8.Invalid_texts;
begin
  AssertFalse('lone continuation', U8(#$80));
  AssertFalse('C0 overlong', U8(#$C0#$80));
  AssertFalse('C1 overlong', U8(#$C1#$BF));
  AssertFalse('E0 overlong', U8(#$E0#$9F#$BF));
  AssertFalse('surrogate D800', U8(#$ED#$A0#$80));
  AssertFalse('surrogate DFFF', U8(#$ED#$BF#$BF));
  AssertFalse('F0 overlong', U8(#$F0#$8F#$BF#$BF));
  AssertFalse('above 10FFFF', U8(#$F4#$90#$80#$80));
  AssertFalse('F5', U8(#$F5#$80#$80#$80));
  AssertFalse('FF', U8(#$FF));
  AssertFalse('truncated 3-byte', U8(#$E2#$82));
  AssertFalse('ascii then bad after 8-byte run', U8('abcdefgh'#$FE));
  AssertFalse('missing continuation', U8(#$C2'a'));
end;

procedure TTestUtf8.Split_at_every_position;
const
  S: RawByteString = 'ab'#$C2#$A9'cdefghijk'#$E2#$82#$AC'lmnopqrstu'#$F0#$9F#$98#$80'z';
  Bad: RawByteString = 'abcdefghij'#$F0#$9F#$98'z';
var
  I: Integer;
  C: TUtf8Check;
begin
  for I := 0 to Length(S) do
  begin
    C := Default(TUtf8Check);
    AssertTrue('first part ' + IntToStr(I), C.Feed(PByte(S), I));
    AssertTrue('second part ' + IntToStr(I), C.Feed(PByte(S) + I, Length(S) - I));
    AssertTrue('complete ' + IntToStr(I), C.Complete);
  end;
  for I := 0 to Length(Bad) do
  begin
    C := Default(TUtf8Check);
    AssertFalse('bad split ' + IntToStr(I),
      C.Feed(PByte(Bad), I) and C.Feed(PByte(Bad) + I, Length(Bad) - I));
  end;
end;

{ ---- encoder ---- }

procedure TTestEncoder.Length_forms;
var
  B: array[0..WS_MAX_HEADER - 1] of Byte;
begin
  AssertEquals(2, WsEncodeHeader(@B[0], True, WS_OP_TEXT, 0));
  AssertEquals($81, B[0]);
  AssertEquals(0, B[1]);
  AssertEquals(2, WsEncodeHeader(@B[0], False, WS_OP_BINARY, 125));
  AssertEquals($02, B[0]);
  AssertEquals(125, B[1]);
  AssertEquals(4, WsEncodeHeader(@B[0], True, WS_OP_BINARY, 126));
  AssertEquals(126, B[1]);
  AssertEquals(0, B[2]);
  AssertEquals(126, B[3]);
  AssertEquals(4, WsEncodeHeader(@B[0], True, WS_OP_BINARY, 65535));
  AssertEquals($FF, B[2]);
  AssertEquals($FF, B[3]);
  AssertEquals(10, WsEncodeHeader(@B[0], True, WS_OP_BINARY, 65536));
  AssertEquals(127, B[1]);
  AssertEquals(0, B[2]);
  AssertEquals(1, B[7]);
  AssertEquals(0, B[8]);
  AssertEquals(0, B[9]);
  AssertEquals(10, WsHeaderSize(QWord(1) shl 40));
  AssertEquals(4, WsHeaderSize(200));
  AssertEquals(2, WsHeaderSize(5));
end;

procedure TTestEncoder.Prepared_frames;
var
  F: TWsFrame;
  Op: Byte;
  S: RawByteString;
begin
  F := WsTextFrame('hello');
  AssertEquals(#$81#5'hello', F);
  AssertTrue(WsFrameValid(F, Op));
  AssertEquals(WS_OP_TEXT, Op);
  F := WsBinaryFrame(Pattern(70000));
  AssertEquals(10 + 70000, Length(F));
  AssertTrue(WsFrameValid(F, Op));
  AssertEquals(WS_OP_BINARY, Op);
  S := F;
  AssertEquals('the payload follows the header', Pattern(70000), Copy(S, 11, MaxInt));
  F := WsMakeFrame(WS_OP_PING, nil, 0);
  AssertTrue(WsFrameValid(F, Op));
  AssertEquals(WS_OP_PING, Op);
  AssertEquals(WS_OP_BINARY, Byte(WsBinaryFrame(StringOfChar('x', 300))[1]) and $0F);
  AssertFalse('empty', WsFrameValid('', Op));
  AssertFalse('not final', WsFrameValid(#$01#0, Op));
  AssertFalse('RSV1', WsFrameValid(#$C1#0, Op));
  AssertFalse('continuation', WsFrameValid(#$80#0, Op));
  AssertFalse('reserved opcode', WsFrameValid(#$83#0, Op));
  AssertFalse('masked', WsFrameValid(#$81#$81'abcdx', Op));
  AssertFalse('too short', WsFrameValid(#$81#5'hell', Op));
  AssertFalse('too long', WsFrameValid(#$81#5'hello!', Op));
  AssertFalse('long ping', WsFrameValid(WsMakeFrame(WS_OP_PING, PByte(StringOfChar('p', 126)), 126), Op));
end;

{ ---- reader ---- }

procedure TTestReader.Length_forms_and_masks;
var
  N: Integer;
  P: RawByteString;
const
  Lens: array[0..8] of Integer = (0, 1, 7, 125, 126, 127, 65535, 65536, 100001);
begin
  for N in Lens do
  begin
    P := Pattern(N);
    AssertEquals('len ' + IntToStr(N), 'B' + IntToStr(N) + ':' + Digest(P) + '|',
      ReadAll(CFrame(WS_OP_BINARY, P, True, $A1B2C3D4 + LongWord(N)), 0));
  end;
  AssertEquals('mask 0', 'T5:' + Digest('hello') + '|', ReadAll(CFrame(WS_OP_TEXT, 'hello', True, 0), 0));
end;

procedure TTestReader.Non_minimal_length_is_accepted;
begin
  AssertEquals('T3:' + Digest('abc') + '|', ReadAll(CFrameForm(WS_OP_TEXT, 'abc', 126), 0));
  AssertEquals('T3:' + Digest('abc') + '|', ReadAll(CFrameForm(WS_OP_TEXT, 'abc', 127), 0));
end;

procedure TTestReader.Empty_messages;
begin
  AssertEquals('T0:' + Digest('') + '|', ReadAll(CFrame(WS_OP_TEXT, ''), 0));
  AssertEquals('B0:' + Digest('') + '|', ReadAll(CFrame(WS_OP_BINARY, ''), 0));
  { an empty first fragment, an empty last one }
  AssertEquals('T2:' + Digest('ab') + '|',
    ReadAll(CFrame(WS_OP_TEXT, '', False) + CFrame(WS_OP_CONT, 'ab', False) + CFrame(WS_OP_CONT, ''), 0));
  AssertEquals('empty ping', 'C9:|', ReadAll(CFrame(WS_OP_PING, ''), 0));
end;

procedure TTestReader.Fragmented_message_with_control_frames_between;
begin
  AssertEquals('C9:p1|C10:p2|T9:' + Digest('abcdefghi') + '|',
    ReadAll(CFrame(WS_OP_TEXT, 'abc', False) + CFrame(WS_OP_PING, 'p1') + CFrame(WS_OP_CONT, 'def', False)
      + CFrame(WS_OP_PONG, 'p2') + CFrame(WS_OP_CONT, 'ghi'), 0));
end;

procedure TTestReader.Unmasked_frame_is_1002;
begin
  AssertEquals('E1002|', ReadAll(CFrameRaw($81, 'hi', False), 0));
end;

procedure TTestReader.Reserved_bits_are_1002;
begin
  AssertEquals('RSV1', 'E1002|', ReadAll(CFrameRaw($C1, 'hi', True), 0));
  AssertEquals('RSV2', 'E1002|', ReadAll(CFrameRaw($A1, 'hi', True), 0));
  AssertEquals('RSV3', 'E1002|', ReadAll(CFrameRaw($91, 'hi', True), 0));
  AssertEquals('RSV on ping', 'E1002|', ReadAll(CFrameRaw($F9, '', True), 0));
end;

procedure TTestReader.Reserved_opcodes_are_1002;
var
  Op: Integer;
begin
  for Op := 3 to 7 do
    AssertEquals('op ' + IntToStr(Op), 'E1002|', ReadAll(CFrameRaw($80 or Op, '', True), 0));
  for Op := 11 to 15 do
    AssertEquals('op ' + IntToStr(Op), 'E1002|', ReadAll(CFrameRaw($80 or Op, '', True), 0));
  { after a valid message }
  AssertEquals('T1:' + Digest('a') + '|E1002|', ReadAll(CFrame(WS_OP_TEXT, 'a') + CFrameRaw($85, 'x', True), 0));
end;

procedure TTestReader.Fragmented_control_frame_is_1002;
begin
  AssertEquals('E1002|', ReadAll(CFrame(WS_OP_PING, 'x', False), 0));
end;

procedure TTestReader.Long_control_frame_is_1002;
begin
  AssertEquals('125 ok', 'C9:' + StringOfChar('*', 125) + '|',
    ReadAll(CFrame(WS_OP_PING, StringOfChar('*', 125)), 0));
  AssertEquals('126', 'E1002|', ReadAll(CFrame(WS_OP_PING, StringOfChar('*', 126)), 0));
end;

procedure TTestReader.Length_top_bit_is_1002;
var
  S: RawByteString;
begin
  S := #$82#$FF#$80#0#0#0#0#0#0#1'mask';
  AssertEquals('E1002|', ReadAll(S, 0));
end;

procedure TTestReader.Continuation_without_message_is_1002;
begin
  AssertEquals('E1002|', ReadAll(CFrame(WS_OP_CONT, 'x'), 0));
  AssertEquals('after a complete message', 'T1:' + Digest('a') + '|E1002|',
    ReadAll(CFrame(WS_OP_TEXT, 'a') + CFrame(WS_OP_CONT, 'x'), 0));
end;

procedure TTestReader.New_message_inside_fragmented_is_1002;
begin
  AssertEquals('E1002|', ReadAll(CFrame(WS_OP_TEXT, 'a', False) + CFrame(WS_OP_BINARY, 'b'), 0));
end;

procedure TTestReader.Message_size_limit_is_1009;
begin
  AssertEquals('at the limit', 'B10:' + Digest(Pattern(10)) + '|', ReadAll(CFrame(WS_OP_BINARY, Pattern(10)), 10));
  AssertEquals('one frame over', 'E1009|', ReadAll(CFrame(WS_OP_BINARY, Pattern(11)), 10));
  AssertEquals('fragments over', 'E1009|',
    ReadAll(CFrame(WS_OP_BINARY, Pattern(6), False) + CFrame(WS_OP_CONT, Pattern(5)), 10));
  AssertEquals('the limit is per message', 'B6:' + Digest(Pattern(6)) + '|B6:' + Digest(Pattern(6)) + '|',
    ReadAll(CFrame(WS_OP_BINARY, Pattern(6)) + CFrame(WS_OP_BINARY, Pattern(6)), 10));
end;

procedure TTestReader.Utf8_across_fragments;
const
  Text: RawByteString = 'a'#$F0#$9F#$98#$80'b'#$E2#$82#$AC'c';
var
  I, J: Integer;
  S: RawByteString;
begin
  { every way to cut the text into three fragments }
  for I := 0 to Length(Text) do
    for J := I to Length(Text) do
    begin
      S := CFrame(WS_OP_TEXT, Copy(Text, 1, I), False) + CFrame(WS_OP_CONT, Copy(Text, I + 1, J - I), False)
        + CFrame(WS_OP_CONT, Copy(Text, J + 1, MaxInt));
      AssertEquals(IntToStr(I) + '/' + IntToStr(J), 'T' + IntToStr(Length(Text)) + ':' + Digest(Text) + '|',
        ReadAll(S, 0));
    end;
end;

procedure TTestReader.Invalid_utf8_is_1007;
begin
  AssertEquals('one frame', 'E1007|', ReadAll(CFrame(WS_OP_TEXT, 'ab'#$FF), 0));
  AssertEquals('cut at the end', 'E1007|', ReadAll(CFrame(WS_OP_TEXT, 'ab'#$E2#$82), 0));
  AssertEquals('cut at the end of fragments', 'E1007|',
    ReadAll(CFrame(WS_OP_TEXT, 'ab'#$E2, False) + CFrame(WS_OP_CONT, #$82), 0));
  AssertEquals('cut at an empty last fragment', 'E1007|',
    ReadAll(CFrame(WS_OP_TEXT, 'ab'#$E2#$82, False) + CFrame(WS_OP_CONT, ''), 0));
  AssertEquals('invalid in the first fragment, found before the rest arrives', 'E1007|',
    ReadAll(CFrame(WS_OP_TEXT, #$ED#$A0#$80, False), 0));
  AssertEquals('binary is not checked', 'B1:' + Digest(#$FF) + '|', ReadAll(CFrame(WS_OP_BINARY, #$FF), 0));
end;

function CloseP(Code: Word; const Reason: RawByteString): RawByteString;
begin
  Result := AnsiChar(Code shr 8) + AnsiChar(Code and $FF) + Reason;
end;

procedure TTestReader.Close_payload_rules;
const
  Valid: array[0..15] of Word = (1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013,
    1014, 3000, 3999, 4000, 4999);
  Invalid: array[0..11] of Word = (0, 999, 1004, 1005, 1006, 1015, 1016, 1100, 2000, 2999, 5000, 65535);
var
  C: Word;
begin
  AssertEquals('empty', 'C8:|', ReadAll(CFrame(WS_OP_CLOSE, ''), 0));
  AssertEquals('1 byte', 'E1002|', ReadAll(CFrame(WS_OP_CLOSE, 'x'), 0));
  for C in Valid do
    AssertEquals('valid ' + IntToStr(C), 'C8:' + CloseP(C, 'ok') + '|', ReadAll(CFrame(WS_OP_CLOSE, CloseP(C, 'ok')), 0));
  for C in Invalid do
    AssertEquals('invalid ' + IntToStr(C), 'E1002|', ReadAll(CFrame(WS_OP_CLOSE, CloseP(C, '')), 0));
  AssertEquals('reason not UTF-8', 'E1007|', ReadAll(CFrame(WS_OP_CLOSE, CloseP(1000, #$C0)), 0));
end;

procedure TTestReader.Reader_stays_failed;
var
  R: TWsReader;
  S: RawByteString;
  P: PByte;
  L: SizeInt;
begin
  R.Init(0);
  S := CFrameRaw($81, 'hi', False) + CFrame(WS_OP_TEXT, 'ok');
  UniqueString(S);
  P := PByte(S);
  L := Length(S);
  AssertTrue(R.Next(P, L) = reError);
  AssertTrue(R.Failed);
  AssertTrue('again', R.Next(P, L) = reError);
end;

{ ---- split fuzz ---- }

procedure TTestSplitFuzz.Random_splits_give_the_same_events;
var
  Corpus, Whole, Pieces: RawByteString;
  Seed, Seeds: Integer;
begin
  Corpus := CFrame(WS_OP_TEXT, 'hello') + CFrame(WS_OP_BINARY, Pattern(300))
    + CFrame(WS_OP_TEXT, 'a'#$F0#$9F#$98, False) + CFrame(WS_OP_PING, 'p') + CFrame(WS_OP_CONT, #$80'xyz', False)
    + CFrame(WS_OP_CONT, #$E2#$82#$AC) + CFrame(WS_OP_BINARY, Pattern(70000), True, $01020304)
    + CFrame(WS_OP_PONG, '') + CFrame(WS_OP_BINARY, '') + CFrame(WS_OP_TEXT, StringOfChar('q', 126))
    + CFrame(WS_OP_CLOSE, CloseP(1000, 'bye'));
  Whole := ReadAll(Corpus, 0);
  AssertTrue('the corpus reads cleanly: ' + Whole, Pos('|E', '|' + Whole) = 0);
  Seeds := StrToIntDef(GetEnvironmentVariable('FUZZ_SEEDS'), 2000);
  for Seed := 1 to Seeds do
  begin
    Pieces := ReadSplit(Corpus, 0, Seed);
    if Pieces <> Whole then
      Fail('seed ' + IntToStr(Seed) + ' gave other events');
  end;
  { an error is found at the same place in any split }
  Corpus := CFrame(WS_OP_TEXT, 'ok') + CFrame(WS_OP_TEXT, 'abc'#$ED#$A0#$80'def');
  Whole := ReadAll(Corpus, 0);
  for Seed := 1 to 200 do
    AssertEquals('error seed ' + IntToStr(Seed), Whole, ReadSplit(Corpus, 0, Seed));
end;

begin
  RegisterTest(TTestUtf8);
  RegisterTest(TTestEncoder);
  RegisterTest(TTestReader);
  RegisterTest(TTestSplitFuzz);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
end.
