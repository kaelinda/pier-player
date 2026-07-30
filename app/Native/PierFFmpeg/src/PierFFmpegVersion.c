#include "PierFFmpeg.h"

#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>

const char *ppff_version(void) {
    return av_version_info();
}

const char *ppff_configuration(void) {
    return avcodec_configuration();
}

const char *ppff_license(void) {
    return avcodec_license();
}
