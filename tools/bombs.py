#!/usr/bin/env python3
"""bombs.py —— 官方流程(ABC 无 -constr)下的"热网 → RTL"归因。

**为什么需要它**: 官方 ABC 脚本是 `strash; &get -n; &fraig -x; &put` —— 没有
`set_driving_cell` / `set_load` ⇒ ABC 手里没有负载信息, 既不 buffer 也不 upsize,
**一个网上挂多少负载就是多少**(单元恒为最小尺寸)。于是 `--constr` 下被 buffer 树
吃掉的扇出, 在官方流程里直接变成延时: syn_offB 实测 24.2412 ns 里有 **21.7286 ns
只落在 3 个网上**(扇出 1601 / 113 / 1514, 本级 7.5134 / 5.8037 / 8.3308 ns),
而健康段只有 2.4483 ns。这就是官方流程唯一的主因。

`tools/path.py` 只回答"最差那 5 条路径"(官方 `timing.rpt` 写死 `-group_path_count 5`),
看不见"还有几条独立长路径、几个起点"。本工具用**全设计**的口径回答 Step 0 要的三件事:

  ① 全设计扇出直方图 + top-N 热网 (谁在付扇出税);
  ② 每个热网的**消费者族**: 每个消费者除热网外还吃哪些引脚、那些引脚的驱动源落在哪
     (RTL 文件:行) —— 这是判定"这是什么结构"(写使能 N×W? 读口 one-hot? 广播?) 的硬证据;
  ③ 每个热网的**起点族**: 正向组合锥穿过的触发器 (按 src 汇总) —— 回答"这个热网属于谁"。

**归因纪律** (`docs/plan.md` §15.10.31): **引脚名 / 扇出数 / 比值不可用于归因**;
只看**驱动源 + 低扇出兄弟网 + 位置**三样。真正的数据位往往是热网(共享中间字面量)的
**低扇出兄弟**。本工具的输出里, `src` 那一列才是证据, 引脚直方图只是线索。

**口径**: 只读 mapped.v (post-ABC, 官方判分产物) + design.json (`src` 来自位置 join,
见 `tools/pathsrc.py`) ⇒ **这里的数字可以当判据用**(不像宿主 yosys 的 preabc 产物,
那只是 RTL 名字的近似)。本工具不改任何 RTL、不产生任何频率数字。

用法:
  tools/bombs.py runs/offH/build/synth_offH/opt                  # 全设计普查 + top-12 热网归因
  tools/bombs.py <dir> --top 20 --depth 3                        # 看更多 / 驱动树更深
  tools/bombs.py <dir> --net _066955_                            # 定点一个网 (完整消费者 + 锥)
  tools/bombs.py <dir> --skip-cone                               # 只看 ①②, 跳过昂贵的正向锥
"""
import argparse
import collections
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pathsrc as P                                            # noqa: E402

# 实例块: "TYPE name ( .PIN(sig), ... );" —— mapped.v 每个连接独占一行, 必须跨行匹配
INST_RE = re.compile(r"([A-Za-z_\\][\w\\$.\[\]: ]*?)\s+(\S+)\s+\((.*?)\)\s*;", re.S)
CONN_RE = re.compile(r"\.(\w+)\s*\(\s*([^)]*?)\s*\)")
SKIP_CELLS = {"module", "endmodule", "input", "output", "wire", "reg", "assign"}
OUT_PINS = ("Y", "YN", "Q", "QN", "rd_out", "CO", "S", "CON")
IGNORE_PINS = ("CLK", "RESETN", "SETN", "VDD", "VSS")
# 时钟/复位不算"热网税": 它们本来就该有巨大扇出(走 CTS), 混进来会盖住真热点
POWER_NETS = {"clock", "reset"}


class Netlist:
    def __init__(self, optdir):
        d = Path(optdir)
        for f in ("mapped.v", "design.json"):
            if not (d / f).is_file():
                sys.exit(f"缺少 {d / f}")
        self.mapped = P.read_mapped(d / "mapped.v")
        self.srcmap = P.join(self.mapped, P.read_design(d / "design.json", "student_top"))
        text = (d / "mapped.v").read_text()
        self.cells = {}                      # name -> (type, {pin: net})
        self.loads = collections.defaultdict(list)   # net -> [(cell, pin)]
        self.drv = {}                        # net -> (cell, pin)
        for m in INST_RE.finditer(text):
            ctype, name, conns = m.group(1).strip(), m.group(2), m.group(3)
            if ctype in SKIP_CELLS:
                continue
            pins = {}
            for pin, sig in CONN_RE.findall(conns):
                sig = sig.strip()
                if not sig or re.fullmatch(r"\d+'[01xz]", sig):
                    continue
                pins[pin] = sig
                self.loads[sig].append((name, pin))
            self.cells[name] = (ctype, pins)
            for p in OUT_PINS:
                if p in pins:
                    self.drv[pins[p]] = (name, p)

    def is_dff(self, name):
        return self.cells[name][0].startswith("DFF")

    def src_of_cell(self, cell):
        """cell 的 (src, hdlname); 组合门是 ABC 造出来的, 没有 src ⇒ (None, type)。"""
        e = self.srcmap.get(cell)
        if e is None:
            return None, self.cells[cell][0]
        return e[1], e[2]


