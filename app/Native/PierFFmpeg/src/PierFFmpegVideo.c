#include "PierFFmpegInternal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <libavutil/error.h>
#include <libavutil/imgutils.h>
#include <limits.h>

static enum AVPixelFormat ppff_hardware_format(
    AVCodecContext *codec_context,
    const enum AVPixelFormat *formats
) {
    PPFFSession *session = codec_context->opaque;
    if (session == NULL) {
        return AV_PIX_FMT_NONE;
    }
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        if (*format == session->hardware_pixel_format) {
            return *format;
        }
    }
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        if (*format != session->hardware_pixel_format) {
            session->video_decoder_mode = PPFF_DECODER_MODE_SOFTWARE;
            session->software_fallback_count = 1;
            return *format;
        }
    }
    return AV_PIX_FMT_NONE;
}

static void ppff_video_decoder_reset(PPFFSession *session) {
    avcodec_free_context(&session->video_decoder);
    av_buffer_unref(&session->hardware_device_context);
    session->hardware_pixel_format = AV_PIX_FMT_NONE;
}

static int ppff_codec_can_use_videotoolbox(enum AVCodecID codec_id) {
    switch (codec_id) {
        case AV_CODEC_ID_H264:
        case AV_CODEC_ID_HEVC:
        case AV_CODEC_ID_VP9:
        case AV_CODEC_ID_AV1:
            return 1;
        default:
            return 0;
    }
}

static int ppff_video_decoder_allocate(PPFFSession *session, const AVCodec *codec) {
    AVStream *stream = session->format_context->streams[session->default_video_stream];
    session->video_decoder = avcodec_alloc_context3(codec);
    if (session->video_decoder == NULL) {
        return AVERROR(ENOMEM);
    }
    int result = avcodec_parameters_to_context(session->video_decoder, stream->codecpar);
    if (result < 0) {
        return result;
    }
    session->video_decoder->pkt_timebase = stream->time_base;
    return 0;
}

