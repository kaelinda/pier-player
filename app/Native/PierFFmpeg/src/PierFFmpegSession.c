#include "PierFFmpegInternal.h"

#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const int ppff_avio_buffer_size = 32 * 1024;

void ppff_error_clear(PPFFError *error) {
    if (error == NULL) {
        return;
    }
    error->code = 0;
    error->message[0] = '\0';
}

void ppff_error_set(PPFFError *error, int code, const char *context) {
    if (error == NULL) {
        return;
    }

    char detail[128] = {0};
    av_strerror(code, detail, sizeof(detail));
    error->code = code;
    if (context != NULL && context[0] != '\0') {
        snprintf(error->message, sizeof(error->message), "%s: %s", context, detail);
    } else {
        snprintf(error->message, sizeof(error->message), "%s", detail);
    }
}

static void ppff_copy_string(char *destination, size_t capacity, const char *source) {
    if (destination == NULL || capacity == 0) {
        return;
    }
    if (source == NULL) {
        destination[0] = '\0';
        return;
    }
    snprintf(destination, capacity, "%s", source);
}

static int ppff_interrupt(void *opaque) {
    PPFFSession *session = opaque;
    if (session == NULL || session->callbacks.interrupt == NULL) {
        return 0;
    }
    return session->callbacks.interrupt(session->callbacks.opaque);
}

static void ppff_session_destroy(PPFFSession *session) {
    if (session == NULL) {
        return;
    }

    ppff_decode_destroy(session);
    if (session->format_context != NULL) {
        avformat_close_input(&session->format_context);
    }
    if (session->avio_context != NULL) {
        av_freep(&session->avio_context->buffer);
        avio_context_free(&session->avio_context);
    }
    free(session);
}

PPFFSession *ppff_session_open(
    PPFFIOCallbacks callbacks,
    PPFFProbeLimits limits,
    PPFFError *error
) {
    ppff_error_clear(error);
    if (callbacks.read == NULL || callbacks.seek == NULL ||
        limits.maximum_probe_bytes <= 0 || limits.maximum_analyze_duration_us <= 0) {
        ppff_error_set(error, AVERROR(EINVAL), "invalid session arguments");
        return NULL;
    }

    PPFFSession *session = calloc(1, sizeof(PPFFSession));
    if (session == NULL) {
        ppff_error_set(error, AVERROR(ENOMEM), "allocate session");
        return NULL;
    }
    session->callbacks = callbacks;
    session->default_video_stream = -1;
    session->default_audio_stream = -1;
    session->default_subtitle_stream = -1;

    unsigned char *avio_buffer = av_malloc(ppff_avio_buffer_size);
    if (avio_buffer == NULL) {
        ppff_error_set(error, AVERROR(ENOMEM), "allocate AVIO buffer");
        ppff_session_destroy(session);
        return NULL;
    }

    session->avio_context = avio_alloc_context(
        avio_buffer,
        ppff_avio_buffer_size,
        0,
        callbacks.opaque,
        callbacks.read,
        NULL,
        callbacks.seek
    );
    if (session->avio_context == NULL) {
        av_free(avio_buffer);
        ppff_error_set(error, AVERROR(ENOMEM), "create AVIO context");
        ppff_session_destroy(session);
        return NULL;
    }
    session->avio_context->seekable = AVIO_SEEKABLE_NORMAL;

    session->format_context = avformat_alloc_context();
    if (session->format_context == NULL) {
        ppff_error_set(error, AVERROR(ENOMEM), "allocate format context");
        ppff_session_destroy(session);
        return NULL;
    }

    session->format_context->pb = session->avio_context;
    session->format_context->flags |= AVFMT_FLAG_CUSTOM_IO;
    session->format_context->probesize = limits.maximum_probe_bytes;
    session->format_context->max_analyze_duration = limits.maximum_analyze_duration_us;
    session->format_context->interrupt_callback.callback = ppff_interrupt;
    session->format_context->interrupt_callback.opaque = session;

    int result = avformat_open_input(&session->format_context, NULL, NULL, NULL);
    if (result < 0) {
        ppff_error_set(error, result, "open media");
        ppff_session_destroy(session);
        return NULL;
    }

    result = avformat_find_stream_info(session->format_context, NULL);
    if (result < 0) {
        ppff_error_set(error, result, "probe streams");
        ppff_session_destroy(session);
        return NULL;
    }

    session->default_video_stream = av_find_best_stream(
        session->format_context, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0
    );
    session->default_audio_stream = av_find_best_stream(
        session->format_context, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0
    );
    session->default_subtitle_stream = av_find_best_stream(
        session->format_context, AVMEDIA_TYPE_SUBTITLE, -1, -1, NULL, 0
    );
    return session;
}

