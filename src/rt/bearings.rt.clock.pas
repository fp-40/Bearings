{ bearings.rt.clock - fast access to the monotonic and wall clocks.

  The server reads the clock very often: every event-loop iteration samples
  the monotonic clock right after epoll_wait returns, to advance the timers
  (bearings.rt.timer) and to measure timeouts. This unit calls libc's
  clock_gettime, which runs in the vDSO (code the kernel maps into every
  process, so no system call is made: about 11 ns). FPC's own clock_gettime
  makes a real system call (about 89 ns).

  MonoNowNs reads CLOCK_MONOTONIC: it never jumps backwards when the
  administrator or NTP changes the date, so it is the clock for deadlines and
  intervals. RealNowUs reads CLOCK_REALTIME (the calendar date) and is used
  only to build the HTTP Date header.

  Threading: the routines have no state and may be called from any thread. }
unit bearings.rt.clock;

{$mode objfpc}{$H+}

interface

uses
  ctypes;

const
  CLOCK_REALTIME = 0;
  CLOCK_MONOTONIC = 1;

type
  TClockSpec = record              { struct timespec (x86_64) }
    Sec: Int64;
    NSec: Int64;
  end;

function clock_gettime(Clk: cint; Tp: Pointer): cint; cdecl; external 'c';   { libc; served by the vDSO }
function MonoNowNs: Int64; inline;    { CLOCK_MONOTONIC in nanoseconds }
function RealNowUs: Int64; inline;    { CLOCK_REALTIME in microseconds since 1970; for the Date header }

implementation

function MonoNowNs: Int64;
var
  T: TClockSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @T);
  Result := T.Sec * 1000000000 + T.NSec;
end;

function RealNowUs: Int64;
var
  T: TClockSpec;
begin
  clock_gettime(CLOCK_REALTIME, @T);
  Result := T.Sec * 1000000 + T.NSec div 1000;
end;

end.