int ppff_video_decoder_open(
    PPFFSession *session,
    PPFFDecodeConfiguration configuration,
    PPFFError *error
) {
    if (session->default_video_stream < 0) {
        return 0;
    }

    AVStream *stream = session->format_context->streams[session->default_video_stream];
    session->force_hardware_decode_failure = configuration.force_hardware_decode_failure;
    session->hardware_decode_failure_injected = 0;
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (codec == NULL) {
        ppff_error_set(error, AVERROR_DECODER_NOT_FOUND, "find video decoder");
        return AVERROR_DECODER_NOT_FOUND;
    }

    int result = ppff_video_decoder_allocate(session, codec);
    if (result < 0) {
        ppff_error_set(error, result, "configure video decoder");
        ppff_video_decoder_reset(session);
        return result;
    }

    const AVCodecHWConfig *hardware_configuration = NULL;
    if (configuration.prefer_hardware &&
        ppff_codec_can_use_videotoolbox(stream->codecpar->codec_id)) {
        for (int index = 0; ; index++) {
            const AVCodecHWConfig *candidate = avcodec_get_hw_config(codec, index);
            if (candidate == NULL) {
                break;
            }
            if ((candidate->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 &&
                candidate->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
                hardware_configuration = candidate;
                break;
            }
        }
    }

    if (hardware_configuration != NULL) {
        session->hardware_attempted = 1;
        session->hardware_pixel_format = hardware_configuration->pix_fmt;
        if (!configuration.force_hardware_open_failure) {
            result = av_hwdevice_ctx_create(
                &session->hardware_device_context,
                AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                NULL,
                NULL,
                0
            );
            if (result >= 0) {
                session->video_decoder->opaque = session;
                session->video_decoder->get_format = ppff_hardware_format;
                session->video_decoder->hw_device_ctx = av_buffer_ref(
                    session->hardware_device_context
                );
                if (session->video_decoder->hw_device_ctx == NULL) {
                    result = AVERROR(ENOMEM);
                } else {
                    result = avcodec_open2(session->video_decoder, codec, NULL);
                }
            }
        } else {
            result = AVERROR_EXTERNAL;
        }

        if (result >= 0) {
            session->video_decoder_mode = PPFF_DECODER_MODE_VIDEOTOOLBOX;
            return 0;
        }

        session->software_fallback_count = 1;
        ppff_video_decoder_reset(session);
        result = ppff_video_decoder_allocate(session, codec);
        if (result < 0) {
            ppff_error_set(error, result, "configure software video decoder");
            ppff_video_decoder_reset(session);
            return result;
        }
    }

    result = avcodec_open2(session->video_decoder, codec, NULL);
    if (result < 0) {
        ppff_error_set(error, result, "open software video decoder");
        ppff_video_decoder_reset(session);
        return result;
    }
    session->video_decoder_mode = PPFF_DECODER_MODE_SOFTWARE;
    return 0;
}

int ppff_video_decoder_fallback_to_software(PPFFSession *session, PPFFError *error) {
    if (session == NULL || session->video_decoder_mode != PPFF_DECODER_MODE_VIDEOTOOLBOX ||
        session->software_fallback_count != 0 || session->default_video_stream < 0) {
        ppff_error_set(error, AVERROR(EINVAL), "fallback video decoder");
        return AVERROR(EINVAL);
    }

    AVStream *stream = session->format_context->streams[session->default_video_stream];
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (codec == NULL) {
        ppff_error_set(error, AVERROR_DECODER_NOT_FOUND, "find software video decoder");
        return AVERROR_DECODER_NOT_FOUND;
    }
    int64_t resume_time_us = session->last_video_pts_us == INT64_MIN
        ? 0
        : session->last_video_pts_us;

    ppff_video_decoder_reset(session);
    int result = ppff_video_decoder_allocate(session, codec);
    if (result >= 0) {
        result = avcodec_open2(session->video_decoder, codec, NULL);
    }
    if (result < 0) {
        ppff_error_set(error, result, "open fallback video decoder");
        ppff_video_decoder_reset(session);
        return result;
    }

    session->video_decoder_mode = PPFF_DECODER_MODE_SOFTWARE;
    session->software_fallback_count = 1;
    return ppff_session_seek(session, resume_time_us, error);
}

static int64_t ppff_video_duration_us(PPFFSession *session, AVFrame *frame) {
    AVStream *stream = session->format_context->streams[session->default_video_stream];
    if (frame->duration > 0) {
        return av_rescale_q(frame->duration, stream->time_base, AV_TIME_BASE_Q);
    }
    AVRational frame_rate = av_guess_frame_rate(session->format_context, stream, frame);
    if (frame_rate.num > 0 && frame_rate.den > 0) {
        return av_rescale_q(1, av_inv_q(frame_rate), AV_TIME_BASE_Q);
    }
    return 1;
}

static void ppff_copy_video_color(CVPixelBufferRef pixel_buffer, const AVFrame *frame) {
    CFStringRef primaries = NULL;
    if (frame->color_primaries == AVCOL_PRI_BT709) {
        primaries = kCVImageBufferColorPrimaries_ITU_R_709_2;
    } else if (frame->color_primaries == AVCOL_PRI_BT2020) {
        primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
    }
    if (primaries != NULL) {
        CVBufferSetAttachment(
            pixel_buffer,
            kCVImageBufferColorPrimariesKey,
            primaries,
            kCVAttachmentMode_ShouldPropagate
        );
    }

    CFStringRef transfer = NULL;
    if (frame->color_trc == AVCOL_TRC_BT709) {
        transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
    } else if (frame->color_trc == AVCOL_TRC_SMPTE2084) {
        transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
    } else if (frame->color_trc == AVCOL_TRC_ARIB_STD_B67) {
        transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG;
    }
    if (transfer != NULL) {
        CVBufferSetAttachment(
            pixel_buffer,
            kCVImageBufferTransferFunctionKey,
            transfer,
            kCVAttachmentMode_ShouldPropagate
        );
    }

    CFStringRef matrix = NULL;
    if (frame->colorspace == AVCOL_SPC_BT709) {
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    } else if (frame->colorspace == AVCOL_SPC_BT2020_NCL) {
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
    }
    if (matrix != NULL) {
        CVBufferSetAttachment(
            pixel_buffer,
            kCVImageBufferYCbCrMatrixKey,
            matrix,
            kCVAttachmentMode_ShouldPropagate
        );
    }
}

static int ppff_software_pixel_buffer(
    PPFFSession *session,
    const AVFrame *frame,
    CVPixelBufferRef *pixel_buffer
) {
    CVReturn result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        frame->width,
        frame->height,
        kCVPixelFormatType_32BGRA,
        NULL,
        pixel_buffer
    );
    if (result != kCVReturnSuccess) {
        return AVERROR_EXTERNAL;
    }

    result = CVPixelBufferLockBaseAddress(*pixel_buffer, 0);
    if (result != kCVReturnSuccess) {
        CVPixelBufferRelease(*pixel_buffer);
        *pixel_buffer = NULL;
        return AVERROR_EXTERNAL;
    }

    session->scale_context = sws_getCachedContext(
        session->scale_context,
        frame->width,
        frame->height,
        frame->format,
        frame->width,
        frame->height,
        AV_PIX_FMT_BGRA,
        SWS_BILINEAR,
        NULL,
        NULL,
        NULL
    );
    if (session->scale_context == NULL) {
        CVPixelBufferUnlockBaseAddress(*pixel_buffer, 0);
        CVPixelBufferRelease(*pixel_buffer);
        *pixel_buffer = NULL;
        return AVERROR(ENOMEM);
    }

    uint8_t *destination_data[4] = {
        CVPixelBufferGetBaseAddress(*pixel_buffer), NULL, NULL, NULL
    };
    int destination_linesize[4] = {
        (int)CVPixelBufferGetBytesPerRow(*pixel_buffer), 0, 0, 0
    };
    int converted_height = sws_scale(
        session->scale_context,
        (const uint8_t *const *)frame->data,
        frame->linesize,
        0,
        frame->height,
        destination_data,
        destination_linesize
    );
    CVPixelBufferUnlockBaseAddress(*pixel_buffer, 0);
    if (converted_height != frame->height) {
        CVPixelBufferRelease(*pixel_buffer);
        *pixel_buffer = NULL;
        return AVERROR_EXTERNAL;
    }

    ppff_copy_video_color(*pixel_buffer, frame);
    return 0;
}

