/**
 *  stream_server.h
 *  PiP
 *
 *  Minimal GCD-based HTTP server for HLS streaming. Serves the live HLS
 *  playlist and MPEG-TS segments from an hls_writer instance, along with
 *  embedded viewer HTML and hls.js library. Uses dispatch sources for
 *  non-blocking socket I/O on a dedicated dispatch queue.
 */

#ifndef STREAM_SERVER_H
#define STREAM_SERVER_H

#import <Foundation/Foundation.h>
#include "hls_writer.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct stream_server_s stream_server_t;

/**
 * Create a stream server instance bound to the given port.
 * The server is not started until stream_server_start() is called.
 * @param port Port number to listen on (use 8080 as default)
 * @return New server instance, or NULL on allocation failure
 */
stream_server_t *stream_server_create(int port);

/**
 * Destroy a server instance and release all resources.
 * Stops the server if it is still running.
 * @param server The server instance (may be NULL)
 */
void stream_server_destroy(stream_server_t *server);

/**
 * Set the HLS writer to serve content from.
 * The writer must remain valid for the lifetime of the server.
 * @param server The server instance
 * @param writer The HLS writer providing playlist and segment data
 */
void stream_server_set_hls_writer(stream_server_t *server, hls_writer_t *writer);

/**
 * Set the embedded viewer HTML data to serve at the root route.
 * The data pointer must remain valid for the lifetime of the server.
 * @param server The server instance
 * @param data   Pointer to the HTML data (not copied, must stay valid)
 * @param size   Size of the HTML data in bytes
 */
void stream_server_set_viewer_data(stream_server_t *server, const uint8_t *data, size_t size);

/**
 * Set the embedded hls.js library data to serve.
 * The data pointer must remain valid for the lifetime of the server.
 * @param server The server instance
 * @param data   Pointer to the JavaScript data (not copied, must stay valid)
 * @param size   Size of the JavaScript data in bytes
 */
void stream_server_set_hlsjs_data(stream_server_t *server, const uint8_t *data, size_t size);

/**
 * Start listening for incoming HTTP connections.
 * Creates a TCP socket, binds to the configured port, and begins
 * accepting connections on a dedicated GCD queue.
 * @param server The server instance
 * @return 0 on success, -1 on failure
 */
int stream_server_start(stream_server_t *server);

/**
 * Stop the server and close all active connections.
 * The server can be restarted with stream_server_start().
 * @param server The server instance
 */
void stream_server_stop(stream_server_t *server);

/**
 * Get the port the server is configured to listen on.
 * @param server The server instance
 * @return Port number
 */
int stream_server_get_port(stream_server_t *server);

/**
 * Get the number of currently active client connections.
 * @param server The server instance
 * @return Number of active connections
 */
int stream_server_get_connection_count(stream_server_t *server);

/**
 * Check whether the server is currently running and accepting connections.
 * @param server The server instance
 * @return Non-zero if running, 0 if stopped
 */
int stream_server_is_running(stream_server_t *server);

#ifdef __cplusplus
}
#endif

#endif /* STREAM_SERVER_H */
