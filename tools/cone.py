#!/usr/bin/env python3
"""cone.py —— 组合锥分析。回答两个 path.py / pathsrc.py 都答不了的问题:

  ① `--cone <cell>`: **这个信号到底驱动了多少东西?**
     官方 timing.rpt 只给 5 条路径(`-group_path_count 5` 写死在 scripts/timing.tcl 里),
     看单条路径会得出"瓶颈是某一段链"的错误结论。实测: ic1k 最差路径的起点(8 个 load 在飞
     指针触发器)一个 bit 的组合锥就有 4 万个 cell、到达 6 千多个触发器, 遍布**每一个**模块
     —— 这种形状下"挪一段寄存器"必然是零和的(§15.10.26 实测证实)。

  ② `--path [N]`: **timing.rpt 第 N 条路径的每一级, 最近的上游寄存器边界在哪个模块?**
     手法: 以**所有触发器**为源做一次多源正向 BFS, 得到每个组合 cell 的
     (到最近上游触发器的级数, 那些触发器的模块)。路径逐级打印这个标签, 就把
     100 级落到"哪一段属于哪一级流水"。
     **限制(必须知道)**: 标签取的是**最近**的边界, 不是路径真正的来路 —— 一个门只要有任何
     一个输入来自某模块的触发器就会被标成那个模块。它能回答"这段逻辑贴着谁的寄存器",
     不能单独回答"这条路径穿过了谁"。要模块级的**确定**归因只能用 MODE=diagnose(保层次)。

用法:
  tools/cone.py <dir> --cone _141944_        # <dir> 含 mapped.v / design.json / timing.rpt
  tools/cone.py <dir> --path                # 第 0 条(最差)路径
  tools/cone.py <dir> --path 3 --max-mod 6  # 只看前 6 个模块标签的级
"""
import argparse
import collections
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pathsrc as P                                            # noqa: E402

# mapped.v 的实例行: "  TYPE _123_ (" 或 FakeRAM 那种转义名 "  TYPE \u_mem.u_ic.u_arr.lane_0  ("
INST_RE = re.compile(r'^  (\S+)\s+(\\\S+|_\d+_)\s*\($')
PIN_RE = re.compile(r'\.(\S+?)\s*\(\s*([^)\s]*)\s*\)')

# 输出引脚只有这三个。已按实际网表核对全集: 组合门输出 .Y, 触发器输出 .QN(本设计 8315 个
# 触发器全部是 QN 型), TIEHI/TIELO 输出 .H/.L(常量, 不算时序源)。.E 是 5 输入门的第 5 个
# **输入**(NOR5/NAND5/OR5/AND5), 不是输出 —— 这里漏一个就会把扇入当扇出, 锥会算错。
OUT_PINS = ('Y', 'Q', 'QN')


def read_netlist(path):
    """mapped.v -> (order[(名字,类型)], insts{名字: (类型, {引脚: 网})})"""
    order, insts = [], {}
    lines = Path(path).read_text().split('\n')
    i = 0
    while i < len(lines):
        m = INST_RE.match(lines[i])
        if not m:
            i += 1
            continue
        ty, name = m.group(1), m.group(2)
        j, buf = i + 1, ''
        while j < len(lines) and ');' not in buf:
            buf += lines[j]
            j += 1
        insts[name] = (ty, {pm.group(1): pm.group(2) for pm in PIN_RE.finditer(buf)})
        order.append((name, ty))
        i = j
    return order, insts


def build_loads(insts):
    """网 -> [(负载实例, 类型, 引脚)]"""
    loads = collections.defaultdict(list)
    for n, (ty, pins) in insts.items():
        for pin, net in pins.items():
            if net:
                loads[net].append((n, ty, pin))
    return loads


def out_nets(insts, name):
    pins = insts[name][1]
    return [pins[p] for p in OUT_PINS if p in pins and pins[p]]


def make_mod_of(srcmap):
    def mod_of(cell):
        e = srcmap.get(cell)
        if not e or not e[1]:
            return None
        m = re.search(r'/verilog/(\S+?):', e[1])
        return m.group(1) if m else e[1]
    return mod_of


