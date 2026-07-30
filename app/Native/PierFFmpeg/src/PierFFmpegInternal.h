#ifndef PIER_FFMPEG_INTERNAL_H
#define PIER_FFMPEG_INTERNAL_H

#include "PierFFmpeg.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

struct PPFFSession {
    PPFFIOCallbacks callbacks;
    AVFormatContext *format_context;
    AVIOContext *avio_context;
    int default_video_stream;
    int default_audio_stream;
    int default_subtitle_stream;
    AVCodecContext *video_decoder;
    AVCodecContext *audio_decoder;
    AVCodecContext *subtitle_decoder;
    AVBufferRef *hardware_device_context;
    enum AVPixelFormat hardware_pixel_format;
    struct SwsContext *scale_context;
    SwrContext *resample_context;
    AVPacket *packet;
    AVFrame *video_frame;
    AVFrame *audio_frame;
    PPFFDecoderMode video_decoder_mode;
    int hardware_attempted;
    int software_fallback_count;
    int force_hardware_decode_failure;
    int hardware_decode_failure_injected;
    int decode_prepared;
    int demux_eof;
    int video_drain_sent;
    int audio_drain_sent;
    int video_drained;
    int audio_drained;
    int64_t last_video_pts_us;
    int64_t next_audio_pts_us;
    int64_t seek_target_us;
    int seek_in_progress;
    int video_seek_ready;
    int audio_seek_ready;
};

void ppff_error_clear(PPFFError *error);
void ppff_error_set(PPFFError *error, int code, const char *context);
void ppff_decode_destroy(PPFFSession *session);
int ppff_video_decoder_open(
    PPFFSession *session,
    PPFFDecodeConfiguration configuration,
    PPFFError *error
);
int ppff_video_decoder_fallback_to_software(PPFFSession *session, PPFFError *error);
int ppff_audio_decoder_open(PPFFSession *session, PPFFError *error);
int ppff_subtitle_decoder_open(PPFFSession *session, PPFFError *error);
int ppff_video_receive(PPFFSession *session, PPFFSample *sample, PPFFError *error);
int ppff_audio_receive(PPFFSession *session, PPFFSample *sample, PPFFError *error);
int ppff_subtitle_decode_packet(
    PPFFSession *session,
    const AVPacket *packet,
    PPFFSample *sample,
    PPFFError *error
);

#endif
