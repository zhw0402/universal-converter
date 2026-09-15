#!/usr/bin/env python3
"""Swift 语法粗检：剥离注释与字符串字面量后检查括号配平。
无法替代编译器，但能抓住最致命的结构性错误。"""
import sys, re, os

RAW_STRING = re.compile(r'#+"')

def scan(src):
    """返回 (错误列表, 统计)"""
    errors = []
    i, n = 0, len(src)
    line = 1
    stack = []          # (char, line)
    pairs = {')': '(', ']': '[', '}': '{'}
    opens = set('([{')
    closes = set(')]}')
    stats = {'strings': 0, 'rawstrings': 0, 'comments': 0}

    while i < n:
        c = src[i]
        if c == '\n':
            line += 1; i += 1; continue

        # 行注释
        if c == '/' and i + 1 < n and src[i+1] == '/':
            while i < n and src[i] != '\n': i += 1
            stats['comments'] += 1
            continue
        # 块注释（支持嵌套）
        if c == '/' and i + 1 < n and src[i+1] == '*':
            depth, i, line = 1, i + 2, line
            while i < n and depth:
                if src[i] == '\n': line += 1
                if src.startswith('/*', i): depth += 1; i += 2; continue
                if src.startswith('*/', i): depth -= 1; i += 2; continue
                i += 1
            stats['comments'] += 1
            continue

        # 原始字符串 #"..."#  /  #"""..."""#
        m = RAW_STRING.match(src, i)
        if m:
            hashes = m.group(0).count('#')
            terminator = '"' + '#' * hashes
            j = m.end()
            # 多行原始字符串
            if src.startswith('""', j):
                j += 2
                end = src.find('"""' + '#' * hashes, j)
                if end == -1:
                    errors.append((line, '未闭合的多行原始字符串')); break
                line += src.count('\n', i, end)
                i = end + 3 + hashes
            else:
                end = src.find(terminator, j)
                if end == -1:
                    errors.append((line, '未闭合的原始字符串')); break
                line += src.count('\n', i, end)
                i = end + 1 + hashes
            stats['rawstrings'] += 1
            continue

        # 多行字符串 """
        if src.startswith('"""', i):
            j = i + 3
            end = src.find('"""', j)
            if end == -1:
                errors.append((line, '未闭合的多行字符串')); break
            line += src.count('\n', i, end)
            i = end + 3
            stats['strings'] += 1
            continue

        # 普通字符串
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == '\\': j += 2; continue
                if src[j] == '\n':
                    errors.append((line, '字符串跨行未闭合（缺少转义或引号）')); break
                if src[j] == '"': break
                j += 1
            if j >= n or src[j] != '"':
                break
            i = j + 1
            stats['strings'] += 1
            continue

        # 字符字面量（几乎不出现，忽略）

        if c in opens:
            stack.append((c, line))
        elif c in closes:
            if not stack:
                errors.append((line, f"多余的 '{c}'"))
            else:
                open_char, open_line = stack.pop()
                if open_char != pairs[c]:
                    errors.append((line, f"'{c}' 与第 {open_line} 行的 '{open_char}' 不匹配"))
        i += 1

    for ch, ln in stack:
        errors.append((ln, f"未闭合的 '{ch}'"))
    return errors, stats


def main(paths):
    total_errors = 0
    for path in paths:
        src = open(path, encoding='utf-8').read()
        errs, stats = scan(src)
        name = os.path.basename(path)
        if errs:
            total_errors += len(errs)
            print(f"❌ {name}")
            for ln, msg in errs[:12]:
                print(f"     第 {ln} 行: {msg}")
        else:
            print(f"✅ {name}  (字符串 {stats['strings']}+原始 {stats['rawstrings']}, 注释 {stats['comments']})")
    print()
    print("结论:", "全部结构平衡 ✅" if total_errors == 0 else f"发现 {total_errors} 处问题 ❌")
    return 1 if total_errors else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
