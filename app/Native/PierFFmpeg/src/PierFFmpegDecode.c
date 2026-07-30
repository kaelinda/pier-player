#include "PierFFmpegInternal.h"

#include <libavutil/error.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

void ppff_decode_destroy(PPFFSession *session) {
    if (session == NULL) {
        return;
    }
    av_packet_free(&session->packet);
    av_frame_free(&session->video_frame);
    av_frame_free(&session->audio_frame);
    avcodec_free_context(&session->video_decoder);
    avcodec_free_context(&session->audio_decoder);
    av_buffer_unref(&session->hardware_device_context);
    sws_freeContext(session->scale_context);
    session->scale_context = NULL;
    swr_free(&session->resample_context);
    session->decode_prepared = 0;
}

int ppff_session_prepare_decoders(
    PPFFSession *session,
    PPFFDecodeConfiguration configuration,
    PPFFError *error
) {
    ppff_error_clear(error);
    if (session == NULL || session->format_context == NULL || session->decode_prepared) {
        ppff_error_set(error, AVERROR(EINVAL), "prepare decoders");
        return AVERROR(EINVAL);
    }
    if (session->default_video_stream < 0 && session->default_audio_stream < 0) {
        ppff_error_set(error, AVERROR_STREAM_NOT_FOUND, "find playable streams");
        return AVERROR_STREAM_NOT_FOUND;
    }

    session->packet = av_packet_alloc();
    session->video_frame = av_frame_alloc();
    session->audio_frame = av_frame_alloc();
    if (session->packet == NULL || session->video_frame == NULL || session->audio_frame == NULL) {
        ppff_error_set(error, AVERROR(ENOMEM), "allocate decode buffers");
        ppff_decode_destroy(session);
        return AVERROR(ENOMEM);
    }

    session->last_video_pts_us = INT64_MIN;
    session->next_audio_pts_us = AV_NOPTS_VALUE;
    int result = ppff_video_decoder_open(session, configuration, error);
    if (result < 0) {
        ppff_decode_destroy(session);
        return result;
    }
    result = ppff_audio_decoder_open(session, error);
    if (result < 0) {
        ppff_decode_destroy(session);
        return result;
    }
    session->decode_prepared = 1;
    return 0;
}

int ppff_session_video_decoder_status(
    const PPFFSession *session,
    PPFFDecoderStatus *status,
    PPFFError *error
) {
    ppff_error_clear(error);
    if (session == NULL || status == NULL || !session->decode_prepared) {
        ppff_error_set(error, AVERROR(EINVAL), "read video decoder status");
        return AVERROR(EINVAL);
    }
    memset(status, 0, sizeof(PPFFDecoderStatus));
    status->mode = session->video_decoder_mode;
    status->hardware_attempted = session->hardware_attempted;
    status->software_fallback_count = session->software_fallback_count;
    return 0;
}

static int ppff_send_drain_packets(PPFFSession *session, PPFFError *error) {
    if (session->video_decoder != NULL && !session->video_drain_sent) {
        int result = avcodec_send_packet(session->video_decoder, NULL);
        if (result < 0 && result != AVERROR_EOF) {
            ppff_error_set(error, result, "drain video decoder");
            return result;
        }
        session->video_drain_sent = 1;
    }
    if (session->audio_decoder != NULL && !session->audio_drain_sent) {
        int result = avcodec_send_packet(session->audio_decoder, NULL);
        if (result < 0 && result != AVERROR_EOF) {
            ppff_error_set(error, result, "drain audio decoder");
            return result;
        }
        session->audio_drain_sent = 1;
    }
    return 0;
}

int ppff_session_read_next(
    PPFFSession *session,
    PPFFSample *sample,
    PPFFError *error
) {
    ppff_error_clear(error);
    if (sample != NULL) {
        memset(sample, 0, sizeof(PPFFSample));
    }
    if (session == NULL || sample == NULL || !session->decode_prepared) {
        ppff_error_set(error, AVERROR(EINVAL), "read decoded sample");
        return AVERROR(EINVAL);
    }

    while (1) {
        int video_result = ppff_video_receive(session, sample, error);
        if (video_result > 0) {
            return video_result;
        }
        if (video_result < 0 &&
            video_result != AVERROR(EAGAIN) &&
            video_result != AVERROR_EOF) {
            return video_result;
        }

        int audio_result = ppff_audio_receive(session, sample, error);
        if (audio_result > 0) {
            return audio_result;
        }
        if (audio_result < 0 &&
            audio_result != AVERROR(EAGAIN) &&
            audio_result != AVERROR_EOF) {
            return audio_result;
        }

        if (session->demux_eof) {
            int drain_result = ppff_send_drain_packets(session, error);
            if (drain_result < 0) {
                return drain_result;
            }
            int video_complete = session->video_decoder == NULL || session->video_drained;
            int audio_complete = session->audio_decoder == NULL || session->audio_drained;
            if (video_complete && audio_complete) {
                return 0;
            }
            continue;
        }

        av_packet_unref(session->packet);
        int read_result = av_read_frame(session->format_context, session->packet);
        if (read_result == AVERROR_EOF) {
            session->demux_eof = 1;
            continue;
        }
        if (read_result < 0) {
            ppff_error_set(error, read_result, "read media packet");
            return read_result;
        }

        AVCodecContext *decoder = NULL;
        if (session->packet->stream_index == session->default_video_stream) {
            decoder = session->video_decoder;
        } else if (session->packet->stream_index == session->default_audio_stream) {
            decoder = session->audio_decoder;
        }
        if (decoder == NULL) {
            continue;
        }

        int send_result = avcodec_send_packet(decoder, session->packet);
        av_packet_unref(session->packet);
        if (send_result < 0 && send_result != AVERROR(EAGAIN)) {
            ppff_error_set(error, send_result, "submit media packet");
            return send_result;
        }
    }
}

void ppff_sample_release(PPFFSample *sample) {
    if (sample == NULL) {
        return;
    }
    if (sample->video_buffer != NULL) {
        CVPixelBufferRelease(sample->video_buffer);
    }
    free(sample->audio_data);
    memset(sample, 0, sizeof(PPFFSample));
}
