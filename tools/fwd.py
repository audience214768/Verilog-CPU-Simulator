#!/usr/bin/env python3
"""fwd.py —— 一颗网的**全部**最近下游触发器（按 src 分组，不截断）。

`netattr.py` 的第 ④ 步只给前 6 组；对"高频广播网"（FO 上百、8 跳内碰上千个触发器）那不够：
`docs/plan.md` §3.34 §7 的**延迟窗口审计清单**要的是**完整名单**——"这颗网晚一拍，
谁跟着晚"要逐组判能不能晚，漏一组就是一次静默错值（§3.17）。

用法（在含 mapped.v / design.json 的 opt 目录所在机器上）：
  python3 tools/fwd.py <opt_dir> <跳数> <网名或实例名> ...

每行输出： `<个数>  <src>`，按个数降序；src 为 `(无 src)` 表示 Yosys 造的数组寄存器
（PRF 阵列 / LD_INFLIGHT，见 tools/README 坑 13）。

例（cutR 头名干道）：
  python3 tools/fwd.py runs/cutR/build/synth_cutR/opt 8 _088848_ _088283_
"""
import argparse
import collections
import sys
from pathlib import Path

sys.path.insert(0, 'tools')          # 允许从 stdin 管道执行（__file__ 不存在）
import cone as C                                                    # noqa: E402
import pathsrc as P                                                 # noqa: E402

OUTPINS = ('Y', 'Q', 'QN', 'H', 'L')
FF = ('DFF', 'SDFF', 'DLY')


def short(s):
    return (s or '(无 src)').split('verilog/')[-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('hops', type=int)
    ap.add_argument('nets', nargs='+')
    ap.add_argument('--max-node', type=int, default=400000)
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
        seen, q, nf = {net}, [net], collections.Counter()
        for _ in range(a.hops):
            nxt = []
            for n in q:
                for i, t, _ in loads.get(n, []):
                    if i in seen:
                        continue
                    seen.add(i)
                    if t.startswith(FF):
                        nf[short((srcmap.get(i) or (None, None, None))[1])] += 1
                    else:
                        nxt.append(yof.get(i))
            q = [x for x in nxt if x]
            if not q:
                break
        tot = sum(nf.values())
        print(f'== {arg} ({net}) 最近下游触发器 {tot} 个 (≤{a.hops} 跳):')
        for s, n in nf.most_common():
            print(f'   {n:>6}  {s}')


if __name__ == '__main__':
    main()
