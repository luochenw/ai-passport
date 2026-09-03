#include "ui_pixel.h"
#include "ui_statusbar.h"

#define UI_CORNER_R 20  /* 呼应外壳圆角塑料窗口 */

static lv_obj_t *s_scr;

static lv_obj_t *block(lv_obj_t *parent, int x, int y, int w, int h, uint32_t color)
{
    lv_obj_t *obj = lv_obj_create(parent);
    lv_obj_remove_flag(obj, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(obj, x, y);
    lv_obj_set_size(obj, w, h);
    lv_obj_set_style_radius(obj, 0, 0);
    lv_obj_set_style_border_width(obj, 0, 0);
    lv_obj_set_style_pad_all(obj, 0, 0);
    lv_obj_set_style_bg_color(obj, lv_color_hex(color), 0);
    return obj;
}

lv_obj_t *ui_pixel_label(lv_obj_t *parent, const char *text,
                         const lv_font_t *font, uint32_t color)
{
    lv_obj_t *label = lv_label_create(parent);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, font, 0);
    lv_obj_set_style_text_color(label, lv_color_hex(color), 0);
    return label;
}

lv_obj_t *ui_pixel_screen_create(const char *title)
{
    (void)title;    /* 高级黑客终端风:去掉 logo 与页面名称,只留取景框 */

    lv_obj_t *scr = lv_obj_create(NULL);
    lv_obj_remove_flag(scr, LV_OBJ_FLAG_SCROLLABLE);
    /* 纯黑机身底,与外壳的圆角塑料窗口衔接 */
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x000000), 0);
    lv_obj_set_style_border_width(scr, 0, 0);
    lv_obj_set_style_pad_all(scr, 0, 0);

    /* 给常驻状态栏让出顶部这一条。
     *
     * 这一行是所有页面"内容自动下移"的**唯一**机制:LVGL 里子对象的坐标是
     * 相对父对象内容区的(lv_obj_move_to() 末尾会加上 parent 的 space_top),
     * 所以在这里设一次 pad_top,十几个页面里那些写死的 y 坐标全部自动让位,
     * 页面代码一行都不用改、也不可能有哪个页面忘了让。
     *
     * 底部对齐的元素不受影响:LV_ALIGN_BOTTOM_* 算的是 y += ph - h,而 ph 是
     * 已经扣掉 pad_top 的内容高度,move_to() 再把 pad_top 加回去,一进一出正好
     * 抵消 —— 底部提示条还贴在屏幕底边。
     *
     * ⚠ 唯一不会自动跟上的是**写死了 320** 的地方(那算的是绝对高度)。
     * 那种比较要改用 UI_CONTENT_H。 */
    lv_obj_set_style_pad_top(scr, UI_STATUSBAR_H, 0);

    /* 圆角深色屏幕层:圆角呼应外壳。
     *
     * 边框保留(圆角靠它成形,也负责把内容和外壳窗口分开),但颜色改成纯黑
     * 而不是强调色 —— 一圈高饱和的橙框在这块小屏上会把视线从内容上拽走,
     * 而它本身不传达任何信息。 */
    lv_obj_t *display = lv_obj_create(scr);
    lv_obj_remove_flag(display, LV_OBJ_FLAG_SCROLLABLE);
    /* 取景框也是 scr 的子对象,所以它同样吃 pad_top —— 内容区原点已经在状态栏
     * 下面了,写 (2, 0) 就是紧贴状态栏。高度相应缩掉状态栏那一条,底边仍落在
     * 原来的 318,不会戳出屏幕。 */
    lv_obj_set_pos(display, 2, 0);
    lv_obj_set_size(display, 236, 316 - UI_STATUSBAR_H);
    lv_obj_set_style_radius(display, UI_CORNER_R, 0);
    lv_obj_set_style_bg_color(display, lv_color_hex(UI_BG), 0);
    lv_obj_set_style_border_width(display, 2, 0);
    lv_obj_set_style_border_color(display, lv_color_hex(0x000000), 0);
    lv_obj_set_style_pad_all(display, 0, 0);

    s_scr = scr;
    return scr;
}

lv_obj_t *ui_pixel_panel_create(lv_obj_t *parent, int x, int y, int w, int h,
                                uint32_t color)
{
    lv_obj_t *panel = block(parent, x, y, w, h, color);
    lv_obj_set_style_border_color(panel, lv_color_hex(UI_LINE), 0);
    lv_obj_set_style_border_width(panel, 1, 0);
    lv_obj_set_style_pad_all(panel, 8, 0);
    return panel;
}

void ui_pixel_set_selected(lv_obj_t *panel, bool selected, bool enabled)
{
    if (!enabled) {
        lv_obj_set_style_bg_color(panel, lv_color_hex(UI_BG_SOFT), 0);
        lv_obj_set_style_border_color(panel, lv_color_hex(UI_LINE), 0);
        return;
    }
    ui_pixel_mark(panel, selected);
}

void ui_pixel_mark(lv_obj_t *panel, bool selected)
{
    lv_obj_set_style_bg_color(panel,
        lv_color_hex(selected ? UI_ACCENT_BG : UI_PAPER), 0);
    lv_obj_set_style_border_color(panel,
        lv_color_hex(selected ? UI_ACCENT : UI_LINE), 0);
}
