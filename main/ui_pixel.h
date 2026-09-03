#pragma once

#include "lvgl.h"

LV_FONT_DECLARE(lv_font_ui_cn_14);
LV_FONT_DECLARE(lv_font_ui_cn_20);

/* 高级黑客终端风 + Claude 陶土橙强调:深色地台,细描边,单一暖橙点缀 */
#define UI_BG          0x0A0908   /* 近黑终端底 */
#define UI_BG_SOFT     0x161310   /* 次级深灰底(禁用态) */
#define UI_INK         0xF0EAE0   /* 暖白正文,替代墨黑 */
#define UI_INK_SOFT    0x847B6C   /* 次要暖灰字 */
#define UI_PAPER       0x171310   /* 卡片深底,替代纸白 */
#define UI_LINE        0x362F26   /* 细描边/分割线 */
#define UI_ACCENT      0xD97757   /* 陶土橙强调 */
#define UI_ACCENT_DK   0xB4552F   /* 深陶土橙 */
#define UI_ACCENT_BG   0x2A1811   /* 深陶土选中底 */
#define UI_SAGE        0x7C8B73   /* 鼠尾草绿 */
#define UI_SAGE_DK     0x5E6F56   /* 深鼠尾草绿 */
#define UI_RED         0xE0554A
#define UI_MUTED       0x5B5346

/* 兼容旧页面引用的语义色名 */
#define UI_SKY        UI_BG
#define UI_SKY_DARK   UI_ACCENT_DK
#define UI_YELLOW     0xEFE3D3
#define UI_GRASS      UI_SAGE
#define UI_GRASS_DARK UI_SAGE_DK
#define UI_ORANGE     UI_ACCENT

lv_obj_t *ui_pixel_screen_create(const char *title);
lv_obj_t *ui_pixel_panel_create(lv_obj_t *parent, int x, int y, int w, int h,
                                uint32_t color);
lv_obj_t *ui_pixel_label(lv_obj_t *parent, const char *text,
                         const lv_font_t *font, uint32_t color);
void ui_pixel_set_selected(lv_obj_t *panel, bool selected, bool enabled);
void ui_pixel_mark(lv_obj_t *panel, bool selected);
