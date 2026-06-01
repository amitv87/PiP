/**
 *  stream_server.m
 *  PiP
 *
 *  Minimal GCD-based HTTP server for HLS streaming.
 *  Uses dispatch sources for non-blocking socket I/O on a dedicated queue.
 *  Serves the live HLS playlist, MPEG-TS segments, embedded viewer HTML,
 *  embedded hls.js library, and a JSON status endpoint.
 */

#import "stream_server.h"
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>

/* ------------------------------------------------------------------ */
/* Constants                                                           */
/* ------------------------------------------------------------------ */

#define MAX_CONNECTIONS     20
#define READ_BUFFER_SIZE    4096
#define MAX_REQUEST_SIZE    8192

/* ------------------------------------------------------------------ */
/* Connection state structure                                          */
/* ------------------------------------------------------------------ */

typedef struct {
    int                  fd;          /* client socket file descriptor */
    dispatch_source_t    read_source; /* GCD read source for this connection */
    char                 buffer[MAX_REQUEST_SIZE]; /* accumulated request data */
    size_t               buffer_len;  /* bytes accumulated so far */
    int                  active;      /* non-zero if this slot is in use */
} connection_t;

/* ------------------------------------------------------------------ */
/* Server state structure                                              */
/* ------------------------------------------------------------------ */

struct stream_server_s {
    int                  port;             /* configured port number */
    int                  listen_fd;        /* listening socket fd (-1 if not listening) */
    int                  running;          /* non-zero if server is running */

    dispatch_queue_t     queue;            /* dedicated serial queue for server I/O */
    dispatch_source_t    accept_source;    /* GCD source for accept events */

    /* HLS content provider */
    hls_writer_t        *hls_writer;

    /* Embedded static content (not owned, caller must keep alive) */
    const uint8_t       *viewer_data;
    size_t               viewer_size;
    const uint8_t       *hlsjs_data;
    size_t               hlsjs_size;

    /* Connection pool */
    connection_t         connections[MAX_CONNECTIONS];
    int                  connection_count;
};

/* ------------------------------------------------------------------ */
/* Forward declarations (private helpers)                              */
/* ------------------------------------------------------------------ */

static void accept_connection(stream_server_t *server);
static void handle_request_data(stream_server_t *server, connection_t *conn);
static void process_http_request(stream_server_t *server, connection_t *conn, const char *method, const char *path);
static void send_response(int fd, int status_code, const char *status_text,
                          const char *content_type, const char *extra_headers,
                          const uint8_t *body, size_t body_len,
                          int head_only);
static void send_text_response(int fd, int status_code, const char *status_text,
                               const char *content_type, const char *extra_headers,
                               const char *body, int head_only);
static int write_all(int fd, const uint8_t *data, size_t len);
static void close_connection(stream_server_t *server, connection_t *conn);
static connection_t *find_free_slot(stream_server_t *server);

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

/**
 * Create a stream server instance bound to the given port.
 * @param port Port number to listen on (use 8080 as default)
 * @return New server instance, or NULL on allocation failure
 */
stream_server_t *
stream_server_create(int port)
{
    stream_server_t *server = calloc(1, sizeof(stream_server_t));
    if (!server) {
        return NULL;
    }

    server->port = port > 0 ? port : 8080;
    server->listen_fd = -1;
    server->running = 0;
    server->hls_writer = NULL;
    server->viewer_data = NULL;
    server->viewer_size = 0;
    server->hlsjs_data = NULL;
    server->hlsjs_size = 0;
    server->connection_count = 0;

    /* Initialize connection pool */
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        server->connections[i].fd = -1;
        server->connections[i].read_source = NULL;
        server->connections[i].buffer_len = 0;
        server->connections[i].active = 0;
    } // end of loop initializing connection pool

    server->queue = dispatch_queue_create("com.pip.stream_server", DISPATCH_QUEUE_SERIAL);

    return server;
} // end of function stream_server_create()

/**
 * Destroy a server instance and release all resources.
 * @param server The server instance (may be NULL)
 */
void
stream_server_destroy(stream_server_t *server)
{
    if (!server) {
        return;
    }

    stream_server_stop(server);

    /* The queue is ARC-managed in ObjC, no explicit release needed */
    server->queue = nil;

    free(server);
} // end of function stream_server_destroy()

/**
 * Set the HLS writer to serve content from.
 * @param server The server instance
 * @param writer The HLS writer providing playlist and segment data
 */
void
stream_server_set_hls_writer(stream_server_t *server, hls_writer_t *writer)
{
    if (server) {
        server->hls_writer = writer;
    }
} // end of function stream_server_set_hls_writer()

