#include "ui_text_sanitize.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
    char out[64];

    ui_text_sanitize_copy(out, sizeof(out), "鲍鱼烩饭炖汤");
    assert(strcmp(out, "鲍鱼烩饭炖汤") == 0);

    ui_text_sanitize_copy(out, sizeof(out), "🍲鲍鱼 🥘 烩饭✨");
    assert(strcmp(out, "鲍鱼 烩饭") == 0);

    ui_text_sanitize_copy(out, sizeof(out), "👨‍🍳  今日推荐");
    assert(strcmp(out, "今日推荐") == 0);

    ui_text_sanitize_copy(out, sizeof(out), "推荐 • 今日");
    assert(strcmp(out, "推荐 • 今日") == 0);

    char short_out[8];
    ui_text_sanitize_copy(short_out, sizeof(short_out), "鲍鱼烩饭");
    assert(strcmp(short_out, "鲍鱼") == 0);

    const char malformed[] = {'A', (char)0xFF, 'B', '\0'};
    ui_text_sanitize_copy(out, sizeof(out), malformed);
    assert(strcmp(out, "A?B") == 0);

    puts("ui text sanitize: PASS");
    return 0;
}
