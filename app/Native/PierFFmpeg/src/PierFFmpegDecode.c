#include "PierFFmpegInternal.h"

#include <libavutil/error.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

enum {
    PPFF_MAX_CONSECUTIVE_CORRUPT_PACKETS = 8
};

static int *ppff_corrupt_packet_counter(
    PPFFSession *session,
    const AVCodecContext *decoder
) {
    if (decoder == session->video_decoder) {
        return &session->consecutive_video_corrupt_packets;
    }
    return &session->consecutive_audio_corrupt_packets;
}

static int ppff_skip_corrupt_packet(
    PPFFSession *session,
    AVCodecContext *decoder,
    PPFFError *error
) {
    int *counter = ppff_corrupt_packet_counter(session, decoder);
    *counter += 1;
    if (*counter > PPFF_MAX_CONSECUTIVE_CORRUPT_PACKETS) {
        ppff_error_set(error, AVERROR_INVALIDDATA, "decode corrupt media");
        return AVERROR_INVALIDDATA;
    }
    return 0;
}

static void ppff_record_decode_progress(
    PPFFSession *session,
    PPFFSampleKind kind
) {
    if (kind == PPFF_SAMPLE_KIND_VIDEO) {
        session->consecutive_video_corrupt_packets = 0;
    } else if (kind == PPFF_SAMPLE_KIND_AUDIO) {
        session->consecutive_audio_corrupt_packets = 0;
    }
}

void ppff_decode_destroy(PPFFSession *session) {
    if (session == NULL) {
        return;
    }
    av_packet_free(&session->packet);
    av_frame_free(&session->video_frame);
    av_frame_free(&session->audio_frame);
    avcodec_free_context(&session->video_decoder);
    avcodec_free_context(&session->audio_decoder);
    avcodec_free_context(&session->subtitle_decoder);
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
    session->seek_target_us = AV_NOPTS_VALUE;
    session->consecutive_video_corrupt_packets = 0;
    session->consecutive_audio_corrupt_packets = 0;
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
    result = ppff_subtitle_decoder_open(session, error);
    if (result < 0) {
        ppff_decode_destroy(session);
        return result;
    }
    session->decode_prepared = 1;
    return 0;
}

static void ppff_reset_after_seek(PPFFSession *session, int64_t target_us) {
    if (session->video_decoder != NULL) {
        avcodec_flush_buffers(session->video_decoder);
    }
    if (session->audio_decoder != NULL) {
        avcodec_flush_buffers(session->audio_decoder);
    }
    if (session->subtitle_decoder != NULL) {
        avcodec_flush_buffers(session->subtitle_decoder);
    }
    if (session->resample_context != NULL) {
        swr_close(session->resample_context);
        swr_init(session->resample_context);
    }
    av_packet_unref(session->packet);
    av_frame_unref(session->video_frame);
    av_frame_unref(session->audio_frame);
    session->demux_eof = 0;
    session->video_drain_sent = 0;
    session->audio_drain_sent = 0;
    session->video_drained = 0;
    session->audio_drained = 0;
    session->last_video_pts_us = INT64_MIN;
    session->next_audio_pts_us = AV_NOPTS_VALUE;
    session->seek_target_us = target_us;
    session->seek_in_progress = 1;
    session->video_seek_ready = session->video_decoder == NULL;
    session->audio_seek_ready = session->audio_decoder == NULL;
    session->consecutive_video_corrupt_packets = 0;
    session->consecutive_audio_corrupt_packets = 0;
}

int ppff_session_seek(
    PPFFSession *session,
    int64_t presentation_time_us,
    PPFFError *error
) {
    ppff_error_clear(error);
    if (session == NULL || !session->decode_prepared || presentation_time_us < 0) {
        ppff_error_set(error, AVERROR(EINVAL), "seek media");
        return AVERROR(EINVAL);
    }
    int result = avformat_seek_file(
        session->format_context,
        -1,
        INT64_MIN,
        presentation_time_us,
        presentation_time_us,
        AVSEEK_FLAG_BACKWARD
    );
    if (result < 0) {
        ppff_error_set(error, result, "seek media");
        return result;
    }
    ppff_reset_after_seek(session, presentation_time_us);
    return 0;
}

int ppff_session_select_audio(
    PPFFSession *session,
    int stream_index,
    int64_t presentation_time_us,
    PPFFError *error
) {
    ppff_error_clear(error);
    if (session == NULL || !session->decode_prepared || stream_index < 0 ||
        stream_index >= (int)session->format_context->nb_streams ||
        session->format_context->streams[stream_index]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
        ppff_error_set(error, AVERROR(EINVAL), "select audio stream");
        return AVERROR(EINVAL);
    }

    if (stream_index != session->default_audio_stream) {
        int previous_stream = session->default_audio_stream;
        avcodec_free_context(&session->audio_decoder);
        swr_free(&session->resample_context);
        session->default_audio_stream = stream_index;

        int result = ppff_audio_decoder_open(session, error);
        if (result < 0) {
            PPFFError selection_error = error != NULL ? *error : (PPFFError){0};
            avcodec_free_context(&session->audio_decoder);
            swr_free(&session->resample_context);
            session->default_audio_stream = previous_stream;
            PPFFError recovery_error;
            ppff_audio_decoder_open(session, &recovery_error);
            if (error != NULL) {
                *error = selection_error;
            }
            return result;
        }
    }
    return ppff_session_seek(session, presentation_time_us, error);
}

