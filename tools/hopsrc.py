#!/usr/bin/env python3
"""hopsrc.py —— 给一条路径的**每一级**算"反向锥叶子按 (来源 src, 跳数) 分解"。

用途（§3.33 的前缀分解）：官方网表里前缀是一堆 ABC 复合门，两头都不是触发器，
`pathsrc.py` 报不出 RTL 源、`netattr.py` 的叶子直方图**不分跳数** ⇒ 分不清
"这一级刚出 PRF 读口" 还是 "这一级已经进比较树"。

跳数定义：BFS 从该级输出网**反向**走，经过 d 个组合门到达叶子触发器 ⇒ 该叶子的
跳数 = d（叶子直接驱动该网 d=1 时说明该网就是一级门）。
（`--hops` 限制 BFS 最大跳数；超过的叶子记在 `>H` 桶。）

用法（在含 mapped.v / design.json 的 opt 目录所在机器上）：
  python3 tools/hopsrc.py <opt_dir> <nets_file>
nets_file 每行一个**实例名**或网名（顺序即报告顺序，`#` 与空行忽略）。

输出每行：
  L<序号> t=<级清单时间> <网> ← <驱动实例>(类型)  负载=<扇出>
      叶 <总数>: 叶≤2 跳 = ... | 按 (src,跳桶) 前 6 组
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
BUCKETS = ((1, 2, '≤2'), (3, 4, '3-4'), (5, 8, '5-8'), (9, 10 ** 9, '>8'))


def bucket(d):
    for lo, hi, nm in BUCKETS:
        if lo <= d <= hi:
            return nm
    return '>8'


def short(s):
    return (s or '(无 src)').split('verilog/')[-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('nets_file')
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

    names = [l.split('#')[0].strip() for l in open(a.nets_file)]
    names = [n for n in names if n]
    for i, raw in enumerate(names, 1):
        net = raw if raw in drv else yof.get(raw)
        if not net or net not in drv:
            print(f'L{i:<2d} {raw:>10s} : 找不到驱动网')
            continue
        inst, ty, op = drv[net]
        sl = srcmap.get(inst) or (None, None, None)
        nlf = len(loads.get(net, []))

        # 反向 BFS，带跳数
        seen = {net: 0}
        q = [net]
        hist = collections.Counter()            # (src, 跳桶) -> 叶数
        shallow = collections.Counter()         # src -> 叶数(≤2 跳)
        tot, ngate, depth = 0, 0, 0
        while q and len(seen) < a.max_node:
            nxt = []
            for n in q:
                dn = seen[n]
                dv = drv.get(n)
                if dv is None:
                    continue
                nm, t, pp = dv
                if t.startswith(FF):
                    s = srcmap.get(nm) or (None, None, None)
                    hist[(short(s[1]), bucket(dn + 1))] += 1
                    if dn + 1 <= 2:
                        shallow[short(s[1])] += 1
                    tot += 1
                    depth = max(depth, dn + 1)
                    continue
                ngate += 1
                for p, v in insts[nm][1].items():
                    if p != pp and v not in seen:
                        seen[v] = dn + 1
                        nxt.append(v)
            q = nxt
        head = ', '.join(f'{s}[{b}跳]×{n}' for (s, b), n in hist.most_common(6))
        sh = ', '.join(f'{s}×{n}' for s, n in shallow.most_common(4)) or '(无)'
        print(f'L{i:<2d} {net:>10s} ← {inst}({ty}) 负载={nlf} 锥={ngate}门/叶{tot}(深{depth})')
        print(f'      叶≤2跳: {sh}')
        print(f'      全部: {head}')


if __name__ == '__main__':
    main()
