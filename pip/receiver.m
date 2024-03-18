//
//  server.m
//  PiP
//
//  Created by Amit Verma on 23/04/22.
//  Copyright © 2022 boggyb. All rights reserved.
//
#ifndef NO_AIRPLAY

#include <stdio.h>
#include <stdarg.h>

#include "stream.h"
#include "logger.h"
#include "dnssd.h"

#import "window.h"

#include <ifaddrs.h>
#include <net/if_dl.h>
#include <sys/socket.h>
#include <sys/utsname.h>

#include <CoreAudioTypes/CoreAudioBaseTypes.h>

#define MAX_ACTIVE_SESSIONS 10

#define LOWEST_ALLOWED_PORT 1024
#define HIGHEST_PORT 65535
#define NTP_TIMEOUT_LIMIT 5

#include <net/if.h>
#include <net/ethernet.h>
#include <sys/types.h>
#include <sys/sysctl.h>

static raop_t *raop = NULL;
static dnssd_t *dnssd = NULL;
static uint open_connections = 0;

static void get_mac(uint8_t mac[6]) {
  struct ifaddrs *ifaddrs;
  if(getifaddrs(&ifaddrs) != 0) return;
  struct ifaddrs* ifa = ifaddrs;
  do{
    if(ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_INET && ifa->ifa_name && strncmp("lo", ifa->ifa_name, 2)){
      size_t len;
      int mib[] = {CTL_NET, AF_ROUTE, 0, AF_LINK, NET_RT_IFLIST, if_nametoindex(ifa->ifa_name)};

      if (mib[5] == 0){
        printf("error calling if_nametoindex\r\n");
        continue;
      }

      if (sysctl(mib, sizeof(mib)/sizeof(mib[0]), NULL, (size_t*)&len, NULL, 0) < 0){
        printf("sysctl 1 error: %s\r\n", strerror(errno));
        continue;
      }

      char * macbuf = (char*) malloc(len);
      if(sysctl(mib, 6, macbuf, (size_t*)&len, NULL, 0) < 0){
        printf("sysctl 1 error: %s\r\n", strerror(errno));
        continue;
      }

      struct if_msghdr * ifm = (struct if_msghdr *)macbuf;
      struct sockaddr_dl * sdl = (struct sockaddr_dl *)(ifm + 1);
      memcpy(mac, (unsigned char *)LLADDR(sdl), 6);
      free(macbuf);
      break;
    }
  }while((ifa = ifa->ifa_next));
  freeifaddrs(ifaddrs);
}

void airplay_receiver_session_start(raop_connection_t* conn){
  if(!conn || conn->usr_data) return;
  NSLog(@"airplay_receiver_session_start: %p", conn);
  Window* window = [[Window alloc] initWithAirplay: true andTitle:[NSString stringWithFormat:@"%s (%s)", conn->devInfo.name, conn->devInfo.model]];
  window.conn = conn;
  conn->usr_data = (__bridge void *)(window);
  [window makeKeyAndOrderFront:[NSApplication sharedApplication]];
}

void airplay_receiver_session_stop(raop_connection_t* conn){
  if(!conn) return;
  NSLog(@"airplay_receiver_session_stop: %p", conn);
  open_connections -= 1;
  conn->usr_data = NULL;
  raop_stop_conn(conn);
}

static void conn_init(void *cls, raop_connection_t* conn) {
  open_connections += 1;
  NSLog(@"conn_init open connections: %i", open_connections);
  dispatch_sync(dispatch_get_main_queue(), ^{airplay_receiver_session_start(conn);});
}

static void conn_destroy(void *cls, raop_connection_t* conn) {
  open_connections -= 1;
  NSLog(@"conn_destroy open connections: %i", open_connections);
  Window* window = (__bridge Window *)(conn->usr_data);
  conn->usr_data = window.conn = NULL;
  dispatch_async(dispatch_get_main_queue(), ^{[window performClose:window];});
}

static void conn_reset(void *cls, int timeouts, bool reset_video, raop_connection_t* conn) {
  NSLog(@"conn_reset cls: %p, timeouts: %d, reset_video: %u", cls, timeouts, reset_video);
}

