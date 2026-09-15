#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跨文件符号检查：把新增代码里对自有类型的成员调用抽出来，
和实际定义逐一比对，抓拼写错误 / 漏定义。"""
import os, re, sys, collections

ROOT = "/var/minis/workspace/universal-converter/Verto"
TYPES = ["Markup", "DocumentProcessor", "DocumentWriter", "DataProcessor", "DocxReader",
         "EpubReader", "ZipArchive", "ZipBuilder", "RawDeflate", "CRC32",
         "TextDocumentKind", "DataDocumentKind", "DataValue"]

def swift_files():
    for dirpath, _, names in os.walk(ROOT):
        for name in sorted(names):
            if name.endswith(".swift"):
                yield os.path.join(dirpath, name)

source = {}
for path in swift_files():
    source[path] = open(path, encoding="utf-8").read()

defined = collections.defaultdict(set)
for path, text in source.items():
    for match in re.finditer(r'\b(?:static\s+|private\s+|mutating\s+|final\s+|@\w+\s+)*'
                             r'(?:func|var|let|init|case)\s+([A-Za-z_][A-Za-z0-9_]*)', text):
        defined[path].add(match.group(1))

all_names = set()
for names in defined.values():
    all_names |= names

issues = []
for path, text in source.items():
    for type_name in TYPES:
        for match in re.finditer(re.escape(type_name) + r'\.([A-Za-z_][A-Za-z0-9_]*)', text):
            member = match.group(1)
            if member in all_names:
                continue
            line = text[:match.start()].count("\n") + 1
            issues.append((os.path.relpath(path, ROOT), line, f"{type_name}.{member}"))

if not issues:
    print("✅ 所有自有类型成员调用都能找到定义")
else:
    print("以下调用未在项目内找到同名定义（可能是框架成员，也可能是笔误）：")
    seen = set()
    for path, line, name in issues:
        key = (name,)
        if key in seen and name.startswith(("Markup.", "Zip", "DataValue", "Document")):
            continue
        seen.add(key)
        print(f"  {path}:{line}  {name}")

print()
print("=== OutputFormat case 覆盖检查 ===")
of = open(os.path.join(ROOT, "Models/OutputFormat.swift"), encoding="utf-8").read()
cases = re.findall(r'^\s*case\s+([a-z0-9,\s]+)$', of, re.M)
flat = [c.strip() for group in cases for c in group.split(",") if c.strip()]
print(f"  声明 {len(flat)} 个: {', '.join(flat)}")
for section in ["displayName", "fileExtension", "category", "imageUTType", "matchingUTType"]:
    block = re.search(r'var %s[^\{]*\{(.*?)\n    \}' % section, of, re.S)
    if block:
        covered = set(re.findall(r'case \.([a-z]+)', block.group(1)))
        has_default = "default" in block.group(1)
        missing = [c for c in flat if c not in covered]
        status = "有 default 兜底" if has_default else (f"缺 {missing}" if missing else "全覆盖")
        print(f"  {section:16s} {len(covered):2d}/{len(flat)}  {status}")

sys.exit(0)