/**
 * Set the embedded viewer HTML data to serve at the root route.
 * @param server The server instance
 * @param data   Pointer to the HTML data
 * @param size   Size of the HTML data in bytes
 */
void
stream_server_set_viewer_data(stream_server_t *server, const uint8_t *data, size_t size)
{
    if (server) {
        server->viewer_data = data;
        server->viewer_size = size;
    }
} // end of function stream_server_set_viewer_data()

/**
 * Set the embedded hls.js library data to serve.
 * @param server The server instance
 * @param data   Pointer to the JavaScript data
 * @param size   Size of the JavaScript data in bytes
 */
void
stream_server_set_hlsjs_data(stream_server_t *server, const uint8_t *data, size_t size)
{
    if (server) {
        server->hlsjs_data = data;
        server->hlsjs_size = size;
    }
} // end of function stream_server_set_hlsjs_data()

/**
 * Start listening for incoming HTTP connections.
 * @param server The server instance
 * @return 0 on success, -1 on failure
 */
int
stream_server_start(stream_server_t *server)
{
    if (!server || server->running) {
        return -1;
    }

    /* Create the listening socket */
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"stream_server: failed to create socket");
        return -1;
    }

    /* Allow address reuse to avoid "address already in use" on restart */
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    /* Bind to all interfaces on the configured port */
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)server->port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"stream_server: failed to bind to port %d", server->port);
        close(fd);
        return -1;
    }

    /* Start listening with a backlog matching max connections */
    if (listen(fd, MAX_CONNECTIONS) < 0) {
        NSLog(@"stream_server: failed to listen on port %d", server->port);
        close(fd);
        return -1;
    }

    /* Make listening socket non-blocking so accept() can be drained safely. */
    int listen_flags = fcntl(fd, F_GETFL, 0);
    if (listen_flags < 0 || fcntl(fd, F_SETFL, listen_flags | O_NONBLOCK) < 0) {
        NSLog(@"stream_server: failed to set listen socket non-blocking");
        close(fd);
        return -1;
    }

    server->listen_fd = fd;
    server->running = 1;

    /* Create a GCD dispatch source to handle incoming connections */
    server->accept_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ,
        (uintptr_t)fd,
        0,
        server->queue
    );

    if (!server->accept_source) {
        NSLog(@"stream_server: failed to create accept dispatch source");
        close(fd);
        server->listen_fd = -1;
        server->running = 0;
        return -1;
    }

    /* Capture server pointer for the event handler block */
    stream_server_t *srv = server;

    dispatch_source_set_event_handler(server->accept_source, ^{
        accept_connection(srv);
    });

    dispatch_source_set_cancel_handler(server->accept_source, ^{
        close(fd);
    });

    dispatch_resume(server->accept_source);

    NSLog(@"stream_server: listening on port %d", server->port);
    return 0;
} // end of function stream_server_start()

/**
 * Stop the server and close all active connections.
 * @param server The server instance
 */
void
stream_server_stop(stream_server_t *server)
{
    if (!server || !server->running) {
        return;
    }

    server->running = 0;

    /* Cancel the accept source (its cancel handler will close listen_fd) */
    if (server->accept_source) {
        dispatch_source_cancel(server->accept_source);
        server->accept_source = nil;
    }

    server->listen_fd = -1;

    /* Close all active connections */
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (server->connections[i].active) {
            close_connection(server, &server->connections[i]);
        }
    } // end of loop closing all active connections

    NSLog(@"stream_server: stopped");
} // end of function stream_server_stop()

/**
 * Get the port the server is configured to listen on.
 * @param server The server instance
 * @return Port number
 */
int
stream_server_get_port(stream_server_t *server)
{
    return server ? server->port : 0;
} // end of function stream_server_get_port()

/**
 * Get the number of currently active client connections.
 * @param server The server instance
 * @return Number of active connections
 */
int
stream_server_get_connection_count(stream_server_t *server)
{
    return server ? server->connection_count : 0;
} // end of function stream_server_get_connection_count()

/**
 * Check whether the server is currently running.
 * @param server The server instance
 * @return Non-zero if running, 0 if stopped
 */
int
stream_server_is_running(stream_server_t *server)
{
    return server ? server->running : 0;
} // end of function stream_server_is_running()

/* ------------------------------------------------------------------ */
/* Private helpers                                                     */
/* ------------------------------------------------------------------ */

/**
 * Accept a new incoming connection and set up a GCD read source for it.
 * Called on the server's dispatch queue when the listen socket is readable.
 * @param server The server instance
 */
