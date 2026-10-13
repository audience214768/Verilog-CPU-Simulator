#!/usr/bin/env python3
"""rdata_path.py <preabc.v> <网名> —— 打印 "宏读出口 → 该网" 的**最短网级路径**。

配套 `rdata_verdict.py`：verdict 回答"吃不吃 rdata"，本工具回答"**从哪条路吃**"。
每一跳都打出 cell 类型、实例名与引脚；RTL 具名网标 ★ —— 拿它直接对读 verilog。

输入同 `rdata_verdict.py`（`preabc_official.ys.tpl` 的产物，RTL 名字还在）。

    tools/rdata_path.py /tmp/preabc_cutX.v '\\u_mem.u_dc.victim_way_w'

口径提示: 这是**网级**路径, 每一跳 = 一个组合 cell; 与 STA 的"级"不是一回事（ABC 之后一级
= 一个复合并门）。它的用途是归因到 RTL 信号, 不是估延时。
"""
import re
import sys
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from seqcone import parse, outs, is_named, base_name, CONST, SEQ  # noqa: E402

RDATA = re.compile(r'rdata|rd_out')


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    netlist, target = sys.argv[1], sys.argv[2]
    cells, drv, drvbase, seen = parse(netlist)
    if target not in seen:
        sys.exit(f'{target}: 网表里找不到这颗网（转义名含空格，记得整体加引号）')

    def sq(inst):
        ty = cells[inst][0].lstrip('\\$')
        return ty.startswith(SEQ) or cells[inst][0].startswith('fakeram')

    depth, parent, q = {target: 0}, {}, deque([target])
    while q:
        n = q.popleft()
        inst = drv.get(n) or drvbase.get(base_name(n))
        if inst is None or sq(inst):
            continue
        ty, pins = cells[inst]
        o = outs(ty, pins)
        for p, v in pins.items():
            if p in o or v in CONST:
                continue
            for net in ([x.strip() for x in v[1:-1].split(',')] if v.startswith('{') else [v]):
                net = net.strip()
                if net and net not in depth:
                    depth[net] = depth[n] + 1
                    parent[net] = (n, inst, p)
                    q.append(net)

    seeds = sorted((d, n) for n, d in depth.items() if RDATA.search(base_name(n)))
    if not seeds:
        print(f'{target}: 锥里没有宏读出口 (锥 {len(depth)} 网)')
        return
    d0, s = seeds[0]
    print(f'# {target}\n# 最近宏读出口 {s}  跳数 {d0}  (锥 {len(depth)} 网)')
    chain, cur = [], s
    while cur in parent:
        nxt, inst, pin = parent[cur]
        chain.append((cur, cells[inst][0], inst, pin))
        cur = nxt
    chain.append((cur, None, None, None))
    for i, (net, ty, inst, pin) in enumerate(chain):
        if ty is None:
            print(f'{i:>3} ★ {net}   ← 目标')
        else:
            print(f'{i:>3} {"★" if is_named(net) else " "} {net:<58} <- {ty} {inst} .{pin}')


if __name__ == '__main__':
    main()
