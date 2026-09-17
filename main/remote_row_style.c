#include "remote_row_style.h"

#include <ctype.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

bool remote_row_style_parse(const char *body, size_t row_count,
                            size_t *row_index, remote_row_style_t *style)
{
    if (!body || !row_index || !style || !isdigit((unsigned char)body[0])) {
        return false;
    }

    errno = 0;
    char *separator = NULL;
    unsigned long index = strtoul(body, &separator, 10);
    if (errno != 0 || separator == body || !separator || *separator != '|' ||
        index >= row_count) {
        return false;
    }

    const char *name = separator + 1;
    remote_row_style_t parsed;
    if (strcmp(name, "body") == 0) {
        parsed = REMOTE_ROW_STYLE_BODY;
    } else if (strcmp(name, "accent") == 0) {
        parsed = REMOTE_ROW_STYLE_ACCENT;
    } else if (strcmp(name, "secondary") == 0) {
        parsed = REMOTE_ROW_STYLE_SECONDARY;
    } else {
        return false;
    }

    *row_index = (size_t)index;
    *style = parsed;
    return true;
}
