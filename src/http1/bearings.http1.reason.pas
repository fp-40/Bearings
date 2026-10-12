{ bearings.http1.reason - the reason phrase of an HTTP/1.1 status line.

  A response starts with a status line such as "HTTP/1.1 404 Not Found".
  "Not Found" is the reason phrase: text for humans, which clients ignore
  (RFC 9112 section 4). The server writes the phrase the application set
  for the response, or else the standard phrase for the status code from
  CanonicalReason, or else an empty phrase.

  Main types and routines:
  - TReasonPhrase: a validated copy of a custom phrase.
  - IsValidReasonByte / FindInvalidReasonByte: the byte check. A phrase may
    contain HTAB, SP, visible ASCII (0x21..0x7E) and obs-text (0x80..0xFF);
    any other byte, in particular CR or LF, is rejected, because it would
    end the status line early and let the phrase inject header lines into
    the response.
  - CanonicalReason / CanonicalReasonStr: the standard phrase of a code.

  Threading: no shared state; every routine may run on any thread. }
unit bearings.http1.reason;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils;

type
  { Raised by TReasonPhrase.FromStatic when the phrase has an invalid byte. }
  EInvalidReasonPhrase = class(Exception)
  private
    FBadByte: Byte;
  public
    constructor CreateBadByte(ABadByte: Byte);
    property BadByte: Byte read FBadByte;
  end;

  { A custom reason phrase. Holds a copy of the phrase bytes, validated
    (except with FromBytesUnchecked). }
  TReasonPhrase = record
  private
    FBytes: RawByteString;
  public
    { False, with the first invalid byte in BadByte, if a byte is invalid. }
    class function TryFrom(P: PByte; Len: SizeInt; out R: TReasonPhrase; out BadByte: Byte): Boolean; static; overload;
    class function TryFrom(const S: RawByteString; out R: TReasonPhrase; out BadByte: Byte): Boolean; static; overload;
    class function TryFrom(const S: RawByteString; out R: TReasonPhrase): Boolean; static; overload;
    { For phrases written in the program: raises EInvalidReasonPhrase on an
      invalid byte, since that is a programming error. Keeps a reference
      to S (no copy). }
    class function FromStatic(const S: RawByteString): TReasonPhrase; static;
    { Copies the bytes without checking them. Only for bytes already
      checked, for example a phrase taken from a parsed status line. }
    class function FromBytesUnchecked(P: PByte; Len: SizeInt): TReasonPhrase; static;
    function AsBytes: RawByteString;
    function Data: PByte;
    function Len: SizeInt;
  end;

function IsValidReasonByte(B: Byte): Boolean; inline;
{ True, with the first invalid byte in BadByte, if a byte is invalid. }
function FindInvalidReasonByte(P: PByte; Len: SizeInt; out BadByte: Byte): Boolean;

{ The standard reason phrase of Code. False for codes without one. P points
  to constant data in the program (no allocation, valid forever). }
function CanonicalReason(Code: Integer; out P: PAnsiChar; out Len: SizeInt): Boolean;
{ Same, as a string constant ('' if none). }
function CanonicalReasonStr(Code: Integer): RawByteString;

implementation

constructor EInvalidReasonPhrase.CreateBadByte(ABadByte: Byte);
begin
  inherited CreateFmt('Invalid byte in reason phrase: %d', [ABadByte]);
  FBadByte := ABadByte;
end;

function IsValidReasonByte(B: Byte): Boolean; inline;
begin
  Result := (B = 9) or (B = 32) or ((B >= $21) and (B <= $7E)) or (B >= $80);
end;

function FindInvalidReasonByte(P: PByte; Len: SizeInt; out BadByte: Byte): Boolean;
var
  I: SizeInt;
begin
  BadByte := 0;
  for I := 0 to Len - 1 do
    if not IsValidReasonByte(P[I]) then
    begin
      BadByte := P[I];
      Exit(True);
    end;
  Result := False;
end;

class function TReasonPhrase.TryFrom(P: PByte; Len: SizeInt; out R: TReasonPhrase; out BadByte: Byte): Boolean;
begin
  R.FBytes := '';
  if FindInvalidReasonByte(P, Len, BadByte) then
    Exit(False);
  SetLength(R.FBytes, Len);
  if Len > 0 then
    Move(P^, Pointer(R.FBytes)^, Len);
  Result := True;
