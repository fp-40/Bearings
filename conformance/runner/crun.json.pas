{ crun.json - the JSON values of the conformance runner.

  Parsing is fpjson's (FPC's JSON library); its tree is converted to
  TJValue, which keeps what the runner needs: strings as their UTF-8 bytes,
  objects in key order, and numbers with their class (a non-negative
  integer, a negative integer, or a float), because two numbers are equal
  only when class and value are (serde_json's rule, which the case files
  were written against).

  fpjson (FPC 3.2.2) drops a \u0000 escape from a string. ParseJson
  therefore refuses a document that has one, instead of losing the byte: a
  NUL byte is written as a "hex" part in a case file. The program
  must run with DefaultSystemCodePage = CP_UTF8, or fpjson converts the
  decoded strings.

  JsonText writes compact JSON: strings escape '"', '\' and the control
  bytes, other bytes are written as they are (UTF-8).

  Test tooling only. }
unit crun.json;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, jsonparser, jsonscanner;

type
  EJsonError = class(Exception);

  TJKind = (jkNull, jkBool, jkNum, jkStr, jkArr, jkObj);
  TJNumClass = (ncPosInt, ncNegInt, ncFloat);

  TJValue = class
  public
    Kind: TJKind;
    B: Boolean;                      { jkBool }
    NumText: RawByteString;          { jkNum: as written }
    NumClass: TJNumClass;
    U: QWord;                        { ncPosInt }
    I: Int64;                        { ncNegInt }
    F: Double;                       { ncFloat }
    S: RawByteString;                { jkStr: UTF-8 bytes }
    Keys: array of RawByteString;    { jkObj }
    Items: array of TJValue;         { jkArr; jkObj: the values, in key order }
    constructor CreateKind(K: TJKind);
    constructor CreateStr(const V: RawByteString);
    constructor CreateInt(V: Int64);
    destructor Destroy; override;
    function Count: Integer;
    { jkObj: the value of Key, or nil }
    function Get(const Key: RawByteString): TJValue;
    function Has(const Key: RawByteString): Boolean;
    { jkObj: adds or replaces (keeping the first position); owns V }
    procedure Put(const Key: RawByteString; V: TJValue);
    procedure Remove(const Key: RawByteString);
    { jkArr: appends; owns V }
    procedure Append(V: TJValue);
    function Clone: TJValue;
    function IsStr: Boolean;
    function IsObj: Boolean;
    function IsArr: Boolean;
    { serde_json's as_u64: a non-negative integer }
    function AsU64(out V: QWord): Boolean;
  end;

{ Parses one JSON document (fpjson). Raises EJsonError, also for a
  \u0000 escape. }
function ParseJson(const Text: RawByteString): TJValue;
function JsonText(V: TJValue): RawByteString;
function JsonEqual(A, Bv: TJValue): Boolean;
{ A JSON string literal (with the quotes) for the UTF-8 bytes S. }
function JsonStr(const S: RawByteString): RawByteString;
{ The value of Key when it is a string, else Default. }
function GetStr(O: TJValue; const Key: RawByteString; const Default: RawByteString = ''): RawByteString;
function GetU64(O: TJValue; const Key: RawByteString; out V: QWord): Boolean;
function GetBool(O: TJValue; const Key: RawByteString): Boolean;   { False when absent or not a bool }

implementation

{ ---- TJValue ---- }

constructor TJValue.CreateKind(K: TJKind);
begin
  inherited Create;
  Kind := K;
end;

constructor TJValue.CreateStr(const V: RawByteString);
begin
  inherited Create;
  Kind := jkStr;
  S := V;
end;

constructor TJValue.CreateInt(V: Int64);
begin
  inherited Create;
  Kind := jkNum;
  NumText := IntToStr(V);
  if V >= 0 then
  begin
    NumClass := ncPosInt;
    U := QWord(V);
  end
  else
  begin
    NumClass := ncNegInt;
    I := V;
  end;
end;

destructor TJValue.Destroy;
var
  K: Integer;
begin
  for K := 0 to High(Items) do
    Items[K].Free;
  inherited Destroy;
end;

function TJValue.Count: Integer;
begin
  Result := Length(Items);
end;

function TJValue.Get(const Key: RawByteString): TJValue;
var
  K: Integer;
begin
  Result := nil;
  if Kind <> jkObj then
    Exit;
  for K := 0 to High(Keys) do
    if Keys[K] = Key then
      Exit(Items[K]);
end;

function TJValue.Has(const Key: RawByteString): Boolean;
begin
  Result := Get(Key) <> nil;
end;

procedure TJValue.Put(const Key: RawByteString; V: TJValue);
var
  K: Integer;
begin
  for K := 0 to High(Keys) do
    if Keys[K] = Key then
    begin
      Items[K].Free;
      Items[K] := V;
      Exit;
    end;
  SetLength(Keys, Length(Keys) + 1);
  SetLength(Items, Length(Items) + 1);
  Keys[High(Keys)] := Key;
  Items[High(Items)] := V;
end;

procedure TJValue.Remove(const Key: RawByteString);
var
  K, J: Integer;
begin
  for K := 0 to High(Keys) do
    if Keys[K] = Key then
    begin
      Items[K].Free;
      for J := K to High(Keys) - 1 do
      begin
        Keys[J] := Keys[J + 1];
        Items[J] := Items[J + 1];
      end;
      SetLength(Keys, Length(Keys) - 1);
      SetLength(Items, Length(Items) - 1);
      Exit;
    end;
end;

procedure TJValue.Append(V: TJValue);
begin
  SetLength(Items, Length(Items) + 1);
  Items[High(Items)] := V;
end;

function TJValue.Clone: TJValue;
var
  K: Integer;
begin
  Result := TJValue.CreateKind(Kind);
  Result.B := B;
  Result.NumText := NumText;
  Result.NumClass := NumClass;
  Result.U := U;
  Result.I := I;
  Result.F := F;
  Result.S := S;
  SetLength(Result.Keys, Length(Keys));
  SetLength(Result.Items, Length(Items));
  for K := 0 to High(Keys) do
    Result.Keys[K] := Keys[K];
  for K := 0 to High(Items) do
    Result.Items[K] := Items[K].Clone;
end;

function TJValue.IsStr: Boolean;
begin
  Result := Kind = jkStr;
end;

function TJValue.IsObj: Boolean;
begin
  Result := Kind = jkObj;
end;

function TJValue.IsArr: Boolean;
begin
  Result := Kind = jkArr;
end;

function TJValue.AsU64(out V: QWord): Boolean;
begin
  Result := (Kind = jkNum) and (NumClass = ncPosInt);
  if Result then
    V := U
  else
    V := 0;
end;

function GetStr(O: TJValue; const Key: RawByteString; const Default: RawByteString): RawByteString;
var
  V: TJValue;
begin
  V := nil;
  if O <> nil then
    V := O.Get(Key);
  if (V <> nil) and (V.Kind = jkStr) then
    Result := V.S
  else
    Result := Default;
end;

function GetU64(O: TJValue; const Key: RawByteString; out V: QWord): Boolean;
var
  X: TJValue;
begin
  V := 0;
  X := nil;
  if O <> nil then
    X := O.Get(Key);
  Result := (X <> nil) and X.AsU64(V);
end;

function GetBool(O: TJValue; const Key: RawByteString): Boolean;
var
  X: TJValue;
begin
  X := nil;
  if O <> nil then
    X := O.Get(Key);
  Result := (X <> nil) and (X.Kind = jkBool) and X.B;
end;

{ ---- parser (fpjson) ---- }

{ True when the text has a \u0000 escape (a backslash only occurs inside
  strings in valid JSON; an escaped backslash is skipped as a pair) }
function HasNulEscape(const Text: RawByteString): Boolean;
var
  K: SizeInt;
begin
  K := 1;
  while K < Length(Text) do
  begin
    if Text[K] = '\' then
    begin
      if (Text[K + 1] = 'u') and (Copy(Text, K + 2, 4) = '0000') then
        Exit(True);
      Inc(K, 2);
      Continue;
    end;
    Inc(K);
  end;
  Result := False;
end;

function Convert(D: TJSONData): TJValue;
var
  K: Integer;
  O: TJSONObject;
begin
  case D.JSONType of
    jtNull: Result := TJValue.CreateKind(jkNull);
    jtBoolean:
      begin
        Result := TJValue.CreateKind(jkBool);
        Result.B := D.AsBoolean;
      end;
    jtString: Result := TJValue.CreateStr(D.AsString);
    jtNumber:
      begin
        Result := TJValue.CreateKind(jkNum);
        case TJSONNumber(D).NumberType of
          ntFloat:
            begin
              Result.NumClass := ncFloat;
              Result.F := D.AsFloat;
              Result.NumText := D.AsJSON;
            end;
          ntQWord:
            begin
              Result.NumClass := ncPosInt;
              Result.U := D.AsQWord;
              Result.NumText := D.AsString;
            end;
        else
          if D.AsInt64 >= 0 then
          begin
            Result.NumClass := ncPosInt;
            Result.U := QWord(D.AsInt64);
          end
          else
          begin
            Result.NumClass := ncNegInt;
            Result.I := D.AsInt64;
          end;
          Result.NumText := D.AsString;
        end;
      end;
    jtArray:
      begin
        Result := TJValue.CreateKind(jkArr);
        for K := 0 to D.Count - 1 do
          Result.Append(Convert(D.Items[K]));
      end;
    jtObject:
      begin
        Result := TJValue.CreateKind(jkObj);
        O := TJSONObject(D);
        for K := 0 to O.Count - 1 do
          Result.Put(O.Names[K], Convert(O.Items[K]));
      end;
  else
    raise EJsonError.Create('unknown JSON value');
  end;
end;

function ParseJson(const Text: RawByteString): TJValue;
var
  P: TJSONParser;
  D: TJSONData;
begin
  if HasNulEscape(Text) then
    raise EJsonError.Create('\u0000 in a JSON string is not supported (fpjson drops it); ' +
      'write a NUL byte as a {"hex": "00"} part');
  D := nil;
  P := TJSONParser.Create(Text, [joUTF8]);
  try
    try
      D := P.Parse;
    except
      on E: Exception do
        raise EJsonError.Create(E.Message);
    end;
    if D = nil then
      raise EJsonError.Create('empty document');
    Result := Convert(D);
  finally
    D.Free;
    P.Free;
  end;
end;

{ ---- writer ---- }

function JsonStr(const S: RawByteString): RawByteString;
const
  HexD: array[0..15] of AnsiChar = '0123456789abcdef';
var
  K: SizeInt;
  C: AnsiChar;
begin
  Result := '"';
  for K := 1 to Length(S) do
  begin
    C := S[K];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
      #8: Result := Result + '\b';
      #12: Result := Result + '\f';
      #0..#7, #11, #14..#31:
        Result := Result + '\u00' + HexD[Ord(C) shr 4] + HexD[Ord(C) and 15];
    else
      Result := Result + C;
    end;
  end;
  Result := Result + '"';
end;

function JsonText(V: TJValue): RawByteString;
var
  K: Integer;
begin
  case V.Kind of
    jkNull: Result := 'null';
    jkBool: if V.B then Result := 'true' else Result := 'false';
    jkNum: Result := V.NumText;
    jkStr: Result := JsonStr(V.S);
    jkArr:
      begin
        Result := '[';
        for K := 0 to High(V.Items) do
        begin
          if K > 0 then
            Result := Result + ',';
          Result := Result + JsonText(V.Items[K]);
        end;
        Result := Result + ']';
      end;
    jkObj:
      begin
        Result := '{';
        for K := 0 to High(V.Keys) do
        begin
          if K > 0 then
            Result := Result + ',';
          Result := Result + JsonStr(V.Keys[K]) + ':' + JsonText(V.Items[K]);
        end;
        Result := Result + '}';
      end;
  end;
end;

function JsonEqual(A, Bv: TJValue): Boolean;
var
  K: Integer;
  X: TJValue;
begin
  if (A = nil) or (Bv = nil) then
    Exit(A = Bv);
  if A.Kind <> Bv.Kind then
    Exit(False);
  case A.Kind of
    jkNull: Result := True;
    jkBool: Result := A.B = Bv.B;
    jkNum:
      begin
        if A.NumClass <> Bv.NumClass then
          Exit(False);
        case A.NumClass of
          ncPosInt: Result := A.U = Bv.U;
          ncNegInt: Result := A.I = Bv.I;
          ncFloat: Result := A.F = Bv.F;
        end;
      end;
    jkStr: Result := A.S = Bv.S;
    jkArr:
      begin
        if Length(A.Items) <> Length(Bv.Items) then
          Exit(False);
        for K := 0 to High(A.Items) do
          if not JsonEqual(A.Items[K], Bv.Items[K]) then
            Exit(False);
        Result := True;
      end;
    jkObj:
      begin
        { serde_json maps compare as maps: same keys, equal values }
        if Length(A.Keys) <> Length(Bv.Keys) then
          Exit(False);
        for K := 0 to High(A.Keys) do
        begin
          X := Bv.Get(A.Keys[K]);
          if (X = nil) or not JsonEqual(A.Items[K], X) then
            Exit(False);
        end;
        Result := True;
      end;
  end;
end;

end.
