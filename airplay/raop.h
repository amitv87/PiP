#ifndef RAOP_H
#define RAOP_H

#include "dnssd.h"
#include "stream.h"
#include "raop_ntp.h"

#if defined (WIN32) && defined(DLL_EXPORT)
# define RAOP_API __declspec(dllexport)
#else
# define RAOP_API
#endif

#ifdef __cplusplus
extern "C" {
#endif


/* Define syslog style log levels */
#define RAOP_LOG_EMERG       0       /* system is unusable */
#define RAOP_LOG_ALERT       1       /* action must be taken immediately */
#define RAOP_LOG_CRIT        2       /* critical conditions */
#define RAOP_LOG_ERR         3       /* error conditions */
#define RAOP_LOG_WARNING     4       /* warning conditions */
#define RAOP_LOG_NOTICE      5       /* normal but significant condition */
#define RAOP_LOG_INFO        6       /* informational */
#define RAOP_LOG_DEBUG       7       /* debug-level messages */


typedef struct raop_s raop_t;

typedef void (*raop_log_callback_t)(void *cls, int level, const char *msg);

typedef struct{
  char* osName;
  char* osVersion;
  char* model;
  char* name;
} raop_device_info;

typedef struct raop_connection_s{
  void* priv;
  void* usr_data;
  raop_device_info devInfo;
} raop_connection_t;

struct raop_callbacks_s {
    void* cls;

    void  (*audio_process)(void *cls, raop_ntp_t *ntp, aac_decode_struct *data, raop_connection_t* conn);
    void  (*video_process)(void *cls, raop_ntp_t *ntp, h264_decode_struct *data, raop_connection_t* conn);

    /* Optional but recommended callback functions */
    void  (*conn_init)(void *cls, raop_connection_t* conn);
    void  (*conn_destroy)(void *cls, raop_connection_t* conn);
    void  (*conn_reset) (void *cls, int timeouts, bool reset_video, raop_connection_t* conn);
    void  (*conn_teardown)(void *cls, bool *teardown_96, bool *teardown_110, raop_connection_t* conn);
    void  (*audio_flush)(void *cls, raop_connection_t* conn);
    void  (*video_flush)(void *cls, raop_connection_t* conn);
    void  (*audio_set_volume)(void *cls, float volume, raop_connection_t* conn);
    void  (*audio_set_metadata)(void *cls, const void *buffer, int buflen, raop_connection_t* conn);
    void  (*audio_set_coverart)(void *cls, const void *buffer, int buflen, raop_connection_t* conn);
    void  (*audio_remote_control_id)(void *cls, const char *dacp_id, const char *active_remote_header, raop_connection_t* conn);
    void  (*audio_set_progress)(void *cls, unsigned int start, unsigned int curr, unsigned int end, raop_connection_t* conn);
    void  (*audio_get_format)(void *cls, audio_format_info* info, raop_connection_t* conn);
    void  (*video_report_size)(void *cls, float *width_source, float *height_source, float *width, float *height, raop_connection_t* conn);
};
typedef struct raop_callbacks_s raop_callbacks_t;
raop_ntp_t *raop_ntp_init(raop_connection_t* conn, logger_t *logger, raop_callbacks_t *callbacks, const unsigned char *remote_addr, int remote_addr_len, unsigned short timing_rport);
  
RAOP_API raop_t *raop_init(int max_clients, raop_callbacks_t *callbacks);
RAOP_API void raop_set_log_level(raop_t *raop, int level);
RAOP_API void raop_set_log_callback(raop_t *raop, raop_log_callback_t callback, void *cls);
RAOP_API int raop_set_plist(raop_t *raop, const char *plist_item, const int value);
RAOP_API void raop_set_port(raop_t *raop, unsigned short port);
RAOP_API void raop_set_udp_ports(raop_t *raop, unsigned short port[3]);
RAOP_API void raop_set_tcp_ports(raop_t *raop, unsigned short port[2]);
RAOP_API unsigned short raop_get_port(raop_t *raop);
RAOP_API void *raop_get_callback_cls(raop_t *raop);
RAOP_API int raop_start(raop_t *raop, unsigned short *port);
RAOP_API int raop_is_running(raop_t *raop);
RAOP_API void raop_stop(raop_t *raop);
RAOP_API void raop_set_dnssd(raop_t *raop, dnssd_t *dnssd);
RAOP_API void raop_destroy(raop_t *raop);

RAOP_API void raop_stop_conn(raop_connection_t* conn);

#ifdef __cplusplus
}
#endif
#endif
