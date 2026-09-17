#pragma once

#include <stdbool.h>
#include <stddef.h>

typedef enum {
    REMOTE_ROW_STYLE_BODY = 0,
    REMOTE_ROW_STYLE_ACCENT,
    REMOTE_ROW_STYLE_SECONDARY,
} remote_row_style_t;

// Parse the body of `S<row>|<style>`. The row must already exist so a malformed
// or out-of-order modifier can never change a different row by accident.
bool remote_row_style_parse(const char *body, size_t row_count,
                            size_t *row_index, remote_row_style_t *style);