static void
accept_connection(stream_server_t *server)
{
    for (;;) {
        struct sockaddr_in client_addr;
        socklen_t addr_len = sizeof(client_addr);

        int client_fd = accept(server->listen_fd, (struct sockaddr *)&client_addr, &addr_len);
        if (client_fd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                /* Backlog drained for this accept event. */
                break;
            }
            if (errno == EINTR) {
                continue;
            }
            NSLog(@"stream_server: accept() failed: %d", errno);
            break;
        }

        /* Keep accepted sockets non-blocking so a slow/stalled client cannot
           block the entire serial server queue while we stream TS data. */
        int client_flags = fcntl(client_fd, F_GETFL, 0);
        if (client_flags < 0 || fcntl(client_fd, F_SETFL, client_flags | O_NONBLOCK) < 0) {
            NSLog(@"stream_server: failed to set O_NONBLOCK on fd=%d", client_fd);
            close(client_fd);
            continue;
        }

        /* Prevent process-wide SIGPIPE termination if a client disconnects
           while we are writing a response body. */
        int no_sigpipe = 1;
        if (setsockopt(client_fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) < 0) {
            NSLog(@"stream_server: failed to set SO_NOSIGPIPE on fd=%d", client_fd);
            close(client_fd);
            continue;
        }

        /* Find a free connection slot */
        connection_t *conn = find_free_slot(server);
        if (!conn) {
            NSLog(@"stream_server: max connections reached, rejecting client");
            close(client_fd);
            continue;
        }

        /* Initialize the connection */
        conn->fd = client_fd;
        conn->buffer_len = 0;
        conn->active = 1;
        server->connection_count++;

        char *client_ip = inet_ntoa(client_addr.sin_addr);
        int client_port = ntohs(client_addr.sin_port);
        NSLog(@"stream_server: accepted connection from %s:%d (fd=%d, active=%d)",
              client_ip, client_port, client_fd, server->connection_count);

        /* Create a GCD read source for this connection */
        conn->read_source = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_READ,
            (uintptr_t)client_fd,
            0,
            server->queue
        );

        if (!conn->read_source) {
            NSLog(@"stream_server: failed to create read source for fd=%d", client_fd);
            close(client_fd);
            conn->fd = -1;
            conn->active = 0;
            server->connection_count--;
            continue;
        }

        /* Capture pointers for the block.
           IMPORTANT: capture client_fd by VALUE for the cancel handler, because
           the connection slot may be reused before the cancel handler runs.
           If we used c->fd, the cancel handler could close the WRONG fd. */
        stream_server_t *srv = server;
        connection_t *c = conn;
        int fd_to_close = client_fd;

        dispatch_source_set_event_handler(conn->read_source, ^{
            handle_request_data(srv, c);
        });

        dispatch_source_set_cancel_handler(conn->read_source, ^{
            close(fd_to_close);
        });

        dispatch_resume(conn->read_source);
    }
} // end of function accept_connection()

/**
 * Handle incoming data on a client connection.
 * Accumulates data in the connection buffer until a complete HTTP request
 * is detected (double CRLF), then dispatches to process_http_request().
 * @param server The server instance
 * @param conn   The connection that has data available
 */
static void
handle_request_data(stream_server_t *server, connection_t *conn)
{
    if (!conn->active) {
        return;
    }

    char temp_buf[READ_BUFFER_SIZE];
    ssize_t bytes_read = read(conn->fd, temp_buf, sizeof(temp_buf));

    if (bytes_read <= 0) {
        /* Connection closed or error */
        close_connection(server, conn);
        return;
    }

    /* Append to connection buffer, respecting max size */
    size_t space = MAX_REQUEST_SIZE - conn->buffer_len - 1;
    size_t to_copy = (size_t)bytes_read < space ? (size_t)bytes_read : space;
    memcpy(conn->buffer + conn->buffer_len, temp_buf, to_copy);
    conn->buffer_len += to_copy;
    conn->buffer[conn->buffer_len] = '\0';

    /* Check for end of HTTP headers (double CRLF) */
    if (strstr(conn->buffer, "\r\n\r\n") || strstr(conn->buffer, "\n\n")) {
        /* Parse the request line: "METHOD /path HTTP/1.x" */
        char method[16] = {0};
        char path[1024] = {0};

        if (sscanf(conn->buffer, "%15s %1023s", method, path) == 2) {
            process_http_request(server, conn, method, path);
        } else {
            send_text_response(conn->fd, 400, "Bad Request",
                               "text/plain", NULL, "Bad Request\n", 0);
        }

        /* Close connection after response (HTTP/1.0 style) */
        close_connection(server, conn);
    }
} // end of function handle_request_data()