int ppff_video_receive(PPFFSession *session, PPFFSample *sample, PPFFError *error) {
    if (session->video_decoder == NULL || session->video_drained) {
        return AVERROR(EAGAIN);
    }
    av_frame_unref(session->video_frame);
    int result;
    if (session->video_decoder_mode == PPFF_DECODER_MODE_VIDEOTOOLBOX &&
        session->force_hardware_decode_failure &&
        !session->hardware_decode_failure_injected) {
        session->hardware_decode_failure_injected = 1;
        result = AVERROR_EXTERNAL;
    } else {
        result = avcodec_receive_frame(session->video_decoder, session->video_frame);
    }
    if (result == AVERROR_EOF) {
        session->video_drained = 1;
        return result;
    }
    if (result < 0) {
        if (result != AVERROR(EAGAIN)) {
            ppff_error_set(error, result, "decode video frame");
        }
        return result;
    }

    CVPixelBufferRef pixel_buffer = NULL;
    if (session->video_frame->format == session->hardware_pixel_format &&
        session->video_frame->data[3] != NULL) {
        pixel_buffer = (CVPixelBufferRef)session->video_frame->data[3];
        CVPixelBufferRetain(pixel_buffer);
    } else {
        result = ppff_software_pixel_buffer(session, session->video_frame, &pixel_buffer);
        if (result < 0) {
            ppff_error_set(error, result, "convert video frame");
            return result;
        }
    }

    AVStream *stream = session->format_context->streams[session->default_video_stream];
    int64_t timestamp = session->video_frame->best_effort_timestamp;
    if (timestamp == AV_NOPTS_VALUE) {
        timestamp = session->video_frame->pts;
    }
    int64_t duration_us = ppff_video_duration_us(session, session->video_frame);
    int64_t presentation_time_us = timestamp == AV_NOPTS_VALUE
        ? (session->last_video_pts_us == INT64_MIN ? 0 : session->last_video_pts_us + duration_us)
        : av_rescale_q(timestamp, stream->time_base, AV_TIME_BASE_Q);
    if (session->last_video_pts_us != INT64_MIN &&
        presentation_time_us < session->last_video_pts_us) {
        presentation_time_us = session->last_video_pts_us;
    }
    session->last_video_pts_us = presentation_time_us;

    sample->kind = PPFF_SAMPLE_KIND_VIDEO;
    sample->stream_index = session->default_video_stream;
    sample->presentation_time_us = presentation_time_us;
    sample->duration_us = duration_us > 0 ? duration_us : 1;
    sample->video_buffer = pixel_buffer;
    return 1;
}
