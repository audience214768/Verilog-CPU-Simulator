#!/usr/bin/env python3
"""裸二进制 → 官方 program.data 文本格式 (首行 @地址, 其后每行 16 字节)。

    riscv64-unknown-elf-objcopy -O binary x.elf x.bin
    python3 tb/top/bin2data.py x.bin x.data [基地址]
"""
import sys


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    base = int(sys.argv[3], 0) if len(sys.argv) == 4 else 0
    data = open(sys.argv[1], 'rb').read()
    with open(sys.argv[2], 'w') as out:
        out.write('# 由 tb/top/bin2data.py 生成 (objcopy -O binary 的产物)\n')
        out.write('@%08x\n' % base)
        for off in range(0, len(data), 16):
            out.write(' '.join('%02x' % b for b in data[off:off + 16]) + '\n')
    print('%s: %d 字节 @ %#x' % (sys.argv[2], len(data), base))


main()