static void conn_teardown(void *cls, bool *teardown_96, bool *teardown_110, raop_connection_t* conn){
  NSLog(@"conn_teardown cls: %p, teardown_96: %u, teardown_110: %u", cls, teardown_96, *teardown_110);
}

static void audio_process (void *cls, raop_ntp_t *ntp, aac_decode_struct *data, raop_connection_t* conn){
  if(!conn->usr_data) return;
  Window* window = (__bridge Window *)(conn->usr_data);
  [window renderAudio:data->data withLength:data->data_len];
}

static void video_process(void *cls, raop_ntp_t *ntp, h264_decode_struct *data, raop_connection_t* conn){
  if(!conn->usr_data) return;
  Window* window = (__bridge Window *)(conn->usr_data);
  int idx = 0, lastIdx = -1, zeroes = 0;

  while(idx < data->data_len){
    uint8_t val = data->data[idx++];

    if(zeroes < 3){
      if(val == 0) zeroes += 1;
      else zeroes = 0;
      continue;
    }

    if(val == 0) continue;

    if(val == 1 && data->data_len){
      if(lastIdx >= 0) [window renderH264:data->data + lastIdx withLength:(int)(idx - zeroes - 1 - lastIdx)];
      lastIdx = idx - zeroes -1;
    }
    zeroes = 0;
  }
  if(lastIdx >= 0) [window renderH264:data->data + lastIdx withLength:(int)(idx - zeroes - lastIdx)];
}

static void audio_flush (void *cls, raop_connection_t* conn){
  NSLog(@"audio_flush cls: %p", cls);
}

static void video_flush (void *cls, raop_connection_t* conn){
  NSLog(@"video_flush cls: %p", cls);
}

static void audio_set_volume (void *cls, float volume_db, raop_connection_t* conn){
  float volume_p = 0;
  if(volume_db < -144) volume_db = -144;
  else if(volume_db > 0) volume_db = 0;
  if(volume_db != -144) volume_p = 1.0 + volume_db / 30.0;
//  LOGI("audio_set_volume volume_db: %f, volume_p: %f", volume_db, volume_p);
  if(!conn->usr_data) return;
  Window* window = (__bridge Window *)(conn->usr_data);
  [window setVolume:volume_p];
}

static void audio_set_metadata(void *cls, const void *buffer, int buflen, raop_connection_t* conn){
  NSLog(@"audio_set_metadata len: %.*s", buflen, buffer);
}

static void audio_set_coverart(void *cls, const void *buffer, int buflen, raop_connection_t* conn){
  NSLog(@"audio_set_coverart: %.*s", buflen, buffer);
}

static void audio_remote_control_id(void *cls, const char *dacp_id, const char *active_remote_header, raop_connection_t* conn){
  NSLog(@"audio_remote_control_id dacp_id: %s, active_remote_header: %s", dacp_id, active_remote_header);
}

static void audio_set_progress(void *cls, unsigned int start, unsigned int curr, unsigned int end, raop_connection_t* conn){
  NSLog(@"audio_set_progress start: %u, curr: %u, end: %u", start, curr, end);
}

static void audio_get_format(void *cls, audio_format_info* info, raop_connection_t* conn){
  NSLog(@"ct=%d spf=%d usingScreen=%d isMedia=%d  audioFormat=0x%lx", info->ct, info->spf, info->usingScreen, info->isMedia, info->audioFormat);
  if(!conn->usr_data) return;
  UInt32 format;
  switch(info->ct){
    case 2: format = kAudioFormatAppleLossless; break;
    case 4: format = kAudioFormatMPEG4AAC; break;
    case 8: format = kAudioFormatMPEG4AAC_ELD; break;
    default: return;
  }
  Window* window = (__bridge Window *)(conn->usr_data);
  [window setAudioInputFormat:format withsampleRate:info->sr andChannels:2 andSPF:info->spf];
}

static void video_report_size(void *cls, float *width_source, float *height_source, float *width, float *height, raop_connection_t* conn){
  NSLog(@"video_report_size cls: %p, width_source: %f, height_source: %f, width: %f, height: %f",
       cls, *width_source, *height_source, *width, *height);
}

