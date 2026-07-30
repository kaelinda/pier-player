#ifndef PIER_FFMPEG_H
#define PIER_FFMPEG_H

#include <stdint.h>
#include <CoreVideo/CoreVideo.h>

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

typedef enum PPFFSampleKind {
    PPFF_SAMPLE_KIND_NONE = 0,
    PPFF_SAMPLE_KIND_VIDEO = 1,
    PPFF_SAMPLE_KIND_AUDIO = 2,
    PPFF_SAMPLE_KIND_SUBTITLE = 3
} PPFFSampleKind;

typedef enum PPFFDecoderMode {
    PPFF_DECODER_MODE_NONE = 0,
    PPFF_DECODER_MODE_VIDEOTOOLBOX = 1,
    PPFF_DECODER_MODE_SOFTWARE = 2
} PPFFDecoderMode;

typedef struct PPFFDecodeConfiguration {
    int prefer_hardware;
    int force_hardware_open_failure;
} PPFFDecodeConfiguration;

typedef struct PPFFDecoderStatus {
    PPFFDecoderMode mode;
    int hardware_attempted;
    int software_fallback_count;
} PPFFDecoderStatus;

typedef struct PPFFSample {
    PPFFSampleKind kind;
    int stream_index;
    int64_t presentation_time_us;
    int64_t duration_us;
    CVPixelBufferRef video_buffer;
    uint8_t *audio_data;
    int audio_byte_count;
    int audio_sample_count;
    int audio_sample_rate;
    int audio_channel_count;
    char *subtitle_text;
    int subtitle_text_length;
} PPFFSample;

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
PPFF_API int ppff_session_prepare_decoders(
    PPFFSession *session,
    PPFFDecodeConfiguration configuration,
    PPFFError *error
);
PPFF_API int ppff_session_video_decoder_status(
    const PPFFSession *session,
    PPFFDecoderStatus *status,
    PPFFError *error
);
PPFF_API int ppff_session_read_next(
    PPFFSession *session,
    PPFFSample *sample,
    PPFFError *error
);
PPFF_API int ppff_session_seek(
    PPFFSession *session,
    int64_t presentation_time_us,
    PPFFError *error
);
PPFF_API int ppff_session_select_audio(
    PPFFSession *session,
    int stream_index,
    int64_t presentation_time_us,
    PPFFError *error
);
PPFF_API int ppff_session_select_subtitle(
    PPFFSession *session,
    int stream_index,
    PPFFError *error
);
PPFF_API void ppff_sample_release(PPFFSample *sample);
PPFF_API void ppff_session_close(PPFFSession **session);

#if defined(__cplusplus)
}
#endif

#endif
