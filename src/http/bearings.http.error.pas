{ bearings.http.error - error values of the HTTP layer, poll results and
  connection outcomes.

  TH1Error says why reading or writing an HTTP message failed: the
  request head could not be parsed, the application failed, the client
  closed the connection in the middle of a request, a socket call failed, a
  timeout expired, and so on. Kind says what failed; Cause adds what else
  is known (an errno, a body decoder error, a fixed text). It is a plain
  record without managed fields, so copying it is a memory copy and a
  routine with a TH1Error local gets no implicit exception frame.

  Kinds (TH1ErrorKind):
    h1eParse              the request head is malformed or too large (Parse
                          holds the parser's reason; h1peVersionH2 means the
                          client sent the HTTP/2 connection preface).
    h1eUser               the application did something wrong (User holds
                          what): its service or body source failed, it set
                          a Content-Length or Transfer-Encoding header that
                          is invalid or contradicts the response, it
                          answered with a 1xx status, it took an upgrade
                          the wrong way.
    h1eBodyWriteAborted   the application's response body ended before the
                          length it declared (NotEofRemaining bytes were
                          missing). It counts as a user error: IsUser is
                          True for it, and OutcomeOf tests IsUser first.
    h1eIncompleteMessage  the connection closed before a message was
                          complete.
    h1eIo                 a socket read or write failed (Cause = ecErrno).
    h1eHeaderTimeout      the client did not send a complete request head in
                          time.
    h1eBody, h1eBodyWrite reading the request body or writing the response
                          body failed.
    h1eShutdown           shutting down the write side of the socket failed.

  Causes (TErrorCause): ecErrno an errno from a system call; ecDecode an
  error found by the request body decoder (bearings.http1.decode: a bad chunk
  size, the connection closed in the middle of the body, ...); ecStatic a
  fixed text (StaticMsg); ecInner one wrapped error kind (InnerKind);
  ecConnText the text kept by the connection in its FErrorText field (for
  example the message the application passed to TExchange.Fail).

  TPollResult and TPollOpt are the results of the connection code's
  non-blocking poll routines. prPending / poPending mean "no progress is
  possible now"; the task runs again when the socket or the application is
  ready. TPollOpt adds poNone, "nothing more" (for example the end of a
  body).

  ErrorDescription builds the text written to logs. OutcomeOf maps the
  result of a connection to the class reported when it closes
  (TConnOutcome, conformance/SPEC.md 7.2). TConnOutcome and OutcomeOf are
  declared here and not in bearings.server because the dispatcher
  (bearings.http1.dispatch) reports the outcome and bearings.server uses the
  dispatcher: declaring them in bearings.server would make the unit references
  circular.

  Threading: plain values and pure functions; any thread. }
unit bearings.http.error;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, ctypes, bearings.http1.role, bearings.http1.decode;

