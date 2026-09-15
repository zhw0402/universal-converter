#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把工程改名/换包 ID，便于侧载安装。只做精确替换，改完打印确认。"""
import sys, os

ROOT = "/var/minis/workspace/universal-converter"
PBX = os.path.join(ROOT, "Verto.xcodeproj", "project.pbxproj")

EDITS = [
    ("INFOPLIST_KEY_CFBundleDisplayName = Verto;",
     'INFOPLIST_KEY_CFBundleDisplayName = "万能转换";'),
    ("PRODUCT_BUNDLE_IDENTIFIER = com.alessandrogaudio.Verto;",
     "PRODUCT_BUNDLE_IDENTIFIER = com.minis.universalconverter;"),
    ("MARKETING_VERSION = 1.1.0;",
     "MARKETING_VERSION = 2.0.0;"),
    ('INFOPLIST_KEY_NSHumanReadableCopyright = "© 2026 Alessandro Gaudio";',
     'INFOPLIST_KEY_NSHumanReadableCopyright = "基于 Verto (MIT © 2026 Alessandro Gaudio)；中文版与文档/数据格式扩展";'),
]

def main():
    with open(PBX, encoding="utf-8") as handle:
        text = handle.read()

    failed = []
    for old, new in EDITS:
        if old in text:
            text = text.replace(old, new)
            print(f"  ✅ {old[:60]}…")
        else:
            failed.append(old)
            print(f"  ⚠️  未找到: {old}")

    with open(PBX, "w", encoding="utf-8") as handle:
        handle.write(text)

    print()
    if failed:
        print(f"{len(failed)} 项未生效，请核对")
        return 1
    print("工程配置已更新")
    return 0

if __name__ == "__main__":
    sys.exit(main())
