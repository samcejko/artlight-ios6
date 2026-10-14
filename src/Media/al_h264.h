#ifndef AL_H264_H
#define AL_H264_H

#include <stdint.h>
#include <stddef.h>

// Small H.264 helpers for the hardware decoder (taken over from GFN6's RTP code)

// The first SPS and PPS NAL units of an Annex B access unit (without start codes); 1 when both were found
int al_h264_find_parameter_sets(const uint8_t *au, size_t len, const uint8_t **sps, size_t *sps_len, const uint8_t **pps, size_t *pps_len);
// The picture size an SPS (starting with its NAL header byte) describes, cropping applied; 1 on success
int al_h264_sps_dimensions(const uint8_t *sps, size_t len, int *width, int *height);
// Annex B -> AVCC (4-byte big-endian lengths) without the SPS, PPS and AUD units; returns the bytes written, 0 when
// it does not fit or there is nothing to decode. out may be au itself.
size_t al_h264_annexb_to_avcc(const uint8_t *au, size_t len, uint8_t *out, size_t cap);

#endif
