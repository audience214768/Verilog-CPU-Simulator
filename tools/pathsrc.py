#!/usr/bin/env python3
"""pathsrc.py —— 关键路径 × RTL 归因: 把 timing.rpt 里的匿名 cell 找回它来自哪一行 Verilog。

为什么需要它: post-ABC 网表里只有匿名名 (`_141944_`), `timing.rpt` 也就只有匿名名,
而 `write_json` 写出的 `design.json` 和 `write_verilog` 写出的 `mapped.v` 是**同一张网表的
两种序列化** —— `design.json` 用 `$abc$...$...` 名, `mapped.v` 用合法化后的 `_NNNNN_` 名,
两者**名字零重叠**, 所以按名字 join 是不可能的。

可行的办法是**按位置 join**: 两次序列化都把 cell 按同一顺序写出。于是
`mapped.v` 里第 k 个实例 ↔ `design.json` 里第 k 个 cell ↔ 该 cell 的 `src` 属性 (行号)。

**限制 (必须知道, 否则会得出错误结论)**: ABC 自己造出来的组合门**没有 `src`** ——
只有触发器还留着 Yosys 从 RTL 继承的 `src`。所以本工具能可靠回答的是
"这条路径的起点/终点/中间的时序元件来自哪个文件的哪一行", 中间那些组合级只能拿到
`?`。要归因组合级, 用 `MODE=diagnose` (保层次, 模块限定名) 配 `tools/path.py`。

用法:
  tools/pathsrc.py runs/ic1k/build/synth_ic1k/opt            # 分析该目录下的最差路径
  tools/pathsrc.py <dir> --path 2                            # 第 3 条路径
  tools/pathsrc.py <dir> --only-src                          # 只打 src 段 (跳组合级)
"""
import argparse
import re
import sys
from pathlib import Path

# mapped.v 实例行: "  TYPE _123_ (" 或 FakeRAM 包装器那种转义名 "  TYPE \u_mem.u_ic.u_arr.lane_0  ("
CELL_RE = re.compile(r'^  (\S+)\s+(\\\S+|_\d+_)\s+\($')
# timing.rpt 每级驱动行: Fanout Cap Slew Delay Time edge cell/pin (TYPE)
LVL_RE = re.compile(r'^\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)'
                    r'\s+([\^v])\s+(\S+)/(\S+)\s+\((\S+)\)\s*$')


def read_mapped(path):
    """mapped.v 里实例的**出现顺序** —— 位置 join 的一侧。"""
    order = []
    with open(path) as fh:
        for line in fh:
            m = CELL_RE.match(line)
            if m:
                order.append((m.group(2), m.group(1)))       # (名字, 类型)
    return order


def _skip_string(text, i):
    """i 指向开引号, 返回闭引号的下标。"""
    return text.index('"', i + 1)


def _brace_block(text, i):
    """i 指向 '{', 返回匹配的 '}' 的下标 (跳过字符串里的花括号)。"""
    depth = 0
    while True:
        ch = text[i]
        if ch == '"':
            i = _skip_string(text, i) + 1
            continue
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1


def read_design(path, top):
    """design.json 里 top 模块的 cell 顺序 + 各自的 src。

    不整份 json.load —— 49 MB 的 design.json 解析成 Python 对象要几百 MB, 而这里
    只需要 (名字, 类型, src) 三元组。手写扫描 + 花括号配对即可。
    """
    text = Path(path).read_text()
    m = re.search(r'\n    "%s": \{\n      "attributes":' % re.escape(top), text)
    if not m:
        sys.exit(f"design.json 里找不到模块 {top}")
    cells = text.index('"cells": {', m.start())
    i = cells + len('"cells": {')
    order = []
    while True:
        while i < len(text) and text[i] in ' \n\r\t,':
            i += 1
        if text[i] == '}':                                   # cells 字典结束
            break
        if text[i] != '"':
            sys.exit(f"design.json 解析错位 @{i}: {text[i:i + 60]!r}")
        j = _skip_string(text, i)
        name = text[i + 1:j]
        k = text.index('{', j)
        end = _brace_block(text, k)
        block = text[k:end + 1]
        ty = re.search(r'"type": "([^"]+)"', block).group(1)
        src = re.search(r'"src": "([^"]+)"', block)
        up = re.search(r'"hdlname": "([^"]+)"', block)
        order.append((name, ty, src.group(1) if src else None,
                      up.group(1) if up else None))
        i = end + 1
    return order


def join(mapped, design):
    """位置 join, 并核对两侧的 cell 类型逐个相同 —— 不同就说明顺序假设不成立, 必须停。

    返回的字典**以 mapped.v 的名字为键** —— timing.rpt 和 mapped.v 用的是同一套
    `_NNNNN_` 名, 而 design.json 用的是 `$abc$...` 名, 两者零重叠, 所以键必须取前者。
    """
    if len(mapped) != len(design):
        sys.exit(f"cell 数不等: mapped.v {len(mapped)} vs design.json {len(design)}")
    bad = [(i, mapped[i], design[i]) for i in range(len(mapped))
           if mapped[i][1] != design[i][1]]
    if bad:
        i, mp, ds = bad[0]
        sys.exit(f"位置 join 失配 {len(bad)}/{len(mapped)} 个, 首个 @{i}: "
                 f"mapped={mp[1]} design={ds[1]} —— 顺序假设不成立, 不得继续")
    return {mapped[i][0]: design[i][1:] for i in range(len(mapped))}


