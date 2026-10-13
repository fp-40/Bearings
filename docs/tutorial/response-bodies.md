# Response bodies

## A body of known length

`Respond(Body)` sends the head and a body with a `Content-Length`. The body
is a `TBodyData` record built by one of the constructors of unit
`bearings.rt.buf`:

| Constructor | Memory | Released how |
| --- | --- | --- |
| `BodyEmpty` | none | nothing to do |
| `BodyStatic(P, Len)` | memory that outlives the write (a constant, a global) | nothing to do |
| `BodyString(S)` | the bytes of a `RawByteString`, no copy | one reference held until written |
| `BodyHeap(P, Len)` | memory from `GetMem` | `FreeMem` after the write |
| `BodyCopy(Ex, P, Len)` | a copy, in a pooled block | the block goes back after the write |
| `BodyFile(Fd, Offset, Len, CloseAfter)` | a range of an open file | sent with `sendfile`; `Fd` closed after the last byte when `CloseAfter` |

`RespondText` is `Respond(BodyString(Text))` with the status and the
`Content-Type` set first.

## A file

`BodyFile` makes the kernel copy the file to the socket. The handler
opens the file, reads its size and hands the descriptor over; the server
owns it from then on (from `examples/stream.pas`):

```pascal
procedure TStreamHandler.ServeFile(Ex: TExchange);
var
  Fd: cint;
  St: Stat;
begin
  Fd := FpOpen(FileName, O_RDONLY or O_CLOEXEC);
  if Fd < 0 then
  begin
    Ex.RespondText(404, 'cannot open ' + FileName + #10);
    Exit;
  end;
  if FpFStat(Fd, St) <> 0 then
  begin
    FpClose(Fd);
    Ex.RespondText(500, 'fstat failed'#10);
    Exit;
  end;
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  Ex.Respond(BodyFile(Fd, 0, St.st_size, True));
end;
```

`open` may block on a slow disk, which is why this handler runs on a
worker.

## A body of unknown length

When the length is not known when the head goes out, `BeginStream` is the
terminal call. The head is sent at once with `Transfer-Encoding: chunked`,
and then the handler writes pieces with `Write` and ends the body with
`Finish`. Ten lines, one per 100 ms, from a worker (also from
`examples/stream.pas`):

```pascal
procedure TStreamHandler.ServeLines(Ex: TExchange);
var
  I: Integer;
  Line: RawByteString;
begin
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  if not Ex.BeginStream then                  { the head goes out now, chunked }
    Exit;                                     { canceled or already answered }
  for I := 1 to 10 do
  begin
    Sleep(100);                               { a worker may block }
    Line := 'line ' + IntToStr(I) + #10;
    if Ex.Write(PByte(Line), Length(Line)) = wrCanceled then
    begin
      WriteLn(StdErr, 'stream: client gone after ', I - 1, ' lines');
      Exit;                                   { the exchange ends the body itself }
    end;
  end;
  Ex.Finish;                                  { the last chunk; no trailers }
end;
```

`Write` copies the bytes into a bounded queue. On a worker it parks while
about `HighWater` bytes (64 KiB by default) are queued and the client has
not read them: a slow client slows the producer down. On the loop thread
it cannot park and returns `wrWouldBlock` instead. `wrCanceled` means the
client went away; the producer stops, and the exchange cleans up.

```sh
$ build/examples/stream 8080 /etc/os-release &
$ curl -N http://127.0.0.1:8080/          # one line per 100 ms
$ curl -i http://127.0.0.1:8080/file      # the file, with its Content-Length
```

A streaming producer that lives on the loop thread is better written as a
`TBodySource`, a class the connection polls for the next frame only while
the socket can take more (`docs/api.md`, section 5).