def hist(nl, top_n):
    h = collections.Counter()
    for net, ps in nl.loads.items():
        if net in POWER_NETS:
            continue
        fo = len(ps)
        for b in (1024, 512, 256, 128, 64, 32, 16):
            if fo >= b:
                h[b] += 1
                break
    print(f"cells={len(nl.cells)}  distinct_nets={len(nl.loads)}")
    for b in (1024, 512, 256, 128, 64, 32, 16):
        print(f"  fanout>={b:5d}: {h[b]}")
    print(f"\ntop {top_n} 热网 (已剔除 clock/reset):")
    ranked = sorted(((len(ps), n) for n, ps in nl.loads.items() if n not in POWER_NETS),
                    reverse=True)[:top_n]
    for fo, n in ranked:
        pins = collections.Counter(p for _, p in ps_of(nl, n)).most_common(3)
        d = nl.drv.get(n)
        dsc = f"{nl.cells[d[0]][0]}" if d else "[主输入]"
        print(f"  {fo:6d}  {n:32s} 驱动={dsc:26s} 负载脚={pins}")
    return [n for _, n in ranked]


def ps_of(nl, net):
    return nl.loads.get(net, [])


def consumer_families(nl, net, limit=4):
    """每个消费者除 net 外的输入引脚, 按**驱动源**汇总 —— 判定结构的主证据。"""
    agg = collections.Counter()
    for cell, _pin in ps_of(nl, net):
        ctype, pins = nl.cells[cell]
        for p, s in pins.items():
            if p in OUT_PINS or p in IGNORE_PINS or s == net:
                continue
            d = nl.drv.get(s)
            if d and nl.is_dff(d[0]):
                src, hdl = nl.src_of_cell(d[0])
                agg[("DFF", src, hdl)] += 1
            elif d:
                agg[("组合", None, nl.cells[d[0]][0])] += 1
            else:
                agg[("主输入", None, s)] += 1
    print(f"    消费者 {len(ps_of(nl, net))} 个; 另一侧输入按**驱动源**汇总:")
    dffs = [kv for kv in agg.items() if kv[0][0] == "DFF"]
    print(f"      —— 来自触发器 (这个网在门控/选择哪些寄存器位), top {limit}:")
    for (kind, src, hdl), c in sorted(dffs, key=lambda kv: -kv[1])[:limit]:
        print(f"      {c:5d}  {str(src)[:74]}")
    if not dffs:
        print("      (无: 消费者的另一侧全是组合门 ⇒ 这是**深层共享节点**, 不是阵列写使能)")
    comb = [kv for kv in agg.items() if kv[0][0] != "DFF"]
    print("      —— 其余 (组合门/主输入), top 4:")
    for (kind, src, hdl), c in sorted(comb, key=lambda kv: -kv[1])[:4]:
        print(f"      {c:5d}  [{kind}] {str(hdl)[:64]}")


def driver_tree(nl, net, depth):
    """热网的驱动锥 (只走驱动侧, 树形打印)。低扇出兄弟网会在这里露出来。"""
    def walk(n, d, seen):
        fo = len(ps_of(nl, n))
        e = nl.drv.get(n)
        if e is None:
            print("  " * d + f"{n} (fo {fo}) [主输入]")
            return
        cell = e[0]
        src, _ = nl.src_of_cell(cell)
        if nl.is_dff(cell):
            print("  " * d + f"{n} (fo {fo}) <= DFF src={src}")
            return
        if n in seen or d >= depth:
            print("  " * d + f"{n} (fo {fo}) <= {nl.cells[cell][0]} ...")
            return
        seen.add(n)
        ctype, pins = nl.cells[cell]
        print("  " * d + f"{n} (fo {fo}) <= {ctype} {cell}")
        for p, s in sorted(pins.items()):
            if p not in OUT_PINS and p not in IGNORE_PINS:
                walk(s, d + 1, seen)

    walk(net, 0, set())


def start_families(nl, net, max_pins=400000):
    """正向组合锥: 从 net 穿过组合门, 收集到达的触发器 (D 脚), 按 src 汇总。"""
    ends = collections.Counter()
    seen = set()
    stack = [net]
    visited = 0
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        for cell, pin in ps_of(nl, n):
            if pin in OUT_PINS or pin in IGNORE_PINS:
                continue
            visited += 1
            if nl.is_dff(cell):
                src, hdl = nl.src_of_cell(cell)
                ends[(src, hdl)] += 1
                continue
            if visited > max_pins:
                continue
            for p, s in nl.cells[cell][1].items():
                if p in OUT_PINS:
                    stack.append(s)
    return ends, visited


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir", help="含 mapped.v / design.json 的综合产物目录")
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--depth", type=int, default=3)
    ap.add_argument("--net", default=None, help="只分析这一个网 (完整版)")
    ap.add_argument("--skip-cone", action="store_true", help="跳过正向锥 (慢)")
    args = ap.parse_args()

    nl = Netlist(args.dir)
    print(f"位置 join: {len(nl.srcmap)} 个 cell ✓")

    if args.net:
        targets = [args.net]
    else:
        targets = hist(nl, args.top)

    for net in targets:
        print(f"\n{'=' * 78}\n热网 {net}: 扇出 {len(ps_of(nl, net))}")
        consumer_families(nl, net)
        print("    驱动锥:")
        driver_tree(nl, net, args.depth)
        if not args.skip_cone:
            ends, visited = start_families(nl, net)
            print(f"    正向锥: 访问 {visited} 个引脚, 到达 {len(ends)} 个触发器 (按 src):")
            for (src, hdl), c in ends.most_common(6):
                print(f"      {c:5d}  {str(src)[:70]}")


if __name__ == "__main__":
    main()