static void log_callback (void *cls, int level, const char *msg) {
  NSLog(@"%s", msg);
}

void airplay_receiver_stop(void){
  if(raop){
    raop_destroy(raop);
    raop = NULL;
  }
  if(dnssd){
    dnssd_unregister_raop(dnssd);
    dnssd_unregister_airplay(dnssd);
    dnssd_destroy(dnssd);
    dnssd = NULL;
  }
}

void airplay_receiver_start(void){
  airplay_receiver_stop();
  raop_callbacks_t raop_cbs = {
    .conn_init = conn_init,
    .conn_destroy = conn_destroy,
//    .conn_reset = conn_reset,
//    .conn_teardown = conn_teardown,
//    .audio_flush = audio_flush,
//    .video_flush = video_flush,
    .audio_process = audio_process,
    .video_process = video_process,
    .audio_set_volume = audio_set_volume,
//    .audio_set_metadata = audio_set_metadata,
//    .audio_set_coverart = audio_set_coverart,
//    .audio_remote_control_id = audio_remote_control_id,
//    .audio_set_progress = audio_set_progress,
    .audio_get_format = audio_get_format,
//    .video_report_size = video_report_size,
  };

  NSSize size = [[NSScreen mainScreen] frame].size;
  float scale = [NSScreen mainScreen].backingScaleFactor;

  NSNumberFormatter* f = [[NSNumberFormatter alloc] init];
  f.numberStyle = NSNumberFormatterDecimalStyle;
  NSNumber* ns_scale = [f numberFromString:(NSString*)getPrefOption(@"airplay_scale_factor")];
  if(ns_scale) scale = [ns_scale floatValue];
  // NSLog(@"screen res: %@, scale: %f", NSStringFromSize(size), scale);

  raop = raop_init(MAX_ACTIVE_SESSIONS * 2, &raop_cbs);
  raop_set_plist(raop, "width", size.width * scale);
  raop_set_plist(raop, "height", size.height * scale);
  raop_set_plist(raop, "refreshRate", 60);
  raop_set_plist(raop, "maxFPS", 60);
  raop_set_plist(raop, "overscanned", 0);
  // raop_set_plist(raop, "clientFPSdata", 1);

  raop_set_plist(raop, "max_ntp_timeouts", NTP_TIMEOUT_LIMIT);

  unsigned short ports[2] = {0};
  raop_set_tcp_ports(raop, ports);
  raop_set_udp_ports(raop, ports);

  raop_set_log_callback(raop, log_callback, NULL);
  raop_set_log_level(raop, LOGGER_INFO);
//  raop_set_log_level(raop, RAOP_LOG_DEBUG);

  unsigned short port = raop_get_port(raop);
  raop_start(raop, &port);
  raop_set_port(raop, port);
  
  NSLog(@"raop listening on %u", port);

  int error;
  uint8_t hw_addr[] = {0xa,0xb,0x0,0x0,0xb,0xa};
  get_mac(hw_addr);
  NSLog(@"hw_addr: %02x:%02x:%02x:%02x:%02x:%02x", hw_addr[0], hw_addr[1], hw_addr[2], hw_addr[3], hw_addr[4], hw_addr[5]);

  char server_name[64] = {0};
  int rc = snprintf(server_name, sizeof(server_name) - 1, "%s", "PiP");

  struct utsname buf;
  if(uname(&buf) == 0) rc += snprintf(server_name + rc, sizeof(server_name) - 1 - rc, "@%s", buf.nodename);
  dnssd = dnssd_init(server_name, rc, (char*)hw_addr, sizeof(hw_addr), &error);
  if(error){
    NSLog(@"Could not initialize dnssd library, error: %d", error);
    airplay_receiver_stop();
    return;
  }

  raop_set_dnssd(raop, dnssd);
  dnssd_register_raop(dnssd, port);
  dnssd_register_airplay(dnssd, port != HIGHEST_PORT ? port + 1 : port - 1);
}

#endif
