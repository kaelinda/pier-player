#include "PierFFmpegInternal.h"

#include <libavutil/error.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static int ppff_is_text_subtitle(enum AVCodecID codec_id) {
    switch (codec_id) {
        case AV_CODEC_ID_TEXT:
        case AV_CODEC_ID_SSA:
        case AV_CODEC_ID_MOV_TEXT:
        case AV_CODEC_ID_SUBRIP:
        case AV_CODEC_ID_WEBVTT:
        case AV_CODEC_ID_ASS:
            return 1;
        default:
            return 0;
    }
}

int ppff_subtitle_decoder_open(PPFFSession *session, PPFFError *error) {
    if (session->default_subtitle_stream < 0) {
        return 0;
    }
    AVStream *stream = session->format_context->streams[session->default_subtitle_stream];
    if (!ppff_is_text_subtitle(stream->codecpar->codec_id)) {
        return 0;
    }
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (codec == NULL) {
        return 0;
    }
    session->subtitle_decoder = avcodec_alloc_context3(codec);
    if (session->subtitle_decoder == NULL) {
        ppff_error_set(error, AVERROR(ENOMEM), "allocate subtitle decoder");
        return AVERROR(ENOMEM);
    }
    int result = avcodec_parameters_to_context(session->subtitle_decoder, stream->codecpar);
    if (result < 0) {
        ppff_error_set(error, result, "configure subtitle decoder");
        return result;
    }
    session->subtitle_decoder->pkt_timebase = stream->time_base;
    result = avcodec_open2(session->subtitle_decoder, codec, NULL);
    if (result < 0) {
        avcodec_free_context(&session->subtitle_decoder);
        return 0;
    }
    return 0;
}

static const char *ppff_subtitle_text(const AVSubtitleRect *rectangle) {
    if (rectangle->text != NULL && rectangle->text[0] != '\0') {
        return rectangle->text;
    }
    if (rectangle->ass == NULL || rectangle->ass[0] == '\0') {
        return NULL;
    }

    const char *cursor = rectangle->ass;
    int comma_count = 0;
    while (*cursor != '\0' && comma_count < 8) {
        if (*cursor == ',') {
            comma_count++;
        }
        cursor++;
    }
    return comma_count == 8 ? cursor : rectangle->ass;
}

int ppff_subtitle_decode_packet(
    PPFFSession *session,
    const AVPacket *packet,
    PPFFSample *sample,
    PPFFError *error
) {
    if (session->subtitle_decoder == NULL) {
        return 0;
    }

    AVSubtitle subtitle = {0};
    int got_subtitle = 0;
    int result = avcodec_decode_subtitle2(
        session->subtitle_decoder,
        &subtitle,
        &got_subtitle,
        packet
    );
    if (result < 0) {
        avsubtitle_free(&subtitle);
        ppff_error_clear(error);
        return 0;
    }
    if (!got_subtitle) {
        return 0;
    }

    size_t text_length = 0;
    for (unsigned index = 0; index < subtitle.num_rects; index++) {
        const char *text = ppff_subtitle_text(subtitle.rects[index]);
        if (text != NULL) {
            text_length += strlen(text) + (text_length > 0 ? 1 : 0);
        }
    }
    if (text_length == 0 || text_length > INT_MAX) {
        avsubtitle_free(&subtitle);
        return 0;
    }

    char *owned_text = malloc(text_length + 1);
    if (owned_text == NULL) {
        avsubtitle_free(&subtitle);
        ppff_error_set(error, AVERROR(ENOMEM), "allocate subtitle text");
        return AVERROR(ENOMEM);
    }
    size_t write_offset = 0;
    for (unsigned index = 0; index < subtitle.num_rects; index++) {
        const char *text = ppff_subtitle_text(subtitle.rects[index]);
        if (text == NULL) {
            continue;
        }
        if (write_offset > 0) {
            owned_text[write_offset++] = '\n';
        }
        size_t length = strlen(text);
        memcpy(owned_text + write_offset, text, length);
        write_offset += length;
    }
    owned_text[write_offset] = '\0';

    AVStream *stream = session->format_context->streams[session->default_subtitle_stream];
    int64_t base_time_us;
    if (subtitle.pts != AV_NOPTS_VALUE) {
        base_time_us = subtitle.pts;
    } else if (packet->pts != AV_NOPTS_VALUE) {
        base_time_us = av_rescale_q(packet->pts, stream->time_base, AV_TIME_BASE_Q);
    } else {
        base_time_us = 0;
    }
    int64_t presentation_time_us = base_time_us +
        (int64_t)subtitle.start_display_time * 1000;
    int64_t duration_us = subtitle.end_display_time > subtitle.start_display_time
        ? (int64_t)(subtitle.end_display_time - subtitle.start_display_time) * 1000
        : av_rescale_q(packet->duration, stream->time_base, AV_TIME_BASE_Q);

    sample->kind = PPFF_SAMPLE_KIND_SUBTITLE;
    sample->stream_index = session->default_subtitle_stream;
    sample->presentation_time_us = presentation_time_us;
    sample->duration_us = duration_us > 0 ? duration_us : 1;
    sample->subtitle_text = owned_text;
    sample->subtitle_text_length = (int)write_offset;
    avsubtitle_free(&subtitle);
    return 1;
}
