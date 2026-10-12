#!/usr/bin/env python3
"""fwdname.py —— 一颗广播网的负载**按"最近的具名祖先网"分组**。

回答的问题: Yosys+ABC flatten 后绝大多数网是匿名的 `_NNNNN_`，但**跨模块边界的网名保得住**
(`\\u_cpu.cmt` 之类)。所以"这颗网的扇出是经哪个 RTL 信号散出去的"可以这样测:
从源网做前向 BFS，给每个节点记下**最近的一个具名祖先网**，最后按该名字给下游触发器分组。

用法:
  python3 tools/fwdname.py <opt_dir> <网名或实例名> [跳数] [--path 实例名]
    --path <实例>: 单独打印"源网 → 该实例"的门级路径（含各级具名信息）
"""
import argparse
import collections
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cone as C                                                    # noqa: E402
import pathsrc as P                                                 # noqa: E402

OUTPINS = ('Y', 'Q', 'QN', 'H', 'L')
FF = ('DFF', 'SDFF', 'DLY')
ANON = re.compile(r'^_?\d+_?$')            # `_012345_` / `12345` = ABC 匿名网


def short(s):
    return (s or '(无 src)').split('verilog/')[-1]


def named(n):
    return bool(n) and not ANON.match(n) and not n.startswith('$')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('net')
    ap.add_argument('hops', nargs='?', type=int, default=8)
    ap.add_argument('--path', default=None)
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

    net = a.net if a.net in drv else yof.get(a.net)
    if not net or net not in drv:
        sys.exit(f'找不到驱动网: {a.net}')

    # BFS: (网 → (具名祖先, 跳数, 前驱网))
    anc = {net: (net if named(net) else None, 0, None)}
    q = [net]
    groups = collections.Counter()
    gsrc = collections.defaultdict(collections.Counter)
    gh = collections.defaultdict(list)
    seen_inst = set()
    for hop in range(a.hops):
        nxt = []
        for n in q:
            for i, t, p in loads.get(n, []):
                if i in seen_inst:
                    continue
                seen_inst.add(i)
                o = yof.get(i)
                if t.startswith(FF):
                    g = anc[n][0]
                    groups[g] += 1
                    gsrc[g][short((srcmap.get(i) or (None, None, None))[1])] += 1
                    gh[g].append(anc[n][1] + 1)
                elif o:
                    an, h, _ = anc[n]
                    anc[o] = (an if an else (o if named(o) else None), h + 1, n)
                    nxt.append(o)
            if len(seen_inst) > a.max_node:
                print('!! 超出节点上限'); break
        q = nxt
        if not q:
            break
    tot = sum(groups.values())
    print(f'== {a.net} ({net}) ≤{a.hops} 跳下游触发器 {tot} 个，按最近具名祖先分组:')
    for g, n in groups.most_common(30):
        hs = gh[g]
        gg = g if g else '(路径上无具名网)'
        print(f'   {n:>6}  {gg}   [跳数 {min(hs)}~{max(hs)}]')
        for s, c in gsrc[g].most_common(3):
            print(f'            {c:>5}  {s}')

    if a.path:
        # 反向找一条到该实例的路径并正序打印
        if a.path not in seen_inst:
            sys.exit(f'{a.path} 不在 ≤{a.hops} 跳闭包内')
        rev, cur = [], None
        for o, (an, h, pre) in anc.items():
            if yof.get(a.path) == o:
                cur = o
                break
        while cur is not None:
            rev.append(cur)
            cur = anc[cur][2]
        for n in reversed(rev):
            dn, dt, dp = drv.get(n, ('?', '?', '?'))
            tag = '' if not named(n) else '  <具名>'
            print(f'   {dn}({dt}).{dp} -> {n}{tag}')


if __name__ == '__main__':
    main()