def read_paths(rpt):
    """timing.rpt 里的 (startpoint, endpoint, slack, [每级]) 列表。"""
    paths, cur = [], None
    for line in open(rpt):
        s = re.match(r'^Startpoint: (\S+)', line)
        if s:
            cur = {"start": s.group(1), "end": None, "slack": None, "lvls": []}
            paths.append(cur)
            continue
        e = re.match(r'^Endpoint: (\S+)', line)
        if e and cur is not None:
            cur["end"] = e.group(1)
            continue
        k = re.match(r'^\s*(-?[\d.]+)\s+slack \((?:MET|VIOLATED)\)\s*$', line)
        if k and cur is not None:
            cur["slack"] = float(k.group(1))
            continue
        m = LVL_RE.match(line)
        if m and cur is not None:
            cur["lvls"].append({"fanout": int(m.group(1)), "delay": float(m.group(4)),
                                "time": float(m.group(5)), "cell": m.group(7),
                                "pin": m.group(8), "type": m.group(9)})
    return paths


def base_cell(name):
    """诊断模式的名字形如 u_mem/_51198_, 取最后一段。"""
    return name.rsplit('/', 1)[-1]


def net_run(mapped, srcmap, cell):
    """网表里**紧挨着**该 cell、且 src 相同的一整段 —— 用来核对向量位宽。

    例: 起点若是 `ld_wr_p`(4b)+`ld_rd_p`(4b), 该段应当恰好 8 个异步复位触发器。
    这是"归因没认错人"的独立佐证: 只看 src 字符串可能撞上同名行号的巧合。
    """
    i = next((k for k, (n, _) in enumerate(mapped) if n == cell), None)
    if i is None:
        return None
    src = srcmap[cell][1]
    lo = hi = i
    while lo > 0 and srcmap[mapped[lo - 1][0]][1] == src:
        lo -= 1
    while hi + 1 < len(mapped) and srcmap[mapped[hi + 1][0]][1] == src:
        hi += 1
    types = {}
    for k in range(lo, hi + 1):
        types[mapped[k][1]] = types.get(mapped[k][1], 0) + 1
    return (hi - lo + 1, i - lo, types, mapped[lo][0], mapped[hi][0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir", help="含 design.json / mapped.v / timing.rpt 的目录")
    ap.add_argument("--top", default="student_top")
    ap.add_argument("--path", type=int, default=0, help="第几条路径 (0 = 最差)")
    ap.add_argument("--all", action="store_true", help="所有路径的起终点摘要")
    ap.add_argument("--only-src", action="store_true", help="只打带 src 的级")
    args = ap.parse_args()

    d = Path(args.dir)
    for f in ("design.json", "mapped.v", "timing.rpt"):
        if not (d / f).is_file():
            sys.exit(f"缺少 {d / f}")

    mapped = read_mapped(d / "mapped.v")
    srcmap = join(mapped, read_design(d / "design.json", args.top))
    paths = read_paths(d / "timing.rpt")
    print(f"位置 join: {len(srcmap)} 个 cell, 类型逐个相同 ✓   路径数: {len(paths)}")

    if args.all:
        seen = {}
        for i, p in enumerate(paths):
            seen.setdefault(p["end"], []).append(i)
        print(f"endpoint 去重后 {len(seen)} 个:")
        for end, idx in seen.items():
            info = srcmap.get(base_cell(end), (None, None, None))
            print(f"  {end:<14} 路径 {idx}   src={info[1]}")
        return

    p = paths[args.path]
    print(f"\n路径 #{args.path}  {p['start']} → {p['end']}   slack={p['slack']} ns  "
          f"{len(p['lvls'])} 级")
    for tag, cell in (("起点", p["start"]), ("终点", p["end"])):
        ty, src, up = srcmap.get(base_cell(cell), (None, None, None))
        print(f"  {tag}: {cell:<12} {ty:<28} src={src or '（无 src）'}")
        r = net_run(mapped, srcmap, base_cell(cell))
        if r and r[0] > 1:
            n, off, types, lo_name, hi_name = r
            hist = ", ".join(f"{v}×{k}" for k, v in sorted(types.items(), key=lambda x: -x[1]))
            print(f"        网表里紧挨着同 src 的一段共 {n} 个 (本 cell 是第 {off} 个): "
                  f"{lo_name}..{hi_name}")
            print(f"        {hist}")

    print(f"\n{'级':>4} {'时间':>8} {'增量':>8} {'扇出':>5}  {'cell':<12} "
          f"{'引脚':<6} {'类型':<26} src")
    nsrc = 0
    for i, l in enumerate(p["lvls"]):
        src = srcmap.get(l["cell"], (None, None, None))[1]
        if src:
            nsrc += 1
        if args.only_src and src is None:
            continue
        print(f"{i:>4} {l['time']:>8.4f} {l['delay']:>8.4f} {l['fanout']:>5}  "
              f"{l['cell']:<12} {l['pin']:<6} {l['type']:<26} {src or '?'}")

    print(f"\n本路径 {len(p['lvls'])} 级里只有 {nsrc} 级带 src (起点那一级; 终点是末级负载, "
          f"不出现在驱动行里)。")
    print("中间组合级显示 ? 不是查表失败: ABC 自己造的门没有 src, 只有触发器留着。")
    print("要归因组合级, 用 MODE=diagnose (保层次, 出 u_xxx/ 限定名) 配 tools/path.py。")


if __name__ == "__main__":
    main()
