#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 Verto 的英文界面文案替换为中文。
只做精确字符串字面量替换（含引号），不做模糊匹配，
未命中的条目会列出来，便于核对。"""
import os, sys, re

ROOT = "/var/minis/workspace/universal-converter/Verto"

# 精确字面量（含前后引号） -> 替换值（含前后引号）
PAIRS = {
    # ---------- 应用外壳 / ContentView ----------
    '"Verto"': '"万能转换"',
    '"verto batch — converting \\(active) of \\(app.jobs.count) files"':
        '"正在转换 \\(active) / \\(app.jobs.count) 个文件"',
    '"verto batch — \\(app.jobs.count) files · all done"':
        '"已完成 · 共 \\(app.jobs.count) 个文件"',
    '"verto batch — \\(app.jobs.count) files queued"':
        '"已排队 \\(app.jobs.count) 个文件"',
    '"choose output folder…"': '"选择输出文件夹…"',
    '"Converted files are saved here"': '"转换后的文件保存在此文件夹"',
    '"Converted files will be saved in this folder"': '"转换后的文件将保存在此文件夹"',
    '"converting…"': '"转换中…"',
    '"cancel"': '"取消"',
    '"\\(app.finishedCount)/\\(app.jobs.count) done"': '"已完成 \\(app.finishedCount) / \\(app.jobs.count)"',
    '"convert"': '"开始转换"',
    '"Convert All"': '"全部转换"',
    '"Add Files"': '"添加文件"',
    '"Add files"': '"添加文件"',
    '"Open Files…"': '"打开文件…"',
    '"browse files…"': '"浏览文件…"',
    '"Choose files to convert"': '"选择要转换的文件"',
    '"Clear"': '"清空"',
    '"Remove all files from the list"': '"移除列表中的全部文件"',
    '"Remove from list"': '"从列表中移除"',
    '"Options"': '"选项"',
    '"Default quality & compression options"': '"默认质量与压缩参数"',
    '"Show in Finder"': '"在「文件」中显示"',
    '"leave the file alone"': '"保持原样"',
    '"Compress \\(src)"': '"压缩 \\(src)"',
    '"the same format"': '"保持原格式"',

    # ---------- 拖放区 ----------
    '"drop files to convert"': '"把文件拖到这里转换"',
    '"drag them anywhere, or"': '"拖到窗口任意位置，或"',
    '"release to add"': '"松开即可添加"',
    '"▼ release to add files"': '"▼ 松开以添加文件"',
    '"images · video · audio · pdf — nothing ever leaves this device"':
        '"图片 · 视频 · 音频 · PDF · 文档 · 数据 — 全部在本机完成"',
    '"images · video · audio · pdf — nothing ever leaves this Mac"':
        '"图片 · 视频 · 音频 · PDF · 文档 · 数据 — 全部在本机完成"',

    # ---------- 任务行 ----------
    '"Output format"': '"输出格式"',
    '"Quality & size for this file"': '"此文件的质量与体积"',
    '"Estimated output"': '"预计输出"',

    # ---------- 图片选项 ----------
    '"Image quality"': '"图片质量"',
    '"Resize images"': '"调整尺寸"',
    '"Original size"': '"原始尺寸"',
    '"Max 4096 px"': '"最长边 4096 px"',
    '"Max 2048 px"': '"最长边 2048 px"',
    '"Max 1024 px"': '"最长边 1024 px"',
    '"Applies to JPEG and HEIC output, and to PDF compression."':
        '"影响 JPEG / HEIC 输出，以及 PDF 压缩。"',
    '"PNG and TIFF pages are lossless — quality applies to JPEG and compressed PDF output."':
        '"PNG / TIFF 为无损格式，质量参数只作用于 JPEG 与压缩后的 PDF。"',
    '"Original"': '"原始"',

    # ---------- PDF 选项 ----------
    '"PDF resolution"': '"PDF 分辨率"',
    '"Rotate pages"': '"旋转页面"',
    '"Rotate"': '"旋转"',
    '"Pages"': '"页码范围"',
    '"Trim white margins"': '"裁掉白边"',
    '"Trim"': '"裁剪"',
    '"100 DPI (smallest)"': '"100 DPI（最小）"',
    '"150 DPI (balanced)"': '"150 DPI（均衡）"',
    '"200 DPI"': '"200 DPI"',
    '"300 DPI (print)"': '"300 DPI（印刷）"',
    '"Pages like 1-3, 7 (empty = all). Rotation, trim and resolution apply to exported pages and to the compressed PDF."':
        '"写法如 1-3, 7（留空 = 全部）。旋转、裁剪与分辨率会同时作用于导出的图片和压缩后的 PDF。"',
    '"no pages rendered"': '"没有渲染出任何页面"',

    # ---------- 视频选项 ----------
    '"Video codec"': '"视频编码"',
    '"Video resolution"': '"视频分辨率"',
    '"Video bitrate"': '"视频码率"',
    '"Bitrate"': '"码率"',
    '"File size"': '"目标体积"',
    '"Target file size"': '"目标文件大小"',
    '"Sizing"': '"体积控制"',
    '"Auto"': '"自动"',
    '"Codec"': '"编码"',
    '"H.264 (compatible)"': '"H.264（兼容性最好）"',
    '"HEVC (smaller)"': '"HEVC（体积小约 40%）"',
    '"The encoder chooses the best bitrate for the resolution."':
        '"由编码器根据分辨率自动选择最佳码率。"',
    '"Bitrate is derived from the size — very small targets reduce quality."':
        '"码率由目标体积反推 —— 目标过小会明显降低画质。"',
    '"Fine-tune bitrate or exact file size per file with the dial button on each row."':
        '"点每一行的调节按钮，可为单个文件设置码率或精确体积。"',
    '"Resolution"': '"分辨率"',

    # ---------- 音频选项 ----------
    '"Audio bitrate"': '"音频码率"',
    '"Bitrate (AAC)"': '"码率（AAC）"',
    '"Audio track"': '"音轨"',
    '"Speed"': '"速度"',
    '"Volume"': '"音量"',
    '"Fade in"': '"淡入"',
    '"Fade out"': '"淡出"',
    '"None"': '"无"',
    '"Normal"': '"原速"',
    '"Pitch is preserved — voices stay natural at any speed."':
        '"变速不变调 —— 任何倍速下人声都保持自然。"',
    '"Start and end as m:ss (e.g. 1:30). Leave a field empty to keep that edge."':
        '"起止时间写 m:ss（例如 1:30）。留空表示不裁剪该端。"',
    ' is uncompressed 16-bit PCM — no quality settings apply."':
        ' 是无压缩的 16-bit PCM，没有可调的质量参数。"',

    # ---------- 引擎错误 ----------
    '"This conversion is not supported."': '"不支持这种格式转换。"',
    '"The file could not be opened."': '"无法打开该文件。"',
    '"The file contains no audio track."': '"该文件不含音轨。"',
    '"Encoding failed: ': '"编码失败：',
    '"Export failed: ': '"导出失败：',
    '"unknown error"': '"未知错误"',
    '"unknown duration"': '"时长未知"',
    '"read error"': '"读取错误"',
    '"write error"': '"写入错误"',
    '"encode error"': '"编码错误"',
    '"the trim range is empty"': '"裁剪区间为空"',
    '"this file does not support the selected quality preset"':
        '"该文件不支持所选的质量预设"',
    '"the file has no video track"': '"该文件没有视频轨道"',
    '"the audio file is empty"': '"音频文件为空"',
    '"audio rendering stalled"': '"音频渲染停滞"',
    '"audio rendering failed"': '"音频渲染失败"',
    '"cannot start writing"': '"无法开始写入"',
    '"cannot start reading"': '"无法开始读取"',
    '"could not create destination"': '"无法创建输出文件"',
    '"could not create PDF context"': '"无法创建 PDF 上下文"',
    '"could not create GIF destination"': '"无法创建 GIF 输出"',
    '"could not write GIF"': '"无法写入 GIF"',
    '"could not allocate the audio buffer"': '"无法分配音频缓冲区"',
    '"cannot write audio track"': '"无法写入音轨"',
    '"cannot read video track"': '"无法读取视频轨道"',
    '"cannot read audio track"': '"无法读取音轨"',
    '"cannot encode video"': '"无法编码视频"',

    # ---------- 徽标 ----------
    '"end"': '"结束"',

    # ---------- 装饰性终端日志 ----------
    '"[09:43:30] queue      idle — 0 jobs waiting"': '"[23:41:30] 队列       空闲 — 无待处理任务"',
    '"[09:43:29] ok         trip-milano.mp4            24.8 MB  target hit"':
        '"[23:41:29] 完成      宣传片.mp4                  24.8 MB  命中目标"',
    '"[09:43:16] ....       ██████████░░  83%          bitrate 4.6 Mbps"':
        '"[23:41:16] ....       ██████████░░  83%          码率 4.6 Mbps"',
    '"[09:43:15] transcode  trip-milano.mov → mp4      target 25 MB"':
        '"[23:41:15] 转码       宣传片.mov → mp4            目标 25 MB"',
    '"[09:43:02] ok         screenshot-3.jpg           148 KB   −71%"':
        '"[23:41:02] 完成       截图-3.jpg                 148 KB   −71%"',
    '"[09:43:02] convert    screenshot-3.png → jpeg    q=0.85 · flatten"':
        '"[23:41:02] 转换       截图-3.png → jpeg           q=0.85 · 展平"',
    '"[09:42:44] ok         voicememo-032.wav          82.9 MB  pcm"':
        '"[23:40:44] 完成       录音-032.wav               82.9 MB  pcm"',
    '"[09:42:41] convert    voicememo-032.m4a → wav    44.1 kHz · 16-bit"':
        '"[23:40:41] 转换       录音-032.m4a → wav         44.1 kHz · 16-bit"',
    '"[09:42:40] scan       voicememo-032.m4a          14.1 MB"':
        '"[23:40:40] 扫描       录音-032.m4a               14.1 MB"',
    '"[09:42:12] render     page 24/24 → jpeg          150 dpi"':
        '"[23:40:12] 渲染       第 24/24 页 → jpeg          150 dpi"',
    '"[09:42:12] ok         24 files                   18.2 MB"':
        '"[23:40:12] 完成       24 个文件                  18.2 MB"',
    '"[09:42:10] render     page 1/24 → jpeg           150 dpi"':
        '"[23:40:10] 渲染       第 1/24 页 → jpeg           150 dpi"',
    '"[09:41:31] ok         lecture-14.mp4             96.4 MB  −77%"':
        '"[23:39:31] 完成       网课-14.mp4                96.4 MB  −77%"',
    '"[09:41:08] ....       ██████░░░░░░  48%          eta 0:22"':
        '"[23:39:08] ....       ██████░░░░░░  48%          剩余 0:22"',
    '"[09:41:07] transcode  lecture-14.mov → mp4       hevc · 1080p"':
        '"[23:39:07] 转码       网课-14.mov → mp4           hevc · 1080p"',
    '"[09:41:07] scan       lecture-14.mov             412 MB"':
        '"[23:39:07] 扫描       网课-14.mov                412 MB"',
    '"[09:41:05] ok         logo-draft.heic            212 KB   −64%"':
        '"[23:39:05] 完成       主图.heic                  212 KB   −64%"',
    '"[09:41:05] convert    logo-draft.png → heic      lossless"':
        '"[23:39:05] 转换       主图.png → heic             无损"',
    '"[09:41:04] ok         IMG_0422.jpg               548 KB   −80%"':
        '"[23:39:04] 完成       IMG_0422.jpg               548 KB   −80%"',
    '"[09:41:03] scan       IMG_0422.heic              2.8 MB"':
        '"[23:39:03] 扫描       IMG_0422.heic              2.8 MB"',
    '"[09:41:03] ok         IMG_0421.jpg               612 KB   −80%"':
        '"[23:39:03] 完成       IMG_0421.jpg               612 KB   −80%"',
    '"[09:41:02] scan       IMG_0421.heic              3.1 MB"':
        '"[23:39:02] 扫描       IMG_0421.heic              3.1 MB"',
    '"[09:41:02] convert    IMG_0421.heic → jpeg       q=0.85"':
        '"[23:39:02] 转换       IMG_0421.heic → jpeg        q=0.85"',
    '"✗ failed"': '"✗ 失败"',
    '"⌗trim"': '"⌗裁边"',
    '"fade"': '"淡入淡出"',
    '"p.': '"第 ',
}

def main():
    apply_changes = "--apply" in sys.argv
    patterns = sorted(PAIRS.keys(), key=len, reverse=True)
    hits = {p: 0 for p in patterns}
    files_changed = 0

    for dirpath, _, filenames in os.walk(ROOT):
        for filename in sorted(filenames):
            if not filename.endswith(".swift"):
                continue
            path = os.path.join(dirpath, filename)
            with open(path, encoding="utf-8") as handle:
                original = handle.read()
            text = original
            for pattern in patterns:
                if pattern in text:
                    hits[pattern] += text.count(pattern)
                    text = text.replace(pattern, PAIRS[pattern])
            if text != original:
                files_changed += 1
                if apply_changes:
                    with open(path, "w", encoding="utf-8") as handle:
                        handle.write(text)
                print(f"  {'已修改' if apply_changes else '将修改'} {os.path.relpath(path, ROOT)}")

    missed = [p for p in patterns if hits[p] == 0]
    print(f"\n命中条目: {len(patterns) - len(missed)}/{len(patterns)}   涉及文件: {files_changed}")
    if missed:
        print("\n未命中的条目（需核对原文）：")
        for pattern in missed:
            print("   ", pattern)
    return 0

if __name__ == "__main__":
    sys.exit(main())
