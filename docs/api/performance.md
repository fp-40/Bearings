# 13. Performance rules

The measured speed (0.85 to 0.98 of hyper on the plaintext benchmark,
`bench/run_gate.sh`; an idle keep-alive connection at about 1.3 KB)
depends on the *inline path* allocating nothing and touching no atomic
instruction per request. The library keeps its side of this: the exchange
is reused per connection, header lists are cleared and reused, the body
channel is a record inside the exchange, posting a message to a loop
allocates nothing. A program that wants the same speed for its inline
answers must keep its side:

- Return one shared, stateless call object from `THttpService.Call`
  (or a pooled one, given back in `Drop`). Creating a call object per
  request is one allocation per request.
- Use `BodyStatic` for constant bodies and `BodyString` for strings that
  already exist; `BodyCopy` and `BodyHeap` allocate. Building a
  `RawByteString` per request (concatenation, `IntToStr`) allocates.
- Add constant headers with `AddTrusted` and constants (`bench/plaintext.pas`
  does this). `Add` validates the bytes (a few comparisons per byte) and
  copies them into the list's arena; the arena is reused per connection,
  so there is no heap allocation once the list is warm. The
  `RawByteString` overloads cost nothing extra with string constants; a
  string built per request does.
- Do not `Share` or `Offload` on the inline path: both touch atomics and
  the offloaded request costs a thread hand-off (measured at about 2.3 to
  2.7 us per request on the benchmark machine, `bench/run_offload.sh`).
- Do not read `Ex.Headers` with `GetValue` (it allocates a string); use
  `Header(Name, out V)` or `Get`, which return slices.
- Managed locals (strings, dynamic arrays, interfaces) in a routine make
  the compiler add an implicit exception frame to it (`fpc_pushexceptaddr`
  / `fpc_setjmp` calls on entry and exit), which costs on every call. The
  **hot-asm check**, `tools/check-hot-asm.sh`, compiles the library with
  `-al` (assembler listings) in the production (`-O3`) and test (`-O2 -Sa`)
  configurations and fails when any routine of the request path got such a
  frame (`tools/hot-asm.py` reads the listings; the list of routines is in
  the script). It checks the library's routines only; a program can apply
  the same rule to its own `Poll` by keeping managed types out of it
  (`bench/plaintext.pas`'s `Answer` has none).

On the worker path these rules are relaxed: a worker request already costs
a thread hand-off, and `ReadAll`, `BodyString` and ordinary string code
are the normal way to write a handler there.
