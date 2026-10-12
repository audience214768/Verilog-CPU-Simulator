#!/usr/bin/env python3
"""loadsrc.py —— 一颗网的**直接负载**按 (src, 类型, 引脚) 分组。

`fwd.py` 给的是"≤N 跳内碰到的触发器"（= 晚一拍谁跟着晚，太大太远），
本工具给的是**这一颗网自己驮着谁**（= 税是谁交的）。两者配合才是"负载税"的靶子选择：
要劈一颗广播网，先得知道它的负载按 RTL 分成了哪几坨、最大一坨在哪。

用法:
  python3 tools/loadsrc.py <opt_dir> <网名或实例名> ...

每坨一行: `<个数>  <src>  <cell类型>/<引脚>`（按个数降序，默认前 20）；末尾附 by-src 汇总。
"""
import argparse
import collections
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cone as C                                                    # noqa: E402
import pathsrc as P                                                 # noqa: E402

OUTPINS = ('Y', 'Q', 'QN', 'H', 'L')


def short(s):
    return (s or '(无 src)').split('verilog/')[-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('nets', nargs='+')
    ap.add_argument('--top', type=int, default=20)
    a = ap.parse_args()

    d = Path(a.dir)
    order, insts = C.read_netlist(d / 'mapped.v')
    srcmap = P.join(order, P.read_design(d / 'design.json', 'student_top'))
    loads = C.build_loads(insts)

    drv, yof = {}, {}
    for nm, (ty, pins) in insts.items():
        for p in OUTPINS:
            if p in pins:
                drv.setdefault(pins[p], (nm, ty, p))
                yof[nm] = pins[p]
                break

    for arg in a.nets:
        net = arg if arg in drv else yof.get(arg)
        if not net or net not in drv:
            print(f'== {arg}: 找不到驱动网')
            continue
        dn, dt, dp = drv[net]
        dl = loads.get(net, [])
        print(f'== {arg} ({net})  drv={dn}({dt}).{dp}  FO={len(dl)}')
        bycell, bysrc = collections.Counter(), collections.Counter()
        for i, t, p in dl:
            s = short((srcmap.get(i) or (None, None, None))[1])
            bycell[(s, t, p)] += 1
            bysrc[s] += 1
        for (s, t, p), n in bycell.most_common(a.top):
            print(f'   {n:>5}  {s}  {t}/{p}')
        print(f'   --- by src (共 {len(bysrc)} 坨) ---')
        for s, n in bysrc.most_common(a.top):
            print(f'   {n:>5}  {s}')


if __name__ == '__main__':
    main()
