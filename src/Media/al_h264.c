#include "al_h264.h"
#include <stdlib.h>
#include <string.h>

/* ---- Annex B helpers ---- */

// Iterates NAL units of an Annex B buffer: *pos is where to start looking; returns the NAL start and length
static int next_nal(const uint8_t *au, size_t len, size_t *pos, const uint8_t **nal, size_t *nal_len)
{
    size_t i = *pos;
    while (i + 3 <= len) {
        if (au[i] == 0 && au[i + 1] == 0 && (au[i + 2] == 1 || (i + 4 <= len && au[i + 2] == 0 && au[i + 3] == 1))) break;
        i++;
    }
    if (i + 3 > len) return 0;
    i += (au[i + 2] == 1) ? 3 : 4;
    size_t start = i;
    while (i + 3 <= len) {
        if (au[i] == 0 && au[i + 1] == 0 && (au[i + 2] == 1 || (i + 4 <= len && au[i + 2] == 0 && au[i + 3] == 1))) break;
        i++;
    }
    size_t end = (i + 3 <= len) ? i : len;
    while (end > start && au[end - 1] == 0 && i + 3 <= len) end--;     // trailing zeros belong to the next start code
    *nal = au + start;
    *nal_len = end - start;
    *pos = i;
    return 1;
}

int al_h264_find_parameter_sets(const uint8_t *au, size_t len, const uint8_t **sps, size_t *sps_len, const uint8_t **pps, size_t *pps_len)
{
    size_t pos = 0;
    const uint8_t *nal;
    size_t nlen;
    *sps = *pps = NULL;
    *sps_len = *pps_len = 0;
    while (next_nal(au, len, &pos, &nal, &nlen)) {
        if (nlen < 1) continue;
        uint8_t type = nal[0] & 0x1f;
        if (type == 7 && !*sps) { *sps = nal; *sps_len = nlen; }
        else if (type == 8 && !*pps) { *pps = nal; *pps_len = nlen; }
    }
    return *sps && *pps;
}

/* ---- SPS parsing (just enough for the picture size) ---- */

typedef struct { const uint8_t *p; size_t n; size_t bit; } bitreader;

static uint32_t rbit(bitreader *b)
{
    if (b->bit >= b->n * 8) return 0;
    uint32_t v = (b->p[b->bit >> 3] >> (7 - (b->bit & 7))) & 1;
    b->bit++;
    return v;
}

static uint32_t rbits(bitreader *b, int n)
{
    uint32_t v = 0;
    while (n-- > 0) v = (v << 1) | rbit(b);
    return v;
}

static uint32_t rue(bitreader *b)
{
    int zeros = 0;
    while (rbit(b) == 0 && zeros < 32 && b->bit < b->n * 8) zeros++;
    if (zeros == 0) return 0;
    return (1u << zeros) - 1 + rbits(b, zeros);
}

static int32_t rse(bitreader *b)
{
    uint32_t k = rue(b);
    return (k & 1) ? (int32_t)((k + 1) / 2) : -(int32_t)(k / 2);
}

static void skip_scaling_list(bitreader *b, int size)
{
    int last = 8, next = 8;
    for (int j = 0; j < size; j++) {
        if (next != 0) next = (last + rse(b) + 256) % 256;
        last = next ? next : last;
    }
}

int al_h264_sps_dimensions(const uint8_t *sps, size_t len, int *width, int *height)
{
    uint8_t rbsp[1024];
    size_t m = 0;
    if (len < 4) return 0;
    for (size_t i = 1; i < len && m < sizeof(rbsp); i++) {
        if (i >= 2 && sps[i] == 3 && sps[i - 1] == 0 && sps[i - 2] == 0) continue;   // emulation prevention byte
        rbsp[m++] = sps[i];
    }
    bitreader b = { rbsp, m, 0 };
    uint32_t profile = rbits(&b, 8);
    rbits(&b, 8);
    rbits(&b, 8);
    rue(&b);
    uint32_t chroma = 1;
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244 || profile == 44 || profile == 83 || profile == 86 ||
        profile == 118 || profile == 128 || profile == 138 || profile == 139 || profile == 134 || profile == 135) {
        chroma = rue(&b);
        if (chroma == 3) rbit(&b);
        rue(&b);
        rue(&b);
        rbit(&b);
        if (rbit(&b)) {
            int lists = chroma != 3 ? 8 : 12;
            for (int i = 0; i < lists; i++) if (rbit(&b)) skip_scaling_list(&b, i < 6 ? 16 : 64);
        }
    }
    rue(&b);
    uint32_t poc = rue(&b);
    if (poc == 0) {
        rue(&b);
    } else if (poc == 1) {
        rbit(&b);
        rse(&b);
        rse(&b);
        uint32_t n = rue(&b);
        if (n > 256) return 0;
        for (uint32_t i = 0; i < n; i++) rse(&b);
    }
    rue(&b);
    rbit(&b);
    uint32_t pw = rue(&b), ph = rue(&b);
    uint32_t frame_mbs_only = rbit(&b);
    if (!frame_mbs_only) rbit(&b);
    rbit(&b);
    uint32_t l = 0, r = 0, t = 0, bo = 0;
    if (rbit(&b)) { l = rue(&b); r = rue(&b); t = rue(&b); bo = rue(&b); }
    int w = (int)((pw + 1) * 16);
    int h = (int)((2 - frame_mbs_only) * (ph + 1) * 16);
    int cx = (chroma == 1 || chroma == 2) ? 2 : 1;
    int cy = (int)(2 - frame_mbs_only) * (chroma == 1 ? 2 : 1);
    w -= (int)(l + r) * cx;
    h -= (int)(t + bo) * cy;
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) return 0;
    *width = w;
    *height = h;
    return 1;
}

size_t al_h264_annexb_to_avcc(const uint8_t *au, size_t len, uint8_t *out, size_t cap)
{
    struct { size_t start, len; } ranges[256];
    int count = 0;
    size_t pos = 0;
    const uint8_t *nal;
    size_t nlen;
    size_t total = 0;
    while (count < 256 && next_nal(au, len, &pos, &nal, &nlen)) {
        if (nlen < 1) continue;
        uint8_t type = nal[0] & 0x1f;
        if (type == 7 || type == 8 || type == 9) continue;
        ranges[count].start = (size_t)(nal - au);
        ranges[count].len = nlen;
        count++;
        total += 4 + nlen;
    }
    if (total > cap || !count) return 0;
    uint8_t *tmp = (out == au) ? (uint8_t *)malloc(total) : out;
    if (!tmp) return 0;
    size_t o = 0;
    for (int i = 0; i < count; i++) {
        tmp[o] = (uint8_t)(ranges[i].len >> 24); tmp[o + 1] = (uint8_t)(ranges[i].len >> 16);
        tmp[o + 2] = (uint8_t)(ranges[i].len >> 8); tmp[o + 3] = (uint8_t)ranges[i].len;
        memcpy(tmp + o + 4, au + ranges[i].start, ranges[i].len);
        o += 4 + ranges[i].len;
    }
    if (out == au) {
        memcpy(out, tmp, total);
        free(tmp);
    }
    return total;
}
