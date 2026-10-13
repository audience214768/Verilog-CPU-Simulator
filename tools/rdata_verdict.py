#!/usr/bin/env python3
"""rdata_verdict.py <preabc.v> <网名> [网名 ...] —— 逐信号判据: 该信号的锥里有没有**宏读出口**?

用途（2026-10-13，plan §3.42 定位"rdata → rd_addr_w"的入口）：回答"这根控制信号到底依不依赖
本拍读出的 SRAM 数据"。这是"宏自己的一拍闭环"是否存在、以及**有几条**的直接判据。

输入必须是 `tools/preabc_official.ys.tpl` 的产物（**RTL 名字还在**；post-ABC 的 `mapped.v` 上
ABC 匿名网名与 RTL 没有对应关系，问不出来 —— 见 `seqcone.py` 头注释）。

每行输出: 锥网数 / 边界数 / 宏读出口条数 + 最近一条及其跳数。**0 条 = 该信号与宏读出口无组合关系**。

用法实例（cutX 树，输出存 docs/timing/cutX/attrib_rdata_cutX.txt）:

    tools/rdata_verdict.py /tmp/preabc_cutX.v \\
        '\\u_mem.u_dc.way_hit_g [0]' '\\u_mem.u_dc.rmw_rd_w' '\\u_mem.u_dc.probe_slot_w' \\
        '\\u_mem.u_dc.st_hit_lat_w'

★ 网名转义里有空格（`\\u_mem.u_dc.rdata_w [557]`）⇒ 整体加引号。端口名在 flatten 后是
`\\u_mem.dc_hit_valid` / `\\u_mem.ld_accept` 这种形式, 不是 `u_dc.hit_valid`。
"""
import re
import sys
from collections import deque, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from seqcone import parse, outs, base_name, CONST, SEQ  # noqa: E402

RDATA = re.compile(r'rdata|rd_out')


def cone_of(cells, drv, drvbase, start):
    """时序截断锥: 停在顺序单元与宏的输出网。返 {net: 到 start 的跳数} + 边界族。"""
    def sq(inst):
        ty = cells[inst][0].lstrip('\\$')
        return ty.startswith(SEQ) or cells[inst][0].startswith('fakeram')

    depth, bord, q = {start: 0}, defaultdict(list), deque([start])
    while q:
        n = q.popleft()
        inst = drv.get(n) or drvbase.get(base_name(n))
        if inst is None:
            bord['(无驱动)'].append((n, depth[n]))
            continue
        if sq(inst):
            bord[base_name(n)].append((n, depth[n]))
            continue
        ty, pins = cells[inst]
        o = outs(ty, pins)
        for p, v in pins.items():
            if p in o or v in CONST or v in depth:
                continue
            for net in ([x.strip() for x in v[1:-1].split(',')] if v.startswith('{') else [v]):
                net = net.strip()
                if net and net not in depth:
                    depth[net] = depth[n] + 1
                    q.append(net)
    return depth, bord


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cells, drv, drvbase, seen = parse(sys.argv[1])
    print(f'{"信号":<36} {"锥网数":>7} {"边界":>6}  宏读出口')
    print('-' * 84)
    for t in sys.argv[2:]:
        if t not in seen:
            print(f'{t:<36} {"—":>7} {"—":>6}  **网表里没有这颗网**')
            continue
        depth, bord = cone_of(cells, drv, drvbase, t)
        nb = sum(len(v) for v in bord.values())
        hits = sorted((d, n) for g, lst in bord.items() if RDATA.search(g) for n, d in lst)
        if hits:
            print(f'{t:<36} {len(depth):>7} {nb:>6}  **{len(hits)} 条 吃 rdata**'
                  f' (最近 d={hits[0][0]}: {hits[0][1]})')
        else:
            print(f'{t:<36} {len(depth):>7} {nb:>6}  干净 (0 条)')


if __name__ == '__main__':
    main()
