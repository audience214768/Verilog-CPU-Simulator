#!/usr/bin/env python3
"""pathtrace.py —— 给一条 STA 路径**贴 RTL 名字**: 逐级列出该级门的有名输入网。

容器里 ABC 产出的是匿名网 (`_012345_`), 功能名几乎全没了 ⇒ `path.py`/`pathsrc.py` 只能给到
"起终点是 RTL 哪一段"。但**跨模块的网名保得住** (`\\u_mem.u_dc.sram_we_w`): 官方流程 flatten 之后
模块边界变成名字前缀, 而端口网 (`fill_line`/`fill_blk`)、宏引脚、以及被 ABC 原样留下的宽网仍带原名。
所以"这条路径经过哪些具名信号"是可以直接读出来的 —— 它就是"这一刀该切在哪"的答案。

用法:
  tools/pathtrace.py <probe_paths.rpt> <opt_dir> [--path N]
    # 报告 = sta -fields {fanout} 产出的; opt_dir = 含 mapped.v 的目录
"""
import argparse
import re
import sys
from pathlib import Path

CELL = re.compile(r'^\s*(\d*)\s+([\d.]+)\s+([\d.]+)\s+[\^v]\s+(\S+)/(\S+)\s+\((\S+)\)\s*$')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('report')
    ap.add_argument('opt_dir')
    ap.add_argument('--path', type=int, default=0, help='第几条路径 (0 起)')
    a = ap.parse_args()

    blocks = Path(a.report).read_text().split('Startpoint: ')
    if len(blocks) <= a.path + 1:
        sys.exit('报告里只有 %d 条路径' % (len(blocks) - 1))
    blk = blocks[a.path + 1]
    head, _, body = blk.partition('-------------------------------------------------------------------\n')
    print('Startpoint: %s' % head.splitlines()[0])
    for ln in head.splitlines():
        if ln.startswith('Endpoint:'):
            print(ln)

    start = head.splitlines()[0].partition(' (')[0]
    cells = []
    for ln in body.splitlines():
        m = CELL.match(ln)
        if not m:
            if ln.startswith('         ---'):
                break
            continue
        if m.group(4) == start and m.group(5) != 'CLK':     # 起点触发器单独打 (CLK 那行跳过)
            print('  起始触发器 %s (%s)' % (m.group(4), m.group(6)))
            continue
        cells.append((m.group(4), m.group(6), float(m.group(2)), float(m.group(3))))

    txt = Path(a.opt_dir, 'mapped.v').read_text()
    print('\n%-3s %-9s %-24s %-8s %s' % ('#', 't(ns)', 'type', 'd(ns)', '具名输入网'))
    for k, (inst, ty, d, t) in enumerate(cells):
        i = txt.find(' %s (' % inst)
        pin = ''
        if i >= 0:
            j = txt.find(');', i)
            body2 = txt[i:j]
            ty = body2.split()[0]
            pin = '; '.join('%s=%s' % (p, v.strip())
                            for p, v in re.findall(r'\.(\w+)\(([^)]*)\)', body2) if '.' in v)
        print('%-3d %-9.4f %-24s %-8.4f %s' % (k, t, ty, d, pin or '-'))


if __name__ == '__main__':
    main()