int ppff_session_select_subtitle(
    PPFFSession *session,
    int stream_index,
    PPFFError *error
) {
    ppff_error_clear(error);
    if (session == NULL || stream_index < -1 ||
        stream_index >= (int)session->format_context->nb_streams ||
        (stream_index >= 0 &&
         session->format_context->streams[stream_index]->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE)) {
        ppff_error_set(error, AVERROR(EINVAL), "select subtitle stream");
        return AVERROR(EINVAL);
    }
    if (stream_index == session->default_subtitle_stream) {
        return 0;
    }

    int previous_stream = session->default_subtitle_stream;
    avcodec_free_context(&session->subtitle_decoder);
    session->default_subtitle_stream = stream_index;
    int result = ppff_subtitle_decoder_open(session, error);
    if (result < 0) {
        PPFFError selection_error = error != NULL ? *error : (PPFFError){0};
        avcodec_free_context(&session->subtitle_decoder);
        session->default_subtitle_stream = previous_stream;
        PPFFError recovery_error;
        ppff_subtitle_decoder_open(session, &recovery_error);
        if (error != NULL) {
            *error = selection_error;
        }
        return result;
    }
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
            ppff_record_decode_progress(session, sample->kind);
            if (session->seek_in_progress &&
                sample->presentation_time_us < session->seek_target_us) {
                ppff_sample_release(sample);
                continue;
            }
            session->video_seek_ready = 1;
            if (session->video_seek_ready && session->audio_seek_ready) {
                session->seek_in_progress = 0;
            }
            return video_result;
        }
        if (video_result < 0 &&
            video_result != AVERROR(EAGAIN) &&
            video_result != AVERROR_EOF) {
            if (video_result == AVERROR_INVALIDDATA) {
                int corrupt_result = ppff_skip_corrupt_packet(
                    session,
                    session->video_decoder,
                    error
                );
                if (corrupt_result >= 0) {
                    continue;
                }
                return corrupt_result;
            }
            if (session->video_decoder_mode == PPFF_DECODER_MODE_VIDEOTOOLBOX &&
                session->software_fallback_count == 0) {
                int fallback_result = ppff_video_decoder_fallback_to_software(session, error);
                if (fallback_result >= 0) {
                    continue;
                }
                return fallback_result;
            }
            return video_result;
        }

        int audio_result = ppff_audio_receive(session, sample, error);
        if (audio_result > 0) {
            ppff_record_decode_progress(session, sample->kind);
            if (session->seek_in_progress &&
                sample->presentation_time_us < session->seek_target_us) {
                ppff_sample_release(sample);
                continue;
            }
            session->audio_seek_ready = 1;
            if (session->video_seek_ready && session->audio_seek_ready) {
                session->seek_in_progress = 0;
            }
            return audio_result;
        }
        if (audio_result < 0 &&
            audio_result != AVERROR(EAGAIN) &&
            audio_result != AVERROR_EOF) {
            if (audio_result == AVERROR_INVALIDDATA) {
                int corrupt_result = ppff_skip_corrupt_packet(
                    session,
                    session->audio_decoder,
                    error
                );
                if (corrupt_result >= 0) {
                    continue;
                }
                return corrupt_result;
            }
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
        } else if (session->packet->stream_index == session->default_subtitle_stream) {
            int subtitle_result = ppff_subtitle_decode_packet(
                session,
                session->packet,
                sample,
                error
            );
            av_packet_unref(session->packet);
            if (subtitle_result < 0) {
                return subtitle_result;
            }
            if (subtitle_result > 0) {
                if (session->seek_in_progress &&
                    sample->presentation_time_us < session->seek_target_us) {
                    ppff_sample_release(sample);
                    continue;
                }
                return subtitle_result;
            }
        }
        if (decoder == NULL) {
            continue;
        }

        if ((session->packet->flags & AV_PKT_FLAG_CORRUPT) != 0) {
            int corrupt_result = ppff_skip_corrupt_packet(session, decoder, error);
            av_packet_unref(session->packet);
            if (corrupt_result < 0) {
                return corrupt_result;
            }
            continue;
        }

        int send_result = avcodec_send_packet(decoder, session->packet);
        av_packet_unref(session->packet);
        if (send_result < 0 && send_result != AVERROR(EAGAIN)) {
            if (send_result == AVERROR_INVALIDDATA) {
                int corrupt_result = ppff_skip_corrupt_packet(session, decoder, error);
                if (corrupt_result >= 0) {
                    continue;
                }
                return corrupt_result;
            }
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
    free(sample->subtitle_text);
    memset(sample, 0, sizeof(PPFFSample));
}
