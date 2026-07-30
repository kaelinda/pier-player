#ifndef PIER_FFMPEG_INTERNAL_H
#define PIER_FFMPEG_INTERNAL_H

#include "PierFFmpeg.h"

#include <libavformat/avformat.h>

struct PPFFSession {
    PPFFIOCallbacks callbacks;
    AVFormatContext *format_context;
    AVIOContext *avio_context;
    int default_video_stream;
    int default_audio_stream;
    int default_subtitle_stream;
};

void ppff_error_clear(PPFFError *error);
void ppff_error_set(PPFFError *error, int code, const char *context);

#endif
