{ libbearings - the shared library of bearings.capi (libbearings.so).

  Build (from the repository root; python/ does this when it builds its
  wheel):
    fpc -Mobjfpc -Sh -O2 -fPIC -Fusrc/rt -Fusrc/http -Fusrc/http1 \
        -Fusrc/server -Fusrc/ws -Fusrc/capi -FUbuild/capi \
        -obuild/capi/libbearings.so src/capi/libbearings.pas

  src/capi/bearings.h declares the routines for C. }
library libbearings;

{$mode objfpc}{$H+}

uses
  cthreads, bearings.capi;

exports
  bearings_version,
  bearings_server_new,
  bearings_server_port,
  bearings_server_stop,
  bearings_server_wait,
  bearings_server_free,
  bearings_metrics,
  bearings_read,
  bearings_body_error,
  bearings_is_canceled,
  bearings_respond,
  bearings_respond_file,
  bearings_begin_stream,
  bearings_write,
  bearings_finish,
  bearings_abort_stream,
  bearings_ws_send,
  bearings_ws_close,
  bearings_ws_subscribe,
  bearings_ws_unsubscribe,
  bearings_ws_publish,
  bearings_ws_count;

end.