/**
 * Process a parsed HTTP request and send the appropriate response.
 * Routes: / (viewer), /stream.m3u8 (playlist), /segment_N.ts (segments),
 *         /hls.min.js (library), /status (JSON status).
 * @param server The server instance
 * @param conn   The client connection
 * @param method The HTTP method (e.g. "GET")
 * @param path   The requested URL path
 */
static void
process_http_request(stream_server_t *server, connection_t *conn, const char *method, const char *path)
{
    /* Cache-control headers for live HLS: prevent browsers from caching the
       playlist or error responses, which would cause playback to stall. */
    static const char *nocache = "Cache-Control: no-cache, no-store, must-revalidate\r\nPragma: no-cache\r\n";

    /* Only support GET and HEAD requests */
    int is_head = (strcmp(method, "HEAD") == 0);
    if (strcmp(method, "GET") != 0 && !is_head) {
        send_text_response(conn->fd, 405, "Method Not Allowed",
                           "text/plain", NULL, "Method Not Allowed\n", 0);
        return;
    }

    /* Route: GET / - Serve embedded viewer HTML */
    if (strcmp(path, "/") == 0) {
        if (server->viewer_data && server->viewer_size > 0) {
            send_response(conn->fd, 200, "OK",
                          "text/html; charset=utf-8", NULL,
                          server->viewer_data, server->viewer_size, is_head);
        } else {
            send_text_response(conn->fd, 503, "Service Unavailable",
                               "text/plain", NULL, "Viewer not configured\n", is_head);
        }
        return;
    }

    /* Route: GET /stream.m3u8 - Serve live HLS playlist (must NOT be cached) */
    if (strcmp(path, "/stream.m3u8") == 0) {
        if (!server->hls_writer) {
            send_text_response(conn->fd, 503, "Service Unavailable",
                               "text/plain", nocache, "No HLS writer configured\n", is_head);
            return;
        }

        char *playlist = hls_writer_get_playlist(server->hls_writer);
        if (!playlist) {
            send_text_response(conn->fd, 503, "Service Unavailable",
                               "text/plain", nocache, "No segments available yet\n", is_head);
            return;
        }

        send_text_response(conn->fd, 200, "OK",
                           "application/vnd.apple.mpegurl", nocache, playlist, is_head);
        free(playlist);
        return;
    } // end of route /stream.m3u8

    /* Route: GET /segment_N.ts - Serve individual MPEG-TS segments */
    uint64_t segment_index = 0;
    if (sscanf(path, "/segment_%llu.ts", &segment_index) == 1) {
        if (!server->hls_writer) {
            send_text_response(conn->fd, 503, "Service Unavailable",
                               "text/plain", nocache, "No HLS writer configured\n", is_head);
            return;
        }

        uint8_t *seg_data = NULL;
        size_t seg_size = 0;

        if (hls_writer_get_segment(server->hls_writer, segment_index, &seg_data, &seg_size) == 0) {
            /* hls_writer_get_segment now returns a malloc'd copy of the data,
               safe to use without worrying about ring buffer eviction. */
            send_response(conn->fd, 200, "OK",
                          "video/mp2t", NULL, seg_data, seg_size, is_head);
            free(seg_data);
        } else {
            send_text_response(conn->fd, 404, "Not Found",
                               "text/plain", nocache, "Segment not found\n", is_head);
        }
        return;
    } // end of route /segment_N.ts

    /* Route: GET /hls.min.js - Serve embedded hls.js library */
    if (strcmp(path, "/hls.min.js") == 0) {
        if (server->hlsjs_data && server->hlsjs_size > 0) {
            send_response(conn->fd, 200, "OK",
                          "application/javascript", NULL,
                          server->hlsjs_data, server->hlsjs_size, is_head);
        } else {
            send_text_response(conn->fd, 503, "Service Unavailable",
                               "text/plain", NULL, "hls.js not configured\n", is_head);
        }
        return;
    }

    /* Route: GET /status - Stream status JSON */
    if (strcmp(path, "/status") == 0) {
        int is_streaming = (server->hls_writer != NULL) ? 1 : 0;
        int seg_count = 0;
        if (server->hls_writer) {
            seg_count = hls_writer_segment_count(server->hls_writer);
            if (seg_count > 0) {
                is_streaming = 1;
            } else {
                is_streaming = 0;
            }
        }

        char json_buf[256];
        snprintf(json_buf, sizeof(json_buf),
                 "{\"streaming\": %s, \"segments\": %d, \"port\": %d}",
                 is_streaming ? "true" : "false",
                 seg_count,
                 server->port);

        send_text_response(conn->fd, 200, "OK",
                           "application/json", nocache, json_buf, is_head);
        return;
    } // end of route /status

    /* No route matched */
    send_text_response(conn->fd, 404, "Not Found",
                       "text/plain", NULL, "Not Found\n", is_head);
} // end of function process_http_request()

