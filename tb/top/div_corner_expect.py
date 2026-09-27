#!/usr/bin/env python3
"""从 div_corner.s 的 pairs 表按 RISC-V 语义独立算出 G3 程序的期望退出值。

    python3 tb/top/div_corner_expect.py tb/top/div_corner.s

**不取自仿真输出** —— 否则是自证。pairs 表是 .s 与期望值唯一共同的真值来源。
"""
import re
import sys


def sx(v):
    return v - (1 << 32) if v >> 31 else v


def div_rem(a, b, unsigned, want_rem):
    """RISC-V 除法语义 (截断向零); 除零与溢出按 ISA 规定。"""
    if unsigned:
        a, b = a & 0xFFFFFFFF, b & 0xFFFFFFFF
        if b == 0:
            return a if want_rem else 0xFFFFFFFF
        return (a % b) if want_rem else (a // b)
    if b == 0:
        return a if want_rem else 0xFFFFFFFF            # 除零: 商全 1, 余 = 被除数
    if a == -0x80000000 and b == -1:
        return 0 if want_rem else -0x80000000           # 唯一溢出: 余 0, 商回绕成自身
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    return (a - q * b) if want_rem else q


def main():
    text = open(sys.argv[1]).read()
    pat = r'^\s*\.word\s+0x([0-9a-fA-F]+)\s*,\s*0x([0-9a-fA-F]+)'
    pairs = re.findall(pat, text, re.M)
    total = len(re.findall(r'^\s*\.word', text, re.M))
    assert pairs and len(pairs) == total, '解析到 %d 对 / 共 %d 条 .word' % (len(pairs), total)
    acc = 0
    for x, y in pairs:                                  # 顺序同 .s: div, divu, rem, remu
        a, b = sx(int(x, 16)), sx(int(y, 16))
        for unsigned, want_rem in ((0, 0), (1, 0), (0, 1), (1, 1)):
            acc = (acc * 31 + div_rem(a, b, unsigned, want_rem)) & 0xFFFFFFFF
    print('%d 对 × 4 条 = %d 个结果, EXPECTED=%d (0x%08x)' % (len(pairs), 4 * len(pairs), acc, acc))


main()
