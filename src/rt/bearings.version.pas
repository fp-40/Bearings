{ bearings.version - the bearings version and the version of the compiler
  that built the program. It lives in src/rt, the lowest layer, so every
  layer (and an application on top) can use it. Constants only; safe from
  any thread. }
unit bearings.version;

{$mode objfpc}{$H+}

interface

const
  { bearings' version }
  BEARINGS_VERSION = '0.1.0';
  { the Free Pascal version and target this program was built with }
  FPC_VERSION_TEXT = {$I %FPCVERSION%} + ' (' + {$I %FPCTARGETCPU%} + '-' + {$I %FPCTARGETOS%} + ')';

implementation

end.
