// main/boot_chime.h —— 开机音乐:异步播放一段嵌入固件的 PCM 片段。
#pragma once

#include <stdbool.h>
#include <stdint.h>

// 在独立任务中播放开机音乐,立即返回,不阻塞调用者。
// 需先 bsp_audio_init() 成功;内部自行设置采样格式与音量。
// chime_volume 为独立的开机音乐音量,范围 0..100;为 0 时跳过播放。
// DMA 尾音播完后才恢复普通音量 restore_volume(0..100)。普通音量为 0
// 不影响非零音量的开机音乐。播放期间的重复调用会被忽略。
void boot_chime_play_async(uint8_t restore_volume, uint8_t chime_volume);

// 是否正在播放。开机阶段任何"设置音量"的动作都要先问一下:音效播放期间去
// 改音量会让它中途变响,而 apply_device_config() 恰好就在那个窗口里跑。
bool boot_chime_is_playing(void);