def do_cone(cell, insts, loads, mod_of):
    """正向组合锥: 从 cell 的输出网出发, 到触发器为止。"""
    seen = {cell}
    q = collections.deque((n, 1) for n in out_nets(insts, cell))
    n_comb = 0
    flops = collections.Counter()
    depth = collections.defaultdict(list)
    while q:
        net, d = q.popleft()
        for n, ty, _pin in loads.get(net, []):
            if n in seen:
                continue
            seen.add(n)
            if ty.startswith('DFF'):
                m = mod_of(n) or '?（无 src）'
                flops[m] += 1
                depth[m].append(d)
            else:
                n_comb += 1
                for o in out_nets(insts, n):
                    if o and o not in seen:
                        q.append((o, d + 1))
    return n_comb, flops, depth


def do_path(srcdir, insts, loads, srcmap, mod_of, idx, max_mod, only_src):
    """路径逐级打印"最近的上游寄存器边界"。"""
    dist, label = {}, {}
    q = collections.deque()
    for n, (ty, _pins) in insts.items():          # 源 = 所有触发器
        if ty.startswith('DFF'):
            dist[n] = 0
            label[n] = frozenset([mod_of(n) or '?（无 src）'])
            q.append(n)
    while q:                                      # 多源正向 BFS
        c = q.popleft()
        for o in out_nets(insts, c):
            for n, ty, _pin in loads.get(o, []):
                if ty.startswith('DFF'):
                    continue
                if n in dist:
                    if dist[n] == dist[c] + 1:
                        label[n] = label[n] | label[c]
                    continue
                dist[n] = dist[c] + 1
                label[n] = label[c]
                q.append(n)

    paths = P.read_paths(srcdir / 'timing.rpt')
    p = paths[idx]
    print(f"已标注组合 cell {len(dist)} 个; 路径 #{idx} {p['start']} → {p['end']}  "
          f"slack={p['slack']} ns  {len(p['lvls'])} 级")
    print(f"\n{'级':>4} {'到达':>9} {'距边界':>7} {'扇出':>5} {'类型':<26} 最近寄存器边界模块")
    prev = object()
    for i, l in enumerate(p['lvls']):
        c = l['cell']
        if only_src and not srcmap.get(c, (None, None, None))[1]:
            continue
        lab = label.get(c)
        mods = "—（无上游触发器）" if lab is None else \
               ",".join(sorted((x or '?').split('/')[-1] for x in lab)[:max_mod])
        if mods != prev:
            print(f"    ---- {mods} ----")
            prev = mods
        print(f"{i:>4} {l['time']:>9.4f} {str(dist.get(c)):>7} {l['fanout']:>5} "
              f"{l['type'][:26]:<26} {mods}")
    print("\n距离是到**最近**上游触发器的级数, 标签取的是那些触发器的模块 —— 它是"
          "\"这段逻辑贴着谁的寄存器\", 不是\"这条路径穿过了谁\"。")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--top", default="student_top")
    ap.add_argument("--cone", metavar="CELL", help="分析该 cell 的正向组合锥")
    ap.add_argument("--path", nargs='?', type=int, const=0, help="timing.rpt 第 N 条路径 (默认 0)")
    ap.add_argument("--max-mod", type=int, default=3, help="每级最多显示几个模块标签")
    ap.add_argument("--only-src", action="store_true", help="只打带 src 的级")
    args = ap.parse_args()

    d = Path(args.dir)
    for f in ("mapped.v", "design.json"):
        if not (d / f).is_file():
            sys.exit(f"缺少 {d / f}")
    order, insts = read_netlist(d / 'mapped.v')
    srcmap = P.join(order, P.read_design(d / 'design.json', args.top))
    mod_of = make_mod_of(srcmap)
    loads = build_loads(insts)
    print(f"网表: {len(insts)} 个实例")

    if args.cone:
        if args.cone not in insts:
            sys.exit(f"网表里没有 {args.cone}")
        n_comb, flops, depth = do_cone(args.cone, insts, loads, mod_of)
        e = srcmap.get(args.cone, (None, None, None))
        print(f"\n{args.cone} ({insts[args.cone][0]})  src={e[1]}")
        print(f"正向组合锥: {n_comb} 个组合 cell, 到达 {sum(flops.values())} 个触发器")
        print(f"\n{'触发器':>8}  {'最短到达级数':>10}  模块")
        for k, v in flops.most_common():
            print(f"{v:>8}  {min(depth[k]):>10}  {k}")
        print("\n交叉验证: 用官方 timing.rpt 的终点直方图对一遍 "
              "(tools/census.tcl 放大路径数, 见 tools/README.md)。")
        return

    if args.path is not None:
        do_path(d, insts, loads, srcmap, mod_of, args.path, args.max_mod, args.only_src)
        return

    ap.error("至少要给 --cone 或 --path")


if __name__ == "__main__":
    main()
