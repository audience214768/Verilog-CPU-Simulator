#!/usr/bin/env python3
"""endattr.py —— 把一次路径普查的**起点/终点**按 RTL src 块归因: "频率墙住在哪几个寄存器块里"。

为什么需要它: `pathsrc.py` 一次只说一条路径; 而"墙的形状"(是断崖还是连续分布、多少个块在贡献)
只能看全量普查。本工具复用 pathsrc 的位置 join 把 census 的匿名名 (`_158744_/D`) 还原成
`文件.v:块首行`。

用法:
  tools/endattr.py <opt_dir> <census.log> [--line 3.333] [--top 12]
产出:
  ① 时延分带直方图 (看有没有断崖);
  ② 起点块 × 终点块 的条数/Σ超线 ns (Σ超线 = Σ(delay-线), 用来排"哪个块吃掉的超线总量最大");
  ③ 每个块自己的最差路径 (看"切完还要接上谁")。
"""
import argparse
import collections
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pathsrc  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir", help="含 mapped.v / design.json 的 opt 目录")
    ap.add_argument("census", help="CENSUS 行日志 (tools/census.tcl 产出)")
    ap.add_argument("--line", type=float, default=3.333, help="频率线 ns (默认 300 MHz)")
    ap.add_argument("--top", type=int, default=12)
    A = ap.parse_args()

    d = Path(A.dir)
    mp = pathsrc.read_mapped(d / "mapped.v")
    dj = pathsrc.read_design(d / "design.json", "student_top")
    j = pathsrc.join(mp, dj)

    def src(cell):
        e = j.get(cell)
        if e is None:
            return "?未找到"
        s = e[1]
        if s is None:
            return "(无 src)"          # PRF: Yosys 生成的大数组
        s = s.split("/work/verilog/")[-1]
        f, _, r = s.partition(":")
        return f + ":" + r.split(".")[0]

    rows = []
    for ln in open(A.census):
        if ln.startswith("CENSUS "):
            f = ln.split()
            rows.append((float(f[2]), f[3].rsplit("/", 1)[0], f[4].rsplit("/", 1)[0]))
    if not rows:
        sys.exit("没有 CENSUS 行")
    rows.sort(reverse=True)
    over = [r for r in rows if r[0] > A.line]
    print("路径 %d 条（%.4f ~ %.4f ns），线 %.3f ns ⇒ >线 %d 条\n"
          % (len(rows), rows[-1][0], rows[0][0], A.line, len(over)))

    print("=== 时延分带（0.2 ns 一带）")
    band = collections.Counter(round(r[0] * 5) / 5 for r in rows)
    for b in sorted(band, reverse=True):
        if b < A.line - 1.2:
            break
        print("  ≥%.1f ns %5d %s" % (b, band[b], "#" * min(60, band[b] // 20)))

    for idx, name in ((1, "起点"), (2, "终点")):
        c, w = collections.Counter(), collections.Counter()
        for r in over:
            k = src(r[idx])
            c[k] += 1
            w[k] += r[0] - A.line
        print("\n=== %s块（>线 %d 条，Σ超线 = Σ(delay-线)）" % (name, len(over)))
        print("  %-34s %6s %12s" % ("src", "条数", "Σ超线 ns"))
        for k, n in c.most_common(A.top):
            print("  %-34s %6d %12.1f" % (k, n, w[k]))

    print("\n=== 起点块 → 终点块（条数前 %d）" % A.top)
    cc = collections.Counter((src(r[1]).split(":")[0], src(r[2]).split(":")[0]) for r in over)
    for (a, b), n in cc.most_common(A.top):
        print("  %-26s → %-26s %5d" % (a, b, n))

    for idx, name, arrow in ((1, "起点块", "→"), (2, "终点块", "←")):
        best = {}
        for r in rows:
            best.setdefault(src(r[idx]), (r[0], src(r[3 - idx])))
        print("\n=== 每个%s的最差路径" % name)
        for k, (dd, other) in sorted(best.items(), key=lambda kv: -kv[1][0])[:A.top]:
            print("  %-30s %7.4f ns  %s %s" % (k, dd, arrow, other))


if __name__ == "__main__":
    main()
