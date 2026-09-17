// main/remote_ui.h —— 远程界面:设备当显示终端,应用逻辑全在配套 app 那边。
//
// 为什么是这个架构
// ────────────────
// 早先"应用"是一份完整固件,装进 appslot 再重启过去。那条路走通了,但代价
// 大到不成立:每个应用都要自带一份 LVGL、字体、BLE 协议栈,于是一个只显示
// 几行数字的面板也有 1.9MB —— 其中 95% 是跟别的应用一模一样的基础设施;
// appslot 只有一个槽,所以还只能装一个,换应用要重刷两分钟。
//
// 真正需要下发的其实只有"这一屏长什么样"。把应用逻辑(取数据、算状态、
// 决定显示什么)留在算力和网络都富裕的那一端,设备只负责画和回传按键:
//
//   · 应用在设备上不占空间,想装几个装几个,切换是瞬间的;
//   · 应用不需要 Wi-Fi、HTTP、JSON —— 那些都在对端做完了;
//   · 写一个应用不用碰 C 和 ESP-IDF,也不可能把设备写成砖。
//
// 屏幕描述协议
// ────────────
// 对端推一段纯文本,一行一个元素,`\n` 分隔:
//
//   T<标题>              顶部标题
//   L<文本>              一行正文
//   B<百分比>|<标签>     一条进度条(百分比 0..100)
//   S<行号>|<样式>       修饰已存在的正文行(body/accent/secondary)
//   H<提示>              底部按键提示
//   M<0|1>               这一屏收不收语音输入(1 = 长按下键说话)
//   W<0|1>               实时对讲模式(1 = DOWN 按下/抬起原样回传)
//
// M 这一行是个例外:它不是"画什么",而是"这一屏启用设备上的哪个能力"。
// 之所以要有它 —— 麦克风长在设备上,采样和编码这条链路的起点在硬件这一侧,
// 没法由对端代劳。对端能做的只是声明"我这一屏想收语音",由设备决定怎么把
// 按键接到录音上。
//
// 用文本而不是二进制:一屏内容撑死几百字节,省下的那点带宽远不值得让两端
// 为了加一种元素就得同步改协议版本号;出问题时抓包也直接能看懂。真正需要
// 压榨带宽的是固件传输那条路径,那边才用二进制。
//
// S 是可选的附加元数据。对端总会先发原有 L/B 内容，因此老固件忽略 S 后仍
// 能显示完整正文，只是统一使用默认颜色。其余未识别行也直接忽略。
#pragma once

#include "bsp_button.h"
#include "remote_row_style.h"
#include <stdbool.h>
#include <stdint.h>

#define REMOTE_UI_MAX_ROWS   12
#define REMOTE_UI_TEXT_LEN   64
#define REMOTE_UI_TITLE_LEN  40

// 首屏能列出的已安装应用数上限。
//
// 8 不是随便定的:首屏要在 240x320 的屏上一次列完(三个按键的设备做滚动列表
// 得不偿失),加上"应用商店/固件升级/电量"三个固定项一共 11 行,按 22px 行距
// 正好卡在底部提示条上面。main.c 里有一条 _Static_assert 把这个算式钉死了 ——
// 想加大这个数,那条断言会在编译期直接报错,而不是等到有人真装满了才发现
// 最后一行看不见。
#define REMOTE_UI_MAX_APPS   8
#define REMOTE_UI_APP_LEN    32
// 图标是一个 LVGL 符号的 UTF-8 编码(私有区 U+F0xx,3 字节),留点余量。
#define REMOTE_UI_ICON_LEN   8

typedef enum {
    REMOTE_ROW_TEXT = 0,
    REMOTE_ROW_BAR,
} remote_row_kind_t;

typedef struct {
    remote_row_kind_t kind;
    remote_row_style_t style;
    char text[REMOTE_UI_TEXT_LEN];
    int  percent;              // 仅 REMOTE_ROW_BAR 有意义
} remote_row_t;

typedef struct {
    char title[REMOTE_UI_TITLE_LEN];
    char footer[REMOTE_UI_TEXT_LEN];
    remote_row_t rows[REMOTE_UI_MAX_ROWS];
    int  row_count;
    bool mic;                  // 对端声明这一屏收语音(M1)
    bool walkie;               // 对端声明实时 PTT(W1)
} remote_screen_t;

// 注册 GATT service。必须在 ble_hub_init() 之前调用。
void remote_ui_register(void);

// 取一份当前屏幕的快照。返回 false 表示对端还没推过任何东西。
bool remote_ui_snapshot(remote_screen_t *out);

// 屏幕版本号:变了说明有新内容,界面据此决定要不要重绘。
uint32_t remote_ui_revision(void);

// 把按键回传给对端。设备自己不解释这些按键的含义 —— 翻页、刷新、选中
// 分别意味着什么,由对端的应用逻辑决定。
void remote_ui_send_key(bsp_btn_t btn, bsp_btn_ev_t ev);

// 通知对端"用户进/出了远程界面",让它知道该不该推屏幕。
void remote_ui_set_active(bool active);

// ---- 已安装应用清单(首屏用) ----------------------------------------------
//
// 配套 app 在连上之后推一份"用户装了哪些应用"的清单过来,设备把它缓存进
// NVS。首屏直接列这份清单。
//
// 每行的格式是 "<图标>\t<名字>",图标可以为空(那一行就直接是名字)。
// 用制表符分隔而不是别的字符:应用名是用户起的,空格和常见标点都可能出现,
// 而制表符不会。
//
// 为什么要缓存而不是每次连上再问:设备可能在没连电脑的情况下开机,那时首屏
// 如果只能显示"等待连接",这台设备就退化成一块只会等待的板子。缓存之后
// 首屏照常列出装过的应用,点进去才提示需要连接电脑 —— 至少用户知道自己
// 装了什么、设备是活的。
int         remote_ui_app_count(void);
const char *remote_ui_app_name(int index);

// 应用的图标(LVGL 符号的 UTF-8 编码)。没有就返回空串,调用方自己决定默认值。
//
// ⚠ 画它必须用 montserrat 字库:图标在私有区 U+F0xx,中文字库根本没有这段
// 码位,拿中文字库画出来是方框。而且 montserrat 只内置了**一批特定的**
// FontAwesome 字形(见 lv_font_montserrat_14.c 开头那行 -r 参数),不在那批
// 里的同样画不出来 —— 所以图标只能从配套 app 那份清单里挑,不能随便填。
const char *remote_ui_app_icon(int index);

// 清单版本号,变了说明列表有更新,首屏据此重绘。
uint32_t remote_ui_manifest_revision(void);

// 告诉对端"用户选了第 index 个应用"。REMOTE_UI_OPEN_STORE 表示选的是
// "应用商店"那一项。
#define REMOTE_UI_OPEN_STORE 0xFE
void remote_ui_open_app(uint8_t index);

// 请求配套 app 卸载首屏第 index 个应用。设备不先改自己的 NVS 缓存；配套
// app 完成卸载后会按既有 MANIFEST 通道回推权威清单，避免两端状态分叉。
void remote_ui_uninstall_app(uint8_t index);