int ppff_session_media_info(
    const PPFFSession *session,
    PPFFMediaInfo *info,
    PPFFError *error
) {
    ppff_error_clear(error);
    if (session == NULL || session->format_context == NULL || info == NULL) {
        ppff_error_set(error, AVERROR(EINVAL), "read media metadata");
        return AVERROR(EINVAL);
    }

    memset(info, 0, sizeof(PPFFMediaInfo));
    ppff_copy_string(
        info->container_name,
        sizeof(info->container_name),
        session->format_context->iformat != NULL
            ? session->format_context->iformat->name
            : NULL
    );
    info->duration_us = session->format_context->duration == AV_NOPTS_VALUE
        ? 0
        : session->format_context->duration;
    info->is_seekable = session->avio_context != NULL &&
        (session->avio_context->seekable & AVIO_SEEKABLE_NORMAL) != 0;
    return 0;
}

int ppff_session_stream_count(const PPFFSession *session) {
    if (session == NULL || session->format_context == NULL) {
        return 0;
    }
    return (int)session->format_context->nb_streams;
}

int ppff_session_stream_info(
    const PPFFSession *session,
    int index,
    PPFFStreamInfo *info,
    PPFFError *error
) {
    ppff_error_clear(error);
    if (session == NULL || session->format_context == NULL || info == NULL ||
        index < 0 || index >= (int)session->format_context->nb_streams) {
        ppff_error_set(error, AVERROR(EINVAL), "read stream metadata");
        return AVERROR(EINVAL);
    }

    AVStream *stream = session->format_context->streams[index];
    AVCodecParameters *parameters = stream->codecpar;
    memset(info, 0, sizeof(PPFFStreamInfo));
    info->index = index;
    info->codec_id = parameters->codec_id;
    ppff_copy_string(info->codec_name, sizeof(info->codec_name), avcodec_get_name(parameters->codec_id));

    switch (parameters->codec_type) {
        case AVMEDIA_TYPE_VIDEO:
            info->kind = PPFF_MEDIA_KIND_VIDEO;
            info->width = parameters->width;
            info->height = parameters->height;
            info->is_default = index == session->default_video_stream;
            break;
        case AVMEDIA_TYPE_AUDIO:
            info->kind = PPFF_MEDIA_KIND_AUDIO;
            info->sample_rate = parameters->sample_rate;
            info->channel_count = parameters->ch_layout.nb_channels;
            info->is_default = index == session->default_audio_stream;
            break;
        case AVMEDIA_TYPE_SUBTITLE:
            info->kind = PPFF_MEDIA_KIND_SUBTITLE;
            info->is_default = index == session->default_subtitle_stream;
            break;
        default:
            info->kind = PPFF_MEDIA_KIND_UNKNOWN;
            break;
    }

    const AVDictionaryEntry *language = av_dict_get(stream->metadata, "language", NULL, 0);
    const AVDictionaryEntry *title = av_dict_get(stream->metadata, "title", NULL, 0);
    ppff_copy_string(
        info->language,
        sizeof(info->language),
        language != NULL ? language->value : NULL
    );
    ppff_copy_string(
        info->title,
        sizeof(info->title),
        title != NULL ? title->value : NULL
    );
    return 0;
}

void ppff_session_close(PPFFSession **session) {
    if (session == NULL || *session == NULL) {
        return;
    }
    ppff_session_destroy(*session);
    *session = NULL;
}
