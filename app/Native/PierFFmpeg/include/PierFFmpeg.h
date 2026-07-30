#ifndef PIER_FFMPEG_H
#define PIER_FFMPEG_H

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

#if defined(__cplusplus)
}
#endif

#endif