/**
 * Send an HTTP response with binary body data.
 * Includes Content-Type, Content-Length, Connection: close, and CORS headers.
 * @param fd            Client socket file descriptor
 * @param status_code   HTTP status code (e.g. 200)
 * @param status_text   HTTP status text (e.g. "OK")
 * @param content_type  Content-Type header value
 * @param extra_headers Additional HTTP headers (NULL for none, must end with \r\n)
 * @param body          Response body data
 * @param body_len      Length of response body in bytes
 * @param head_only     If non-zero, send only headers (for HEAD requests)
 */
static void
send_response(int fd, int status_code, const char *status_text,
              const char *content_type, const char *extra_headers,
              const uint8_t *body, size_t body_len,
              int head_only)
{
    /* Build the HTTP response header */
    char header[1024];
    int header_len = snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "%s"
        "\r\n",
        status_code, status_text,
        content_type,
        body_len,
        extra_headers ? extra_headers : "");

    /* Send header, then body (skip body for HEAD requests). */
    if (write_all(fd, (const uint8_t *)header, (size_t)header_len) != 0) {
        return;
    }

    if (!head_only && body && body_len > 0) {
        (void)write_all(fd, body, body_len);
    }
} // end of function send_response()

/**
 * Write the full buffer to a socket.
 * Retries short writes and transient EINTR/EAGAIN failures.
 * @return 0 on success, -1 on write failure
 */
static int
write_all(int fd, const uint8_t *data, size_t len)
{
    const int max_eagain_retries = 250; /* ~250ms with 1ms sleep */
    int eagain_retries = 0;
    size_t total_written = 0;
    while (total_written < len) {
        ssize_t written = write(fd, data + total_written, len - total_written);
        if (written > 0) {
            total_written += (size_t)written;
            eagain_retries = 0;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            eagain_retries++;
            if (eagain_retries >= max_eagain_retries) {
                return -1;
            }
            usleep(1000);
            continue;
        }
        return -1;
    }
    return 0;
}

/**
 * Send an HTTP response with a C string body (convenience wrapper).
 * @param fd            Client socket file descriptor
 * @param status_code   HTTP status code
 * @param status_text   HTTP status text
 * @param content_type  Content-Type header value
 * @param extra_headers Additional HTTP headers (NULL for none)
 * @param body          Null-terminated response body string
 * @param head_only     If non-zero, send only headers (for HEAD requests)
 */
static void
send_text_response(int fd, int status_code, const char *status_text,
                   const char *content_type, const char *extra_headers,
                   const char *body, int head_only)
{
    send_response(fd, status_code, status_text,
                  content_type, extra_headers,
                  (const uint8_t *)body,
                  body ? strlen(body) : 0,
                  head_only);
} // end of function send_text_response()

/**
 * Close a client connection and free its resources.
 * Cancels the GCD read source and marks the connection slot as available.
 * @param server The server instance
 * @param conn   The connection to close
 */
static void
close_connection(stream_server_t *server, connection_t *conn)
{
    if (!conn || !conn->active) {
        return;
    }

    conn->active = 0;

    /* Save and invalidate the fd BEFORE cancelling, so that if the slot
       is reused before the cancel handler runs, the new fd won't be corrupted.
       The cancel handler captures the fd by VALUE and will close the right one. */
    int saved_fd = conn->fd;
    conn->fd = -1;

    if (conn->read_source) {
        dispatch_source_cancel(conn->read_source);
        conn->read_source = nil;
        /* fd will be closed by the cancel handler (which captured it by value) */
    } else if (saved_fd >= 0) {
        /* No read_source (error path): close fd directly */
        close(saved_fd);
    }

    conn->buffer_len = 0;

    if (server->connection_count > 0) {
        server->connection_count--;
    }
} // end of function close_connection()

/**
 * Find a free connection slot in the server's connection pool.
 * @param server The server instance
 * @return Pointer to a free connection_t slot, or NULL if all slots are in use
 */
static connection_t *
find_free_slot(stream_server_t *server)
{
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (!server->connections[i].active) {
            return &server->connections[i];
        }
    } // end of loop searching for free connection slot
    return NULL;
} // end of function find_free_slot()