end;

class function TReasonPhrase.TryFrom(const S: RawByteString; out R: TReasonPhrase; out BadByte: Byte): Boolean;
begin
  Result := TryFrom(PByte(Pointer(S)), Length(S), R, BadByte);
end;

class function TReasonPhrase.TryFrom(const S: RawByteString; out R: TReasonPhrase): Boolean;
var
  B: Byte;
begin
  Result := TryFrom(PByte(Pointer(S)), Length(S), R, B);
end;

class function TReasonPhrase.FromStatic(const S: RawByteString): TReasonPhrase;
var
  B: Byte;
begin
  if FindInvalidReasonByte(PByte(Pointer(S)), Length(S), B) then
    raise EInvalidReasonPhrase.CreateBadByte(B);
  Result.FBytes := S;
end;

class function TReasonPhrase.FromBytesUnchecked(P: PByte; Len: SizeInt): TReasonPhrase;
begin
  Result.FBytes := '';
  SetLength(Result.FBytes, Len);
  if Len > 0 then
    Move(P^, Pointer(Result.FBytes)^, Len);
end;

function TReasonPhrase.AsBytes: RawByteString;
begin
  Result := FBytes;
end;

function TReasonPhrase.Data: PByte;
begin
  Result := PByte(Pointer(FBytes));
end;

function TReasonPhrase.Len: SizeInt;
begin
  Result := Length(FBytes);
end;

function CanonicalReasonStr(Code: Integer): RawByteString;
begin
  case Code of
    100: Result := 'Continue';
    101: Result := 'Switching Protocols';
    102: Result := 'Processing';
    103: Result := 'Early Hints';
    200: Result := 'OK';
    201: Result := 'Created';
    202: Result := 'Accepted';
    203: Result := 'Non Authoritative Information';
    204: Result := 'No Content';
    205: Result := 'Reset Content';
    206: Result := 'Partial Content';
    207: Result := 'Multi-Status';
    208: Result := 'Already Reported';
    226: Result := 'IM Used';
    300: Result := 'Multiple Choices';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    303: Result := 'See Other';
    304: Result := 'Not Modified';
    305: Result := 'Use Proxy';
    307: Result := 'Temporary Redirect';
    308: Result := 'Permanent Redirect';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    402: Result := 'Payment Required';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    406: Result := 'Not Acceptable';
    407: Result := 'Proxy Authentication Required';
    408: Result := 'Request Timeout';
    409: Result := 'Conflict';
    410: Result := 'Gone';
    411: Result := 'Length Required';
    412: Result := 'Precondition Failed';
    413: Result := 'Payload Too Large';
    414: Result := 'URI Too Long';
    415: Result := 'Unsupported Media Type';
    416: Result := 'Range Not Satisfiable';
    417: Result := 'Expectation Failed';
    418: Result := 'I''m a teapot';
    421: Result := 'Misdirected Request';
    422: Result := 'Unprocessable Entity';
    423: Result := 'Locked';
    424: Result := 'Failed Dependency';
    425: Result := 'Too Early';
    426: Result := 'Upgrade Required';
    428: Result := 'Precondition Required';
    429: Result := 'Too Many Requests';
    431: Result := 'Request Header Fields Too Large';
    451: Result := 'Unavailable For Legal Reasons';
    500: Result := 'Internal Server Error';
    501: Result := 'Not Implemented';
    502: Result := 'Bad Gateway';
    503: Result := 'Service Unavailable';
    504: Result := 'Gateway Timeout';
    505: Result := 'HTTP Version Not Supported';
    506: Result := 'Variant Also Negotiates';
    507: Result := 'Insufficient Storage';
    508: Result := 'Loop Detected';
    510: Result := 'Not Extended';
    511: Result := 'Network Authentication Required';
  else
    Result := '';
  end;
end;

function CanonicalReason(Code: Integer; out P: PAnsiChar; out Len: SizeInt): Boolean;
var
  S: RawByteString;
begin
  { Assigning a string literal does not allocate: literals are constants
    with refcount -1, and the pointer below stays valid after S goes out of
    scope because it points into the program's constant data. }
  S := CanonicalReasonStr(Code);
  Len := Length(S);
  P := PAnsiChar(Pointer(S));
  Result := Len > 0;
end;

end.
