#include "remote_row_style.h"

#include <assert.h>
#include <stddef.h>

int main(void)
{
    size_t row = 99;
    remote_row_style_t style = REMOTE_ROW_STYLE_BODY;

    assert(remote_row_style_parse("0|accent", 1, &row, &style));
    assert(row == 0 && style == REMOTE_ROW_STYLE_ACCENT);
    assert(remote_row_style_parse("8|secondary", 9, &row, &style));
    assert(row == 8 && style == REMOTE_ROW_STYLE_SECONDARY);
    assert(remote_row_style_parse("1|body", 2, &row, &style));
    assert(row == 1 && style == REMOTE_ROW_STYLE_BODY);

    assert(!remote_row_style_parse("bad|accent", 1, &row, &style));
    assert(!remote_row_style_parse("0accent", 1, &row, &style));
    assert(!remote_row_style_parse("1|accent", 1, &row, &style));
    assert(!remote_row_style_parse("0|future-style", 1, &row, &style));
    assert(!remote_row_style_parse("0|accent|extra", 1, &row, &style));
    return 0;
}
