#include "PierFFmpegInternal.h"

#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <limits.h>
#include <stdlib.h>

static const int ppff_output_sample_rate = 48000;
static const int ppff_output_channel_count = 2;

int ppff_audio_decoder_open(PPFFSession *session, PPFFError *error) {
    if (session->default_audio_stream < 0) {
        return 0;
    }

    AVStream *stream = session->format_context->streams[session->default_audio_stream];
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (codec == NULL) {
        ppff_error_set(error, AVERROR_DECODER_NOT_FOUND, "find audio decoder");
        return AVERROR_DECODER_NOT_FOUND;
    }

    session->audio_decoder = avcodec_alloc_context3(codec);
    if (session->audio_decoder == NULL) {
        ppff_error_set(error, AVERROR(ENOMEM), "allocate audio decoder");
        return AVERROR(ENOMEM);
    }
    int result = avcodec_parameters_to_context(session->audio_decoder, stream->codecpar);
    if (result < 0) {
        ppff_error_set(error, result, "configure audio decoder");
        return result;
    }
    session->audio_decoder->pkt_timebase = stream->time_base;
    result = avcodec_open2(session->audio_decoder, codec, NULL);
    if (result < 0) {
        ppff_error_set(error, result, "open audio decoder");
        return result;
    }

    AVChannelLayout input_layout = session->audio_decoder->ch_layout;
    AVChannelLayout fallback_input_layout = {0};
    if (input_layout.nb_channels <= 0) {
        av_channel_layout_default(
            &fallback_input_layout,
            stream->codecpar->ch_layout.nb_channels > 0
                ? stream->codecpar->ch_layout.nb_channels
                : 2
        );
        input_layout = fallback_input_layout;
    }
    AVChannelLayout output_layout;
    av_channel_layout_default(&output_layout, ppff_output_channel_count);
    result = swr_alloc_set_opts2(
        &session->resample_context,
        &output_layout,
        AV_SAMPLE_FMT_FLT,
        ppff_output_sample_rate,
        &input_layout,
        session->audio_decoder->sample_fmt,
        session->audio_decoder->sample_rate,
        0,
        NULL
    );
    av_channel_layout_uninit(&output_layout);
    av_channel_layout_uninit(&fallback_input_layout);
    if (result < 0 || session->resample_context == NULL) {
        ppff_error_set(error, result < 0 ? result : AVERROR(ENOMEM), "configure audio resampler");
        return result < 0 ? result : AVERROR(ENOMEM);
    }
    result = swr_init(session->resample_context);
    if (result < 0) {
        ppff_error_set(error, result, "open audio resampler");
        return result;
    }
    return 0;
}

int ppff_audio_receive(PPFFSession *session, PPFFSample *sample, PPFFError *error) {
    if (session->audio_decoder == NULL || session->audio_drained) {
        return AVERROR(EAGAIN);
    }
    av_frame_unref(session->audio_frame);
    int result = avcodec_receive_frame(session->audio_decoder, session->audio_frame);
    if (result == AVERROR_EOF) {
        session->audio_drained = 1;
        return result;
    }
    if (result < 0) {
        if (result != AVERROR(EAGAIN)) {
            ppff_error_set(error, result, "decode audio frame");
        }
        return result;
    }

    int input_rate = session->audio_decoder->sample_rate;
    int maximum_samples = (int)av_rescale_rnd(
        swr_get_delay(session->resample_context, input_rate) + session->audio_frame->nb_samples,
        ppff_output_sample_rate,
        input_rate,
        AV_ROUND_UP
    );
    if (maximum_samples <= 0) {
        return AVERROR(EAGAIN);
    }
    int maximum_bytes = av_samples_get_buffer_size(
        NULL,
        ppff_output_channel_count,
        maximum_samples,
        AV_SAMPLE_FMT_FLT,
        1
    );
    if (maximum_bytes < 0) {
        ppff_error_set(error, maximum_bytes, "size audio sample");
        return maximum_bytes;
    }
    uint8_t *audio_data = malloc((size_t)maximum_bytes);
    if (audio_data == NULL) {
        ppff_error_set(error, AVERROR(ENOMEM), "allocate audio sample");
        return AVERROR(ENOMEM);
    }

    uint8_t *output_planes[1] = {audio_data};
    int converted_samples = swr_convert(
        session->resample_context,
        output_planes,
        maximum_samples,
        (const uint8_t **)session->audio_frame->extended_data,
        session->audio_frame->nb_samples
    );
    if (converted_samples < 0) {
        free(audio_data);
        ppff_error_set(error, converted_samples, "resample audio frame");
        return converted_samples;
    }
    if (converted_samples == 0) {
        free(audio_data);
        return AVERROR(EAGAIN);
    }

    int audio_byte_count = av_samples_get_buffer_size(
        NULL,
        ppff_output_channel_count,
        converted_samples,
        AV_SAMPLE_FMT_FLT,
        1
    );
    AVStream *stream = session->format_context->streams[session->default_audio_stream];
    int64_t frame_timestamp = session->audio_frame->best_effort_timestamp;
    if (frame_timestamp == AV_NOPTS_VALUE) {
        frame_timestamp = session->audio_frame->pts;
    }
    int64_t presentation_time_us;
    if (session->next_audio_pts_us != AV_NOPTS_VALUE) {
        presentation_time_us = session->next_audio_pts_us;
    } else if (frame_timestamp != AV_NOPTS_VALUE) {
        presentation_time_us = av_rescale_q(frame_timestamp, stream->time_base, AV_TIME_BASE_Q);
    } else {
        presentation_time_us = 0;
    }
    int64_t duration_us = av_rescale_q(
        converted_samples,
        (AVRational){1, ppff_output_sample_rate},
        AV_TIME_BASE_Q
    );
    session->next_audio_pts_us = presentation_time_us + duration_us;

    sample->kind = PPFF_SAMPLE_KIND_AUDIO;
    sample->stream_index = session->default_audio_stream;
    sample->presentation_time_us = presentation_time_us;
    sample->duration_us = duration_us > 0 ? duration_us : 1;
    sample->audio_data = audio_data;
    sample->audio_byte_count = audio_byte_count;
    sample->audio_sample_count = converted_samples;
    sample->audio_sample_rate = ppff_output_sample_rate;
    sample->audio_channel_count = ppff_output_channel_count;
    return 1;
}
