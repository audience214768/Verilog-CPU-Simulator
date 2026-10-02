#!/usr/bin/env python3
"""iss.py —— 最小 RV32IM 指令集模拟器（**第三方黄金参考**，非官方，不参与判分）

为什么要它: 整机算错时，日志只能告诉你"某条指令的结果不对"，不能告诉你**正确值是多少**。
本脚本独立实现一遍 ISA 语义，与 RTL 无任何共享代码 —— 于是"谁错了"变成可判定的，
而不是拿 RTL 自己的输出当自己的标尺（那是循环论证）。

口径:
  * 与官方 testcases 一致: 读 `@地址` / 十六进制字节流，**小端**，`//` 与 `#` 后是注释
  * 停机 = 向 MMIO 0x80000000 做 32 位 store，退出值 = store 数据
  * 只为调试服务: 不建模非对齐跨字访问、不建模 cache/异常（官方程序不产生）

用法:
  tools/iss.py testcases/correctness_hanoi/program.data        # → # insns=N exit=[v] a0=v
  tools/iss.py <prog.data> -t                                  # 追退休轨迹 (每条一行)

实测锚点（docs/plan.md §二十四 的定位链靠它）:
  hanoi ⇒ `# insns=3674 exit=[184] a0=184` —— RTL 修复后本地 TB 的 `commit=3674` 与之逐位相符。
"""
import sys

MASK = 0xFFFFFFFF


def sext(v, b):
    return (v - (1 << b)) & MASK if v >> (b - 1) else v & MASK


def load_image(path):
    mem = bytearray(1 << 22)
    addr = 0
    for line in open(path):
        for tok in line.split('//')[0].split('#')[0].split():
            if tok.startswith('@'):
                addr = int(tok[1:], 16)
            else:
                mem[addr] = int(tok, 16)
                addr += 1
    return mem


def run(path, trace=False, maxins=200_000_000):
    mem = load_image(path)
    rd = [0] * 32
    pc = 0
    n = 0
    out = []
    while n < maxins:
        ins = int.from_bytes(mem[pc:pc + 4], 'little')
        op = ins & 0x7F
        f3 = (ins >> 12) & 7
        f7 = (ins >> 25) & 0x7F
        rs1 = (ins >> 15) & 31
        rs2 = (ins >> 20) & 31
        rdd = (ins >> 7) & 31
        a = rd[rs1]
        b = rd[rs2]
        imm_i = sext(ins >> 20, 12)
        imm_s = sext(((ins >> 25) << 5) | ((ins >> 7) & 31), 12)
        imm_b = sext(((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) |
                     (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1), 13)
        imm_u = ins & 0xFFFFF000
        imm_j = sext(((ins >> 31) << 20) | (((ins >> 12) & 0xFF) << 12) |
                     (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1), 21)
        npc = (pc + 4) & MASK
        wb = None       # (reg, value)

        if op == 0x37:
            wb = (rdd, imm_u)
        elif op == 0x17:
            wb = (rdd, (pc + imm_u) & MASK)
        elif op == 0x6F:
            wb = (rdd, npc)
            npc = (pc + imm_j) & MASK
        elif op == 0x67:
            wb = (rdd, npc)
            npc = (a + imm_i) & MASK & ~1
        elif op == 0x63:
            taken = {0: a == b, 1: a != b, 4: sext(a, 32) < sext(b, 32),
                     5: sext(a, 32) >= sext(b, 32), 6: a < b, 7: a >= b}[f3]
            if taken:
                npc = (pc + imm_b) & MASK
        elif op == 0x03:
            ad = (a + imm_i) & MASK
            v = int.from_bytes(mem[ad:ad + 4], 'little')
            wb = (rdd, {0: sext(v & 0xFF, 8), 1: sext(v & 0xFFFF, 16), 2: v,
                        4: v & 0xFF, 5: v & 0xFFFF}[f3])
        elif op == 0x23:
            ad = (a + imm_s) & MASK
            if ad == 0x80000000:
                out.append(b)
                return out, n + 1, rd
            w = {0: 1, 1: 2, 2: 4}[f3]
            mem[ad:ad + w] = b.to_bytes(4, 'little')[:w]
        elif op == 0x13:
            sh = b & 31
            wb = (rdd, {0: (a + imm_i) & MASK, 2: int(a < sext(imm_i, 12)), 3: int(a < imm_i),
                        4: a ^ imm_i, 6: a | imm_i, 7: a & imm_i,
                        1: (a << sh) & MASK, 5: (a >> sh) if f7 == 0 else sext(a, 32) >> sh}[f3] & MASK)
        elif op == 0x33:
            sh = b & 31
            if f7 == 1:
                r = {0: (a * b) & MASK,
                     1: ((sext(a, 32) * sext(b, 32)) >> 32) & MASK,
                     2: ((sext(a, 32) * b) >> 32) & MASK,
                     3: ((a * b) >> 32) & MASK,
                     4: (a // b) & MASK if b else MASK,
                     5: (a // b) & MASK if b else MASK,
                     6: (a % b) & MASK if b else a,
                     7: (a % b) & MASK if b else a}[f3]
                if f3 == 4:
                    r = sext(a, 32) // sext(b, 32) if b else MASK
                    r &= MASK
                if f3 == 5:
                    r = a // b if b else MASK
                if f3 == 6:
                    r = sext(a, 32) % sext(b, 32) if b else a
                    r &= MASK
            else:
                r = {0: (a + b) & MASK, 1: (a << sh) & MASK, 2: int(a < b),
                     3: int(a < b), 4: a ^ b, 5: a >> sh if f7 == 0 else sext(a, 32) >> sh,
                     6: a | b, 7: a & b}[f3] & MASK
            wb = (rdd, r)
        elif op == 0x0F:
            pass
        else:
            raise SystemExit(f"bad opcode {op:02x} @ {pc:08x} ins={ins:08x}")
        if trace:
            print(f"{n:8d} {pc:08x} {ins:08x}")
        if wb and wb[0]:
            rd[wb[0]] = wb[1]
        rd[0] = 0
        pc = npc
        n += 1
    return out, n, rd


if __name__ == '__main__':
    path = sys.argv[1]
    tr = len(sys.argv) > 2 and sys.argv[2] == '-t'
    out, n, rd = run(path, tr)
    print(f"# insns={n} exit={out} a0={rd[10]}")
