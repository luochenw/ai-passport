// main/boot_chime.h —— 开机音乐:异步播放一段嵌入固件的 PCM 片段。
#pragma once

#include <stdbool.h>
#include <stdint.h>

// 在独立任务中播放开机音乐,立即返回,不阻塞调用者。
// 需先 bsp_audio_init() 成功;内部自行设置采样格式与音量。
// 异步播放开机音效。音效本身用一个固定的小音量(见 .c 里的
// BOOT_CHIME_VOLUME),放完之后把音量设回 restore_volume —— 也就是用户在
// 配套 app 里配的那个播放音量。
void boot_chime_play_async(uint8_t restore_volume);

// 是否正在播放。开机阶段任何"设置音量"的动作都要先问一下:音效播放期间去
// 改音量会让它中途变响,而 apply_device_config() 恰好就在那个窗口里跑。
bool boot_chime_is_playing(void);
