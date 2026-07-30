#ifndef PIER_FFMPEG_H
#define PIER_FFMPEG_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#if defined(__GNUC__)
#define PPFF_API __attribute__((visibility("default")))
#else
#define PPFF_API
#endif

PPFF_API const char *ppff_version(void);
PPFF_API const char *ppff_configuration(void);
PPFF_API const char *ppff_license(void);

typedef struct PPFFSession PPFFSession;

typedef int (*PPFFReadCallback)(void *opaque, uint8_t *buffer, int size);
typedef int64_t (*PPFFSeekCallback)(void *opaque, int64_t offset, int whence);
typedef int (*PPFFInterruptCallback)(void *opaque);

typedef struct PPFFIOCallbacks {
    void *opaque;
    PPFFReadCallback read;
    PPFFSeekCallback seek;
    PPFFInterruptCallback interrupt;
} PPFFIOCallbacks;

typedef struct PPFFProbeLimits {
    int64_t maximum_probe_bytes;
    int64_t maximum_analyze_duration_us;
} PPFFProbeLimits;

typedef struct PPFFError {
    int code;
    char message[256];
} PPFFError;

typedef enum PPFFMediaKind {
    PPFF_MEDIA_KIND_UNKNOWN = 0,
    PPFF_MEDIA_KIND_VIDEO = 1,
    PPFF_MEDIA_KIND_AUDIO = 2,
    PPFF_MEDIA_KIND_SUBTITLE = 3
} PPFFMediaKind;

typedef struct PPFFMediaInfo {
    char container_name[128];
    int64_t duration_us;
    int is_seekable;
} PPFFMediaInfo;

typedef struct PPFFStreamInfo {
    int index;
    PPFFMediaKind kind;
    int codec_id;
    char codec_name[64];
    char language[32];
    char title[128];
    int width;
    int height;
    int sample_rate;
    int channel_count;
    int is_default;
} PPFFStreamInfo;

enum {
    PPFF_AVSEEK_SIZE = 0x10000,
    PPFF_ERROR_EOF = -541478725,
    PPFF_ERROR_IO = -5,
    PPFF_ERROR_INVALID_ARGUMENT = -22
};

PPFF_API PPFFSession *ppff_session_open(
    PPFFIOCallbacks callbacks,
    PPFFProbeLimits limits,
    PPFFError *error
);
PPFF_API int ppff_session_media_info(
    const PPFFSession *session,
    PPFFMediaInfo *info,
    PPFFError *error
);
PPFF_API int ppff_session_stream_count(const PPFFSession *session);
PPFF_API int ppff_session_stream_info(
    const PPFFSession *session,
    int index,
    PPFFStreamInfo *info,
    PPFFError *error
);
PPFF_API void ppff_session_close(PPFFSession **session);

#if defined(__cplusplus)
}
#endif

#endif
