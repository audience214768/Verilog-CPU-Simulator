#!/usr/bin/env python3
"""netattr.py —— 一颗热网的**三步归因**: 谁驱动它 / 它驱动谁 / 谁在它附近。

分工: `path.py` 说"哪一级最贵", `pathsrc.py` 说"起终点是哪段 RTL", `cone.py --cone` 说"正向锥多大"。
但官方流程里最贵的网 (扇出几百的 ABC 共享字面量) 往往**两头都不是触发器**, 缺的正是这三步。

  ① 驱动: 该网的驱动实例 / 类型 / 输入。
     ★ 若给的是**实例名**, 自动换成它的输出网 —— 官方 `path.json` 的 `net` 字段填的其实是
     **驱动实例名**, 直接拿它去找网会一无所获 (`.v` 里 `TYPE _087201_ (... .Y(_029527_))`)。
  ② 反向锥: 完整组合锥的门数 / 触及网数 + **叶子触发器按 src 分组**。
     · 锥只有 2~3 门 ⇒ 这颗网**就是一条 RTL 直线**, 可以直接改 RTL (先例: plan.md §14 的 449);
     · 锥上万门 ⇒ 它是 ABC 对大云团的因式分解, **没有单条 RTL 对应物**, 只能改云团本身。
  ③ 正向: 负载的 类型×引脚 直方图 + 最近的下游触发器按 src 分组。
     负载几乎全是**无 src** 的复合门 = ABC 自造; 引脚集中在某个低有效脚 ⇒ 该字面量被折进了与/或项。

用法:
  tools/netattr.py <opt_dir> <net 或 实例名> [--max-leaf 6] [--hops 8]
  tools/netattr.py runs/cut5/build/synth_cut5/opt _023593_
"""
import argparse
import collections
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cone as C                                                    # noqa: E402
import pathsrc as P                                                 # noqa: E402

OUTPINS = ('Y', 'Q', 'QN', 'H', 'L')
FF = ('DFF', 'SDFF', 'DLY')


def short(s):
    return (s or '(无 src)').split('verilog/')[-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir', help='含 mapped.v / design.json 的目录')
    ap.add_argument('net')
    ap.add_argument('--max-leaf', type=int, default=6, help='反向锥叶子按 src 显示几组')
    ap.add_argument('--hops', type=int, default=8, help='正向找最近触发器的最大级数')
    ap.add_argument('--max-node', type=int, default=400000)
    a = ap.parse_args()

    d = Path(a.dir)
    order, insts = C.read_netlist(d / 'mapped.v')
    srcmap = P.join(order, P.read_design(d / 'design.json', 'student_top'))
    loads = C.build_loads(insts)

    drv, yof = {}, {}                       # 网 -> 驱动实例; 实例 -> 输出网
    for nm, (ty, pins) in insts.items():
        for p in OUTPINS:
            if p in pins:
                drv.setdefault(pins[p], (nm, ty, p))
                yof[nm] = pins[p]
                break

    net = a.net
    if net not in drv and net in insts:     # 给的是实例名
        net = yof.get(net)
        print(f'[注] {a.net} 是**实例名**({insts[a.net][0]}) ⇒ 换成它的输出网 {net}')
    if not net or net not in drv:
        sys.exit(f'网表里找不到 {a.net} 的驱动网')
    inst, ty, op = drv[net]
    s = srcmap.get(inst) or (None, None, None)
    print(f'① 网 {net}  ← {inst} ({ty}) .{op}' + (f'   src={short(s[1])}' if s[1] else ''))
    for p, v in sorted(insts[inst][1].items()):
        if p != op:
            print(f'     .{p}({v})')

    seen, stack = set(), [net]
    leaves, ngate = collections.Counter(), 0
    while stack:
        n = stack.pop()
        if n in seen or len(seen) > a.max_node:
            continue
        seen.add(n)
        dv = drv.get(n)
        if dv is None:
            continue
        nm, t, pp = dv
        if t.startswith(FF):
            sl = srcmap.get(nm) or (None, None, None)
            leaves[(sl[2] or '(无名)', short(sl[1]))] += 1
            continue
        ngate += 1
        stack += [v for k, v in insts[nm][1].items() if k != pp]
    tot = sum(leaves.values())
    print(f'\n② 反向锥: {ngate} 个组合门 / 触及 {len(seen)} 个网 / 叶子触发器 {tot}')
    bysrc = collections.Counter()
    for (h, sl), n in leaves.items():
        bysrc[sl] += n
    for sl, n in bysrc.most_common(a.max_leaf):
        print(f'   {n:>6}  {sl}')
    if 0 < tot <= 40:
        print('   叶子名: ' + ', '.join(f'{h}×{n}' for (h, sl), n in leaves.most_common(12)))

    ls = loads.get(net, [])
    ct = collections.Counter(t for _, t, _ in ls)
    cp = collections.Counter(p for _, _, p in ls)
    cs = collections.Counter(short((srcmap.get(i) or (None, None, None))[1]) for i, _, _ in ls)
    print(f'\n③ 负载 {len(ls)}: ' + ', '.join(f'{t}×{n}' for t, n in ct.most_common(6)))
    print('   引脚: ' + ', '.join(f'{p}×{n}' for p, n in cp.most_common(6)))
    print('   来源: ' + ', '.join(f'{x}×{n}' for x, n in cs.most_common(4)))

    seen2, q, nf = {net}, [net], collections.Counter()
    for _ in range(a.hops):
        nxt = []
        for n in q:
            for i, t, _ in loads.get(n, []):
                if i in seen2:
                    continue
                seen2.add(i)
                if len(seen2) > a.max_node:
                    break
                if t.startswith(FF):
                    nf[short((srcmap.get(i) or (None, None, None))[1])] += 1
                else:
                    nxt.append(yof.get(i))
        q = [x for x in nxt if x]
        if not q:
            break
    print(f'\n④ 最近下游触发器 ({sum(nf.values())} 个, ≤{a.hops} 级): '
          + ', '.join(f'{x}×{n}' for x, n in nf.most_common(6)))


if __name__ == '__main__':
    main()