type
  TPollResult = (prOk, prErr, prPending);        { done, failed (see Err), or not yet }
  TPollOpt = (poSome, poErr, poNone, poPending);  { an item, failed, no more items, or not yet }

  TH1ErrorKind = (h1eNone, h1eParse, h1eUser, h1eIncompleteMessage, h1eIo, h1eHeaderTimeout,
    h1eBody, h1eBodyWrite, h1eBodyWriteAborted, h1eShutdown);
  TH1UserKind = (h1uNone, h1uBody, h1uService, h1uUnsupportedStatusCode, h1uManualUpgrade,
    h1uHeader);
  TErrorCause = (ecNone, ecErrno, ecDecode, ecStatic, ecConnText, ecInner);

  { Plain data: no managed fields, no owned objects (see the unit header). }
  TH1Error = record
    Kind: TH1ErrorKind;
    Parse: TH1ParseError;            { h1eParse (h1peVersionH2 for the h2 preface) }
    User: TH1UserKind;            { h1eUser }
    Cause: TErrorCause;
    Errno: cint;                     { ecErrno: the errno }
    Decode: TDecodeError;            { ecDecode: the body decoder's error }
    StaticMsg: PAnsiChar;            { ecStatic: 'connection error', ... }
    InnerKind: TH1ErrorKind;      { ecInner: the wrapped kind (one level only) }
    NotEofRemaining: QWord;          { h1eBodyWriteAborted }
    { ecConnText: the text is in the owning connection's FErrorText (cold RawByteString field) }
    function IsParse: Boolean;  function IsParseTooLarge: Boolean;  function IsParseVersionH2: Boolean;
    function IsUser: Boolean;
    function IsIncompleteMessage: Boolean;  function IsBodyWriteAborted: Boolean;
    function IsShutdown: Boolean;  function IsTimeout: Boolean;   { h1eHeaderTimeout only }
    function HasIoSource: Boolean;                                { the cause is an errno or a decoder error }
  end;

  { A program error inside the HTTP/1 code, for example a response version the encoder cannot
    write (HTTP/0.9 or HTTP/3.0) or a full write queue. The loop catches it and aborts the
    connection task (see bearings.rt.loop). }
  EH1Panic = class(Exception);

  { How a connection ended (conformance/SPEC.md 7.2). }
  TConnOutcome = (coOk, coTimeout, coParseTooLarge, coParseVersionH2, coParse, coIncomplete,
    coUser, coBodyWriteAborted, coShutdown, coIo, coOther);

function NewParse(E: TH1ParseError): TH1Error;      function NewIncomplete: TH1Error;
function NewTooLarge: TH1Error;                      function NewVersionH2: TH1Error;
function NewIo(Errno: cint): TH1Error;               function NewHeaderTimeout: TH1Error;
function NewBodyDecode(E: TDecodeError): TH1Error;   function NewBodyIo(Errno: cint): TH1Error;
function NewBodyStatic(Msg: PAnsiChar): TH1Error;    function NewBodyWrite(Errno: cint): TH1Error;
function NewBodyWriteAborted(Remaining: QWord): TH1Error;
function NewShutdown(Errno: cint): TH1Error;         function NewUserService: TH1Error;
function NewUserBody: TH1Error;                      function NewUserHeader: TH1Error;
function NewUserUnsupportedStatusCode: TH1Error;     function NewUserManualUpgrade: TH1Error;
{ The error as text for logs: the kind's description, then ": " and the cause. Cold path (it
  builds strings). ConnText: the connection's FErrorText, used for an ecConnText cause. }
function ErrorDescription(const E: TH1Error; const ConnText: RawByteString): string;

{ coOk if R = prOk; else the class of the first predicate that is True, in the order of
  conformance/SPEC.md 7.2. }
function OutcomeOf(R: TPollResult; const E: TH1Error): TConnOutcome;

implementation

uses
  bearings.rt.sys;

{ ---- predicates ---- }

function TH1Error.IsParse: Boolean;
begin
  Result := Kind = h1eParse;
end;

function TH1Error.IsParseTooLarge: Boolean;
begin
  { the head, or the request-target alone, is longer than the limit }
  Result := (Kind = h1eParse) and ((Parse = h1peTooLarge) or (Parse = h1peUriTooLong));
end;

function TH1Error.IsParseVersionH2: Boolean;
begin
  Result := (Kind = h1eParse) and (Parse = h1peVersionH2);
end;

function TH1Error.IsUser: Boolean;
begin
  { h1eBodyWriteAborted is an application error too }
  Result := (Kind = h1eUser) or (Kind = h1eBodyWriteAborted);
end;

function TH1Error.IsIncompleteMessage: Boolean;
begin
  Result := Kind = h1eIncompleteMessage;
end;

function TH1Error.IsBodyWriteAborted: Boolean;
begin
  Result := Kind = h1eBodyWriteAborted;
end;

function TH1Error.IsShutdown: Boolean;
begin
  Result := Kind = h1eShutdown;
end;

function TH1Error.IsTimeout: Boolean;
begin
  { only the header timeout. An errno ETIMEDOUT (for example the body
    read timeout, see TExchange.BodyErrorIsTimeout) is an I/O cause and
    is not classed as a timeout here. }
  Result := Kind = h1eHeaderTimeout;
end;

function TH1Error.HasIoSource: Boolean;
begin
  { the cause is an I/O error: an errno from the OS (NewIo, NewBodyIo,
    NewBodyWrite, NewShutdown) or an error of the body decoder }
  Result := (Cause = ecErrno) or (Cause = ecDecode);
end;

{ ---- constructors ---- }

function NewParse(E: TH1ParseError): TH1Error;
begin
  Result := Default(TH1Error);
  Result.Kind := h1eParse;
  Result.Parse := E;
end;

function NewIncomplete: TH1Error;
begin
  Result := Default(TH1Error);
  Result.Kind := h1eIncompleteMessage;
end;

function NewTooLarge: TH1Error;
begin
  Result := NewParse(h1peTooLarge);
end;

function NewVersionH2: TH1Error;
begin
  Result := NewParse(h1peVersionH2);
end;

function NewIo(Errno: cint): TH1Error;
begin
  Result := Default(TH1Error);
  Result.Kind := h1eIo;
  Result.Cause := ecErrno;
  Result.Errno := Errno;
end;

function NewHeaderTimeout: TH1Error;
begin
  Result := Default(TH1Error);
  Result.Kind := h1eHeaderTimeout;
end;

function NewBodyDecode(E: TDecodeError): TH1Error;
begin
  { the request body decoder found an error }
  Result := Default(TH1Error);
  Result.Kind := h1eBody;
  Result.Cause := ecDecode;
  Result.Decode := E;
end;

function NewBodyIo(Errno: cint): TH1Error;
begin
  { a socket read of the request body failed }
  Result := Default(TH1Error);
  Result.Kind := h1eBody;
  Result.Cause := ecErrno;
  Result.Errno := Errno;
end;

function NewBodyStatic(Msg: PAnsiChar): TH1Error;
begin
  { a body error with a fixed text; the dispatcher sends 'connection error'
    to a handler still reading the body when the connection fails }
  Result := Default(TH1Error);
  Result.Kind := h1eBody;
  Result.Cause := ecStatic;
  Result.StaticMsg := Msg;
end;

function NewBodyWrite(Errno: cint): TH1Error;
begin
  { a socket write of the response body failed }
  Result := Default(TH1Error);
  Result.Kind := h1eBodyWrite;
  Result.Cause := ecErrno;
  Result.Errno := Errno;
end;

function NewBodyWriteAborted(Remaining: QWord): TH1Error;
begin
  { the response body ended Remaining bytes before its declared length }
  Result := Default(TH1Error);
  Result.Kind := h1eBodyWriteAborted;
  Result.NotEofRemaining := Remaining;
end;

function NewShutdown(Errno: cint): TH1Error;
begin
  { shutdown(2) of the socket's write side failed }
  Result := Default(TH1Error);
  Result.Kind := h1eShutdown;
  Result.Cause := ecErrno;
  Result.Errno := Errno;
end;

function NewUserService: TH1Error;
begin
  { the application's service failed; the text is the connection's FErrorText }
  Result := Default(TH1Error);
  Result.Kind := h1eUser;
  Result.User := h1uService;
  Result.Cause := ecConnText;
end;

function NewUserBody: TH1Error;
begin
  { the application's response body source failed; the text is the
    connection's FErrorText }
  Result := Default(TH1Error);
  Result.Kind := h1eUser;
  Result.User := h1uBody;
  Result.Cause := ecConnText;
end;

function NewUserHeader: TH1Error;
begin
  { the application set an invalid or contradictory Content-Length or
    Transfer-Encoding response header }
  Result := Default(TH1Error);
  Result.Kind := h1eUser;
  Result.User := h1uHeader;
end;

function NewUserUnsupportedStatusCode: TH1Error;
begin
  Result := Default(TH1Error);
  Result.Kind := h1eUser;
  Result.User := h1uUnsupportedStatusCode;
end;

function NewUserManualUpgrade: TH1Error;
begin
  Result := Default(TH1Error);
  Result.Kind := h1eUser;
  Result.User := h1uManualUpgrade;
end;

{ ---- text for logs ---- }

function KindDescription(const E: TH1Error): string;
begin
  case E.Kind of
    h1eNone: Result := '';
    h1eParse: Result := H1ParseErrorDescription(E.Parse);
    h1eUser:
      case E.User of
        h1uBody: Result := 'response body failed';
        h1uService: Result := 'handler failed';
        h1uUnsupportedStatusCode: Result := 'handler returned a 1xx status';
        h1uManualUpgrade: Result := 'upgrade requested on a cmPlain connection';
        h1uHeader: Result := 'invalid framing headers in the response';
      else
        Result := '';
      end;
    h1eIncompleteMessage: Result := 'connection closed in the middle of a request';
    h1eIo: Result := 'connection error';
    h1eHeaderTimeout: Result := 'timeout waiting for the request head';
    h1eBody: Result := 'request body error';
    h1eBodyWrite: Result := 'response body write error';
    h1eBodyWriteAborted: Result := 'response body ended early';
    h1eShutdown: Result := 'error shutting down connection';
  end;
end;

{ An errno as text: "<strerror> (os error N)". }
function OsErrorText(Errno: cint): string;
begin
  Result := SysErrorMessage(Errno) + ' (os error ' + IntToStr(Errno) + ')';
end;

function ErrorDescription(const E: TH1Error; const ConnText: RawByteString): string;
var
  Inner: TH1Error;
begin
  { the kind's text, then ": " and the cause's text (the format the
    conformance harness compares) }
  Result := KindDescription(E);
  case E.Cause of
    ecErrno: Result := Result + ': ' + OsErrorText(E.Errno);
    ecDecode: Result := Result + ': ' + DecodeErrorMessage(E.Decode);
    ecStatic:
      if E.StaticMsg <> nil then
        Result := Result + ': ' + string(E.StaticMsg);
    ecConnText:
      if ConnText <> '' then
        Result := Result + ': ' + string(ConnText);
    ecInner:
      begin
        Inner := Default(TH1Error);
        Inner.Kind := E.InnerKind;
        Result := Result + ': ' + KindDescription(Inner);
      end;
  end;
  if E.Kind = h1eBodyWriteAborted then
    Result := Result + ': ' + IntToStr(E.NotEofRemaining) + ' bytes missing';
end;

function OutcomeOf(R: TPollResult; const E: TH1Error): TConnOutcome;
begin
  { the order of the tests is the order of conformance/SPEC.md 7.2 }
  if R = prOk then
    Exit(coOk);
  if E.IsTimeout then
    Result := coTimeout
  else if E.IsParseTooLarge then
    Result := coParseTooLarge
  else if E.IsParseVersionH2 then
    Result := coParseVersionH2
  else if E.IsParse then
    Result := coParse
  else if E.IsIncompleteMessage then
    Result := coIncomplete
  else if E.IsUser then
    Result := coUser
  else if E.IsBodyWriteAborted then
    Result := coBodyWriteAborted
  else if E.IsShutdown then
    Result := coShutdown
  else if E.HasIoSource then
    Result := coIo
  else
    Result := coOther;
end;

end.
