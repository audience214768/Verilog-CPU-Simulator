#!/usr/bin/env python3
"""census_src.py —— 把 census.tcl 的全设计普查按 **RTL src** 归族。

用法: census_src.py <opt目录> <census.txt> <pathsrc.py所在目录> [top模块名]

census.tcl 只给匿名 cell 名 (如 `u_mem.u_dc.u_arr.lane_1/rd_out[287]` 这种还带实例路径的,
以及 `_088847_` 这种 ABC 造出来的)。本脚本复用 pathsrc 的**位置对齐 join**
(mapped.v 的 cell 顺序 ↔ design.json 的 cell 顺序), 把每条普查行的**起点和终点**各归到一个
RTL src 行, 再按 (起点/终点, src) 聚合 ⇒ 直接回答"哪个 RTL 家族的路径最长、有几条"。

这是"预注册结构判据"的**验收工具**: 判据写成"某族作为终点应跌出 4000 榜 / 应降到 X 以下"后,
跑一遍就知道兑现没有, 不必每次人工翻 timing.rpt。

注意 (2026-10-11 踩过): 转义标识符里**含空格** (`\\u_mem.u_dc.rdata_w [569]`),
按 `\\S+` 切会把它截断 ⇒ 这里只按空白切分再 `rsplit("/", 1)[0]` 取实例路径。

远端跑法 (design.json 不出远端): 把本文件 scp 到远端 runs/<id>/, 然后
    python3 census_src.py <opt> <census.txt> <pathsrc.py所在目录>
"""
import sys, collections
sys.path.insert(0, sys.argv[3])
import pathsrc

d, cen = sys.argv[1], sys.argv[2]
top = sys.argv[4] if len(sys.argv) > 4 else "student_top"
mapped = pathsrc.read_mapped(d + "/mapped.v")
srcmap = pathsrc.join(mapped, pathsrc.read_design(d + "/design.json", top))
print("join ok:", len(srcmap), "cells")

def look(c):
    for k in (c, "\\" + c):
        if k in srcmap:
            return srcmap[k][1]
    return None

fams = collections.defaultdict(lambda: [0.0, 0, None])
for ln in open(cen, errors="replace"):
    if not ln.startswith("CENSUS "):
        continue
    p = ln.split()
    delay = float(p[2])
    for tag, raw in (("S", p[3]), ("E", p[4])):
        c = raw.rsplit("/", 1)[0]
        key = (tag, look(c))
        f = fams[key]
        f[1] += 1
        if delay > f[0]:
            f[0] = delay
            f[2] = (p[3], p[4])
for (tag, src), (mx, n, ex) in sorted(fams.items(), key=lambda kv: -kv[1][0])[:400]:
    print(f"{tag} max={mx:7.4f} n={n:5d}  src={src}")
    if ex:
        print(f"      最差例: {ex[0]} -> {ex[1]}")
