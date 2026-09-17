#pragma once

#include <stddef.h>

// Copy UTF-8 text without splitting a code point at dst_size. Emoji decoration
// sequences are removed because the embedded monochrome CJK font intentionally
// has no emoji glyphs. Invalid UTF-8 bytes become a visible ASCII question mark.
size_t ui_text_sanitize_copy(char *dst, size_t dst_size, const char *src);
