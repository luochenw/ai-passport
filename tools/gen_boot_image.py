#!/usr/bin/env python3
"""把一张图片转成开机画面(240x320 RGB565)。

    tools/gen_boot_image.py <图片> [-o assets/boot_image.rgb565]

为什么不引 Pillow:这个仓库的风格是自带脚本、不引额外依赖。缩放交给 macOS
自带的 sips,解码交给下面这几十行 —— BMP 是唯一一种不用第三方库就能可靠
读出像素的常见格式,所以中间格式选它。

产物是**裸 RGB565 数据**,由 CMake 的 EMBED_FILES 嵌进固件 —— 跟开机音效
(assets/music/boot_chime.pcm)完全一样的做法。不生成 C 数组:同样 150 KB
的数据,写成 `0x1234,` 是 640 KB 源文件,每次全量编译都要重新解析一遍,而
换来的东西一模一样。
"""

import argparse
import pathlib
import struct
import subprocess
import sys
import tempfile

WIDTH, HEIGHT = 240, 320   # ST7789P3,见 components/bsp/include/bsp_display.h


def to_bmp(src: pathlib.Path, dst: pathlib.Path) -> None:
    """缩放到刚好盖满 240x320,多出来的部分居中裁掉。

    先按"短边填满"缩放再裁,而不是直接拉到 240x320 —— 后者会把人脸拉变形。
    """
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(src)],
                         capture_output=True, text=True)
    dims = {}
    for line in out.stdout.splitlines():
        if ":" in line:
            k, _, v = line.strip().partition(":")
            if v.strip().isdigit():
                dims[k.strip()] = int(v.strip())
    w, h = dims.get("pixelWidth"), dims.get("pixelHeight")
    if not w or not h:
        sys.exit(f"读不出图片尺寸:{src}")

    # 短边填满:放大到两边都 >= 目标,再居中裁。
    scale = max(WIDTH / w, HEIGHT / h)
    rw, rh = round(w * scale), round(h * scale)
    with tempfile.TemporaryDirectory() as tmp:
        resized = pathlib.Path(tmp) / "r.bmp"
        subprocess.run(["sips", "-s", "format", "bmp",
                        "-z", str(rh), str(rw), str(src), "--out", str(resized)],
                       check=True, capture_output=True)
        subprocess.run(["sips", "-c", str(HEIGHT), str(WIDTH), str(resized),
                        "--out", str(dst)], check=True, capture_output=True)


def read_bmp(path: pathlib.Path) -> list:
    """只认 24/32 位未压缩 BMP —— sips 就产这个,不做通用解码器。"""
    data = path.read_bytes()
    if data[:2] != b"BM":
        sys.exit("中间文件不是 BMP,sips 的行为可能变了")
    offset = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    if bpp not in (24, 32):
        sys.exit(f"只支持 24/32 位 BMP,实际 {bpp}")
    if (w, abs(h)) != (WIDTH, HEIGHT):
        sys.exit(f"裁出来是 {w}x{abs(h)},期望 {WIDTH}x{HEIGHT}")

    stride = ((w * bpp // 8) + 3) & ~3
    px = bpp // 8
    rows = []
    for y in range(abs(h)):
        # BMP 高度为正表示**自下而上**存储。忘了这条的话图会上下颠倒,
        # 而颠倒的人脸一眼看不出是"存反了"还是"屏幕装反了"。
        src_y = (abs(h) - 1 - y) if h > 0 else y
        base = offset + src_y * stride
        row = []
        for x in range(w):
            b, g, r = data[base + x * px: base + x * px + 3]
            row.append(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3))
        rows.append(row)
    return rows


def emit_raw(rows: list, out: pathlib.Path) -> None:
    """小端 RGB565,逐行从上到下 —— LVGL 的 LV_COLOR_FORMAT_RGB565 就是这个布局。"""
    buf = bytearray()
    for row in rows:
        for v in row:
            buf += struct.pack("<H", v)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(buf)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("-o", "--output", default="assets/boot_image.rgb565")
    args = ap.parse_args()

    src = pathlib.Path(args.image).expanduser()
    if not src.exists():
        sys.exit(f"找不到 {src}")
    with tempfile.TemporaryDirectory() as tmp:
        bmp = pathlib.Path(tmp) / "fit.bmp"
        to_bmp(src, bmp)
        rows = read_bmp(bmp)
    out = pathlib.Path(args.output)
    emit_raw(rows, out)
    print(f"已生成 {out}({WIDTH}x{HEIGHT} RGB565,{out.stat().st_size} 字节)")
    print("⚠ 源图里的人脸/水印在这份数据里原样存在。它已被 .gitignore 挡住,"
          "别绕过去提交进公开仓库。")


if __name__ == "__main__":
    main()
