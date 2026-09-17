#include "ui_text_sanitize.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

static bool decode_utf8(const unsigned char *src, uint32_t *codepoint, size_t *length)
{
    const unsigned char first = src[0];
    if (first < 0x80) {
        *codepoint = first;
        *length = 1;
        return true;
    }

    size_t count;
    uint32_t value;
    if (first >= 0xC2 && first <= 0xDF) {
        count = 2;
        value = first & 0x1F;
    } else if (first >= 0xE0 && first <= 0xEF) {
        count = 3;
        value = first & 0x0F;
    } else if (first >= 0xF0 && first <= 0xF4) {
        count = 4;
        value = first & 0x07;
    } else {
        *length = 1;
        return false;
    }

    for (size_t i = 1; i < count; i++) {
        if (src[i] == '\0' || (src[i] & 0xC0) != 0x80) {
            *length = 1;
            return false;
        }
        value = (value << 6) | (src[i] & 0x3F);
    }
    if ((count == 3 && value < 0x800) ||
        (count == 4 && value < 0x10000) ||
        (value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF) {
        *length = 1;
        return false;
    }
    *codepoint = value;
    *length = count;
    return true;
}

static bool is_emoji_decoration(uint32_t codepoint)
{
    return (codepoint >= 0x1F000 && codepoint <= 0x1FAFF) ||
           (codepoint >= 0x2300 && codepoint <= 0x23FF) ||
           (codepoint >= 0x2600 && codepoint <= 0x27BF) ||
           (codepoint >= 0x2B00 && codepoint <= 0x2BFF) ||
           (codepoint >= 0xFE00 && codepoint <= 0xFE0F) ||
           (codepoint >= 0xE0100 && codepoint <= 0xE01EF) ||
           codepoint == 0x200D || codepoint == 0x20E3;
}

size_t ui_text_sanitize_copy(char *dst, size_t dst_size, const char *src)
{
    if (dst_size == 0) return 0;
    if (!src) {
        dst[0] = '\0';
        return 0;
    }

    const unsigned char *cursor = (const unsigned char *)src;
    size_t written = 0;
    bool removed_decoration = false;
    while (*cursor) {
        uint32_t codepoint = 0;
        size_t length = 0;
        const bool valid = decode_utf8(cursor, &codepoint, &length);
        if (!valid) {
            if (written + 1 >= dst_size) break;
            dst[written++] = '?';
            cursor += length;
            removed_decoration = false;
            continue;
        }
        if (is_emoji_decoration(codepoint)) {
            cursor += length;
            removed_decoration = true;
            continue;
        }
        // A decoration commonly arrives as "emoji + space + label".  Do not
        // leave that separator behind at the start of a menu line.
        if (removed_decoration && (codepoint == 0x20 || codepoint == 0x3000)) {
            cursor += length;
            continue;
        }
        removed_decoration = false;
        if (written + length >= dst_size) break;
        memcpy(dst + written, cursor, length);
        written += length;
        cursor += length;
    }
    dst[written] = '\0';
    return written;
}
