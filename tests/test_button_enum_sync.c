// tests/test_button_enum_sync.c —— 校验 Mac 端的按键枚举跟固件头文件一致。
//
// 为什么需要这个测试:两边是两种语言、两个仓库位置,靠人记住数值对应关系
// 是不可靠的 —— 实测就写错过一次:Swift 侧按"上/确定/下"的直觉编号,而
// 固件里是"上/下/确定",于是下键和确定键在设备上互换,双击被当成长按。
//
// 这种错不会有任何编译错误或运行时报错,只表现为"按下去做的事不对",
// 而且要拿着实机一个键一个键试才能发现。放到这里一秒就能查出来。
//
// 做法:从 Swift 源码里把枚举值抠出来,跟这里 include 的真实头文件比对。
#include "bsp_button.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failed;

// 在 Swift 源码里找 "case <名字> = <数字>",返回那个数字;找不到返回 -1。
static int swift_enum_value(const char *src, const char *enum_name, const char *case_name)
{
    const char *e = strstr(src, enum_name);
    if (!e) return -1;
    char needle[64];
    snprintf(needle, sizeof(needle), "case %s = ", case_name);
    const char *c = strstr(e, needle);
    if (!c) return -1;
    return atoi(c + strlen(needle));
}

static void check(const char *src, const char *enum_name, const char *case_name,
                  int expected, const char *c_name)
{
    int got = swift_enum_value(src, enum_name, case_name);
    if (got != expected) {
        printf("  FAIL %s.%s = %d,但固件里 %s = %d\n",
               enum_name, case_name, got, c_name, expected);
        g_failed++;
    }
}

int main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1]
                                  : "mac-relay/FoloCodexRelay/Shared/RemoteApps.swift";
    FILE *f = fopen(path, "rb");
    if (!f) { printf("读不到 %s\n", path); return 1; }
    static char src[262144];
    size_t n = fread(src, 1, sizeof(src) - 1, f);
    src[n] = '\0';
    fclose(f);

    printf("按键枚举跨语言一致性\n");

    check(src, "RemoteButton", "up",   BSP_BTN_UP,   "BSP_BTN_UP");
    check(src, "RemoteButton", "down", BSP_BTN_DOWN, "BSP_BTN_DOWN");
    check(src, "RemoteButton", "ok",   BSP_BTN_OK,   "BSP_BTN_OK");

    check(src, "RemoteButtonEvent", "press",  BSP_BTN_PRESS,   "BSP_BTN_PRESS");
    check(src, "RemoteButtonEvent", "click",  BSP_BTN_CLICK,   "BSP_BTN_CLICK");
    check(src, "RemoteButtonEvent", "double", BSP_BTN_DOUBLE,  "BSP_BTN_DOUBLE");
    check(src, "RemoteButtonEvent", "long",   BSP_BTN_LONG,    "BSP_BTN_LONG");
    check(src, "RemoteButtonEvent", "hold",   BSP_BTN_HOLD,    "BSP_BTN_HOLD");
    check(src, "RemoteButtonEvent", "longUp", BSP_BTN_LONG_UP, "BSP_BTN_LONG_UP");
    check(src, "RemoteButtonEvent", "release", BSP_BTN_RELEASE, "BSP_BTN_RELEASE");

    if (g_failed == 0) { printf("全部一致 ✅\n"); return 0; }
    printf("%d 项不一致 ❌ —— 改 RemoteApps.swift 里的枚举去对齐头文件\n", g_failed);
    return 1;
}
