{ bearings.http.error - error values of the HTTP layer, poll results and
  connection outcomes.

  THyperError says why reading or writing an HTTP message failed: the
  request head could not be parsed, the application failed, the client
  closed the connection in the middle of a request, a socket call failed, a
  timeout expired, and so on. Kind says what failed; Cause adds what else
  is known (an errno, a body decoder error, a fixed text). It is a plain
  record without managed fields, so copying it is a memory copy and a
  routine with a THyperError local gets no implicit exception frame.

  Kinds (THyperErrorKind):
    hekParse              the request head is malformed or too large (Parse
                          holds the parser's reason; h1peVersionH2 means the
                          client sent the HTTP/2 connection preface).
    hekUser               the application did something wrong (User holds
                          what): its service or body source failed, it set
                          a Content-Length or Transfer-Encoding header that
                          is invalid or contradicts the response, it
                          answered with a 1xx status, it took an upgrade
                          the wrong way.
    hekBodyWriteAborted   the application's response body ended before the
                          length it declared (NotEofRemaining bytes were
                          missing). It counts as a user error: IsUser is
                          True for it, and OutcomeOf tests IsUser first.
    hekIncompleteMessage  the connection closed before a message was
                          complete.
    hekIo                 a socket read or write failed (Cause = ecErrno).
    hekHeaderTimeout      the client did not send a complete request head in
                          time.
    hekBody, hekBodyWrite reading the request body or writing the response
                          body failed.
    hekShutdown           shutting down the write side of the socket failed.
    hekCanceled, hekChannelClosed, hekUnexpectedMessage   kept for
                          completeness; the HTTP/1 server code does not
                          create them.

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

  THyperErrorKind = (hekNone, hekParse, hekUser, hekIncompleteMessage, hekUnexpectedMessage,
    hekCanceled, hekChannelClosed, hekIo, hekHeaderTimeout, hekBody, hekBodyWrite,
    hekBodyWriteAborted, hekShutdown);
  THyperUserKind = (hukNone, hukBody, hukService, hukUnsupportedStatusCode, hukNoUpgrade,
    hukManualUpgrade, hukHeader);
  TErrorCause = (ecNone, ecErrno, ecDecode, ecStatic, ecConnText, ecInner);

  { Plain data: no managed fields, no owned objects (see the unit header). }
  THyperError = record
    Kind: THyperErrorKind;
    Parse: TH1ParseError;            { hekParse (h1peVersionH2 for the h2 preface) }
    User: THyperUserKind;            { hekUser }
    Cause: TErrorCause;
    Errno: cint;                     { ecErrno: the errno }
    Decode: TDecodeError;            { ecDecode: the body decoder's error }
    StaticMsg: PAnsiChar;            { ecStatic: 'connection error', ... }
    InnerKind: THyperErrorKind;      { ecInner: the wrapped kind (one level only) }
    NotEofRemaining: QWord;          { hekBodyWriteAborted }
    { ecConnText: the text is in the owning connection's FErrorText (cold RawByteString field) }
    function IsParse: Boolean;  function IsParseTooLarge: Boolean;  function IsParseVersionH2: Boolean;
    function IsUser: Boolean;  function IsCanceled: Boolean;  function IsClosed: Boolean;
    function IsIncompleteMessage: Boolean;  function IsBodyWriteAborted: Boolean;
    function IsShutdown: Boolean;  function IsTimeout: Boolean;   { hekHeaderTimeout only }
    function HasIoSource: Boolean;                                { the cause is an errno or a decoder error }
  end;

  { A program error inside the HTTP/1 code, for example a response version the encoder cannot
    write (HTTP/0.9 or HTTP/3.0) or a full write queue. The loop catches it and aborts the
    connection task (see bearings.rt.loop). }
  EH1Panic = class(Exception);

  { How a connection ended (conformance/SPEC.md 7.2). }
  TConnOutcome = (coOk, coTimeout, coParseTooLarge, coParseVersionH2, coParse, coIncomplete,
    coUser, coCanceled, coClosed, coBodyWriteAborted, coShutdown, coIo, coOther);

function NewParse(E: TH1ParseError): THyperError;      function NewIncomplete: THyperError;
function NewTooLarge: THyperError;                      function NewVersionH2: THyperError;
function NewIo(Errno: cint): THyperError;               function NewHeaderTimeout: THyperError;
function NewBodyDecode(E: TDecodeError): THyperError;   function NewBodyIo(Errno: cint): THyperError;
function NewBodyStatic(Msg: PAnsiChar): THyperError;    function NewBodyWrite(Errno: cint): THyperError;
function NewBodyWriteAborted(Remaining: QWord): THyperError;
function NewShutdown(Errno: cint): THyperError;         function NewUserService: THyperError;
function NewUserBody: THyperError;                      function NewUserHeader: THyperError;
function NewUserUnsupportedStatusCode: THyperError;     function NewUserManualUpgrade: THyperError;
function NewClosed: THyperError;
{ The error as text for logs: the kind's description, then ": " and the cause. Cold path (it
  builds strings). ConnText: the connection's FErrorText, used for an ecConnText cause. }
function ErrorDescription(const E: THyperError; const ConnText: RawByteString): string;

{ coOk if R = prOk; else the class of the first predicate that is True, in the order of
  conformance/SPEC.md 7.2. }
function OutcomeOf(R: TPollResult; const E: THyperError): TConnOutcome;

implementation

uses
  bearings.rt.sys;

{ ---- predicates ---- }

function THyperError.IsParse: Boolean;
begin
  Result := Kind = hekParse;
end;

function THyperError.IsParseTooLarge: Boolean;
begin
  { the head, or the request-target alone, is longer than the limit }
  Result := (Kind = hekParse) and ((Parse = h1peTooLarge) or (Parse = h1peUriTooLong));
end;

function THyperError.IsParseVersionH2: Boolean;
begin
  Result := (Kind = hekParse) and (Parse = h1peVersionH2);
end;

function THyperError.IsUser: Boolean;
begin
  { hekBodyWriteAborted is an application error too }
  Result := (Kind = hekUser) or (Kind = hekBodyWriteAborted);
end;

function THyperError.IsCanceled: Boolean;
begin
  Result := Kind = hekCanceled;
end;

function THyperError.IsClosed: Boolean;
begin
  Result := Kind = hekChannelClosed;
end;

function THyperError.IsIncompleteMessage: Boolean;
begin
  Result := Kind = hekIncompleteMessage;
end;

function THyperError.IsBodyWriteAborted: Boolean;
begin
  Result := Kind = hekBodyWriteAborted;
end;

function THyperError.IsShutdown: Boolean;
begin
  Result := Kind = hekShutdown;
end;

function THyperError.IsTimeout: Boolean;
begin
  { only the header timeout. An errno ETIMEDOUT (for example the body
    read timeout, see TExchange.BodyErrorIsTimeout) is an I/O cause and
    is not classed as a timeout here. }
  Result := Kind = hekHeaderTimeout;
end;

function THyperError.HasIoSource: Boolean;
begin
  { the cause is an I/O error: an errno from the OS (NewIo, NewBodyIo,
    NewBodyWrite, NewShutdown) or an error of the body decoder }
  Result := (Cause = ecErrno) or (Cause = ecDecode);
end;

{ ---- constructors ---- }

function NewParse(E: TH1ParseError): THyperError;
begin
  Result := Default(THyperError);
  Result.Kind := hekParse;
  Result.Parse := E;
end;

function NewIncomplete: THyperError;
begin
  Result := Default(THyperError);
  Result.Kind := hekIncompleteMessage;
end;

function NewTooLarge: THyperError;
begin
  Result := NewParse(h1peTooLarge);
end;

function NewVersionH2: THyperError;
begin
  Result := NewParse(h1peVersionH2);
end;

function NewIo(Errno: cint): THyperError;
begin
  Result := Default(THyperError);
  Result.Kind := hekIo;
  Result.Cause := ecErrno;
  Result.Errno := Errno;
end;

function NewHeaderTimeout: THyperError;
begin
  Result := Default(THyperError);
  Result.Kind := hekHeaderTimeout;
end;

function NewBodyDecode(E: TDecodeError): THyperError;
begin
  { the request body decoder found an error }
  Result := Default(THyperError);
  Result.Kind := hekBody;
  Result.Cause := ecDecode;
  Result.Decode := E;
end;

function NewBodyIo(Errno: cint): THyperError;
begin
  { a socket read of the request body failed }
  Result := Default(THyperError);
  Result.Kind := hekBody;
  Result.Cause := ecErrno;
  Result.Errno := Errno;
end;

function NewBodyStatic(Msg: PAnsiChar): THyperError;
begin
  { a body error with a fixed text; the dispatcher sends 'connection error'
    to a handler still reading the body when the connection fails }
  Result := Default(THyperError);
  Result.Kind := hekBody;
  Result.Cause := ecStatic;
  Result.StaticMsg := Msg;
end;

function NewBodyWrite(Errno: cint): THyperError;
begin
  { a socket write of the response body failed }
  Result := Default(THyperError);
  Result.Kind := hekBodyWrite;
  Result.Cause := ecErrno;
  Result.Errno := Errno;
end;

function NewBodyWriteAborted(Remaining: QWord): THyperError;
begin
  { the response body ended Remaining bytes before its declared length }
  Result := Default(THyperError);
  Result.Kind := hekBodyWriteAborted;
  Result.NotEofRemaining := Remaining;
end;

function NewShutdown(Errno: cint): THyperError;
begin
  { shutdown(2) of the socket's write side failed }
  Result := Default(THyperError);
  Result.Kind := hekShutdown;
  Result.Cause := ecErrno;
  Result.Errno := Errno;
end;

function NewUserService: THyperError;
begin
  { the application's service failed; the text is the connection's FErrorText }
  Result := Default(THyperError);
  Result.Kind := hekUser;
  Result.User := hukService;
  Result.Cause := ecConnText;
end;

function NewUserBody: THyperError;
begin
  { the application's response body source failed; the text is the
    connection's FErrorText }
  Result := Default(THyperError);
  Result.Kind := hekUser;
  Result.User := hukBody;
  Result.Cause := ecConnText;
end;

function NewUserHeader: THyperError;
begin
  { the application set an invalid or contradictory Content-Length or
    Transfer-Encoding response header }
  Result := Default(THyperError);
  Result.Kind := hekUser;
  Result.User := hukHeader;
end;

function NewUserUnsupportedStatusCode: THyperError;
begin
  Result := Default(THyperError);
  Result.Kind := hekUser;
  Result.User := hukUnsupportedStatusCode;
end;

function NewUserManualUpgrade: THyperError;
begin
  Result := Default(THyperError);
  Result.Kind := hekUser;
  Result.User := hukManualUpgrade;
end;

function NewClosed: THyperError;
begin
  Result := Default(THyperError);
  Result.Kind := hekChannelClosed;
end;

{ ---- text for logs ---- }

function KindDescription(const E: THyperError): string;
begin
  case E.Kind of
    hekNone: Result := '';
    hekParse: Result := H1ParseErrorDescription(E.Parse);
    hekUser:
      case E.User of
        hukBody: Result := 'error from user''s Body stream';
        hukService: Result := 'error from user''s Service';
        hukUnsupportedStatusCode: Result := 'response has 1xx status code, not supported by server';
        hukNoUpgrade: Result := 'no upgrade available';
        hukManualUpgrade: Result := 'upgrade expected but low level API in use';
        hukHeader: Result := 'user sent unexpected header';
      else
        Result := '';
      end;
    hekIncompleteMessage: Result := 'connection closed before message completed';
    hekUnexpectedMessage: Result := 'received unexpected message from connection';
    hekCanceled: Result := 'operation was canceled';
    hekChannelClosed: Result := 'channel closed';
    hekIo: Result := 'connection error';
    hekHeaderTimeout: Result := 'read header from client timeout';
    hekBody: Result := 'error reading a body from connection';
    hekBodyWrite: Result := 'error writing a body to connection';
    hekBodyWriteAborted: Result := 'user body write aborted';
    hekShutdown: Result := 'error shutting down connection';
  end;
end;

{ An errno as text: "<strerror> (os error N)". }
function OsErrorText(Errno: cint): string;
begin
  Result := SysErrorMessage(Errno) + ' (os error ' + IntToStr(Errno) + ')';
end;

function ErrorDescription(const E: THyperError; const ConnText: RawByteString): string;
var
  Inner: THyperError;
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
        Inner := Default(THyperError);
        Inner.Kind := E.InnerKind;
        Result := Result + ': ' + KindDescription(Inner);
      end;
  end;
  if E.Kind = hekBodyWriteAborted then
    Result := Result + ': early end, expected ' + IntToStr(E.NotEofRemaining) + ' more bytes';
end;

function OutcomeOf(R: TPollResult; const E: THyperError): TConnOutcome;
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
  else if E.IsCanceled then
    Result := coCanceled
  else if E.IsClosed then
    Result := coClosed
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
