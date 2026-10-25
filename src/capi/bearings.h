/* bearings.h - the C interface of libbearings.so (src/capi/bearings.capi.pas,
   whose header comment describes the model, the head buffer and the
   threading rules).

   The Python package (python/) hands this file to cffi, whose parser
   accepts no preprocessor directive but the include guard below: keep
   the declarations plain C. */
#ifndef BEARINGS_H
#define BEARINGS_H

typedef struct bearings_server bearings_server;
typedef struct bearings_exchange bearings_exchange;

/* Zeroed fields take the defaults. */
typedef struct {
    const char *host;           /* NULL or "" = "0.0.0.0" */
    int port;                   /* 0 = a free port (bearings_server_port) */
    const char *unix_path;      /* NULL or "" = TCP */
    int unix_mode;              /* 0 = 0660 */
    int inherited_fd;           /* > 0: an open listening socket */
    int loops;                  /* 0 = one per CPU */
    int workers;                /* 0 = min(32, CPUs + 4) */
    int worker_queue_limit;     /* 0 = no limit */
    int saturated_status;       /* with a queue limit: the answer when it is full (503) */
    int max_connections;        /* 0 = no limit */
    int access_log;             /* 0 off, 1 JSON lines, 2 console lines (stdout) */
    int access_log_level;       /* lines below this level of Python's logging are dropped: 0 = none,
                                   30 (warning) or 40 (error) keeps the 4xx and 5xx */
    int access_log_user_agent;  /* 1 = the lines have the User-Agent header */
    int access_log_referer;     /* 1 = the lines have the Referer header */
    int access_log_colors;      /* 1 = the console lines have the level in structlog's ANSI color */
    int metrics;                /* 1 = keep the counters of bearings_metrics */
    int raise_fd_limit;         /* 1 = start raises the soft limit on open file descriptors to the
                                   hard limit (every connection is one); select(2) cannot take a
                                   descriptor >= 1024, and child processes inherit the limit */
    /* WebSockets: accepted on this path (NULL or "" = none) */
    const char *ws_path;
    const char *ws_origins;     /* the Origin values allowed, one per line */
    int ws_same_host;           /* 1 = also an Origin whose host[:port] is the Host header */
    int ws_any_port;            /* 1 = also any port of the Host header's name */
    int ws_ping_ms;             /* 0 = 25000; -1 = no pings */
    int ws_idle_ms;             /* 0 = 60000; -1 = no idle timeout */
    long long ws_max_message;   /* 0 = 16 MiB */
    long long ws_send_high_water; /* 0 = 1 MiB */
    int ws_close_on_backpressure; /* 1 = a subscriber that is behind is closed, not skipped */
    const char *ws_ignore_text; /* a text message equal to this never reaches the callback */
} bearings_config;

/* Runs on a worker thread, once per request; head and ex are valid until it returns. */
typedef void (*bearings_request_cb)(void *ctx, bearings_exchange *ex,
                                    const char *head, size_t len);

/* A WebSocket's events, on a worker thread, one at a time per connection:
   1 opened (data: the handshake, laid out as a request head), 2 text,
   3 binary, 4 closed (data: the code in decimal, NUL, the reason; the last). */
typedef void (*bearings_ws_cb)(void *ctx, int event, unsigned long long id,
                               const char *data, size_t len);

const char *bearings_version(void);

bearings_server *bearings_server_new(const bearings_config *cfg, bearings_request_cb cb,
                                     bearings_ws_cb ws_cb, void *ctx,
                                     char *err, size_t err_len);
int bearings_server_port(bearings_server *srv);
void bearings_server_stop(bearings_server *srv, int grace_ms);
void bearings_server_wait(bearings_server *srv);
void bearings_server_free(bearings_server *srv);
size_t bearings_metrics(bearings_server *srv, char *buf, size_t len);

/* >= 0 bytes read (0 at the end), -1 body error, -2 client gone. */
ssize_t bearings_read(bearings_exchange *ex, char *buf, size_t max);
size_t bearings_body_error(bearings_exchange *ex, char *buf, size_t len);
int bearings_is_canceled(bearings_exchange *ex);

/* 0 ok, 1 canceled or already answered, -1 invalid header, -3 internal error.
   With a body of known length (blen > 0; a file), a Content-Length among
   the headers is left out: the server writes the length. */
int bearings_respond(bearings_exchange *ex, int status, const char *headers, size_t hlen,
                     const char *body, size_t blen);
int bearings_respond_file(bearings_exchange *ex, int status, const char *headers, size_t hlen,
                          int fd, long long offset, long long len);
int bearings_begin_stream(bearings_exchange *ex, int status, const char *headers, size_t hlen);
int bearings_write(bearings_exchange *ex, const char *data, size_t len);
int bearings_finish(bearings_exchange *ex);
void bearings_abort_stream(bearings_exchange *ex, const char *msg);

/* WebSockets, by id; any thread. 0 ok, 1 closing or gone, 2 full (send:
   nothing was queued), -1 invalid topic, -3 internal error. */
int bearings_ws_send(bearings_server *srv, unsigned long long id, const char *data, size_t len);
int bearings_ws_close(bearings_server *srv, unsigned long long id, int code, const char *reason);
int bearings_ws_subscribe(bearings_server *srv, unsigned long long id,
                          const char *topic, size_t len);
int bearings_ws_unsubscribe(bearings_server *srv, unsigned long long id,
                            const char *topic, size_t len);
int bearings_ws_publish(bearings_server *srv, const char *topic, size_t tlen,
                        const char *data, size_t len);
size_t bearings_ws_count(bearings_server *srv);

#endif
