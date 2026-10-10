#!/usr/bin/env python3
"""diagnose 网表: 逐模块位置 join (mapped.v 的 _NNNNN_ ↔ design.json 的 $abc$... + src)。"""
import re, sys
from pathlib import Path

D = Path(sys.argv[1])
INST = re.compile(r'^  (\S+)\s+(\S+)\s+\($')
MOD  = re.compile(r'^module (\S+)\s*\(')

def norm_mv(n):
    """mapped.v 的转义标识符: 前导 \\$ 是 $ 的转义, 其余 \\ 是字面反斜杠。"""
    return n[1:] if n.startswith('\\') else n

def norm_json(n):
    """design.json 里的 JSON 转义: \\\\ -> \\, \\" -> "。"""
    return n.replace('\\\\', '\\').replace('\\"', '"')

# ---- mapped.v: 每模块的实例顺序 ----
mv = {}
cur = None
for line in open(D / "mapped.v"):
    m = MOD.match(line)
    if m:
        cur = norm_mv(m.group(1)); mv[cur] = []; continue
    if line.startswith('endmodule'): cur = None; continue
    if cur is None: continue
    i = INST.match(line)
    if i: mv[cur].append((i.group(2), i.group(1)))
print(f"mapped.v 模块 {len(mv)}, 例化总数 {sum(len(v) for v in mv.values())}")

# ---- design.json: 每模块的 cell 顺序 ----
txt = (D / "design.json").read_text()
def skip_str(t, i): return t.index('"', i + 1)
def brace(t, i):
    d = 0
    while True:
        c = t[i]
        if c == '"': i = skip_str(t, i) + 1; continue
        if c == '{': d += 1
        elif c == '}':
            d -= 1
            if d == 0: return i
        i += 1
mods = {}
for m in re.finditer(r'\n    "((?:[^"\\]|\\.)*)": \{\n      "attributes":', txt):
    name = norm_json(m.group(1))
    k = txt.index('"cells": {', m.end()); i = k + len('"cells": {')
    cells = []
    while True:
        while i < len(txt) and txt[i] in ' \n\r\t,': i += 1
        if txt[i] == '}': break
        if txt[i] != '"': sys.exit("错位")
        j = skip_str(txt, i); cn = txt[i+1:j]
        b = txt.index('{', j); e = brace(txt, b); blk = txt[b:e+1]
        ty = re.search(r'"type": "((?:[^"\\]|\\.)*)"', blk)
        src = re.search(r'"src": "([^"]+)"', blk)
        hn = re.search(r'"hdlname": "((?:[^"\\]|\\.)*)"', blk)
        cells.append((cn, norm_json(ty.group(1)) if ty else None,
                      src.group(1) if src else None,
                      norm_json(hn.group(1)) if hn else None))
        i = e + 1
    mods[name] = cells
print(f"design.json 模块 {len(mods)}, cell 总数 {sum(len(v) for v in mods.values())}")

# ---- 位置 join ----
J = {}   # mapped 模块名 -> {cell名: (type, src, hdlname)}
bad = 0
for name, insts in mv.items():
    ds = mods.get(name)
    if ds is None:
        print(f"  !! design.json 缺模块 {name}"); bad += 1; continue
    if len(insts) != len(ds):
        print(f"  !! {name}: mapped {len(insts)} vs json {len(ds)}"); bad += 1; continue
    mism = [k for k in range(len(insts))
            if norm_mv(insts[k][1]).split('\\')[-1] != ds[k][1].split('\\')[-1]]
    if mism:
        print(f"  !! {name}: 类型失配 {len(mism)} 个, 首个 @{mism[0]} "
              f"{insts[mism[0]][1]} vs {ds[mism[0]][1]}"); bad += 1; continue
    J[name] = {insts[k][0]: ds[k][1:] for k in range(len(insts))}
print(f"join 成功 {len(J)}/{len(mv)} 个模块, 失败 {bad}")

# ---- 解析路径 ----
def resolve(inst_path):
    """'u_mem.u_dc._12384_' -> (模块限定路径, (type, src, hdlname))"""
    parts = inst_path.split('.')
    mod = 'student_top'
    for p in parts[:-1]:
        c = J.get(mod, {}).get(p)
        if c is None: return mod, None
        mod = c[0]             # 子模块类型 (实例的 hdlname 是局部名, 不能用来下钻)
    return mod, J.get(mod, {}).get(parts[-1])

if len(sys.argv) > 2 and sys.argv[2] == 'probe':
    for t in sys.argv[3:]:
        print(t, '->', resolve(t))
    sys.exit()

LVL = re.compile(r'^\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)'
                 r'\s+([\^v])\s+(\S+)/(\S+)\s+\((\S+)\)\s*$')
def show(which):
    paths, cur = [], None
    for line in open(D / "timing.rpt"):
        s = re.match(r'^Startpoint: (\S+)', line)
        if s: cur = {"start": s.group(1), "end": None, "lvls": []}; paths.append(cur); continue
        e = re.match(r'^Endpoint: (\S+)', line)
        if e and cur is not None: cur["end"] = e.group(1); continue
        m = LVL.match(line)
        if m and cur is not None:
            cur["lvls"].append((int(m.group(1)), float(m.group(4)), float(m.group(5)),
                                m.group(7), m.group(8), m.group(9)))
    p = paths[which - 1]
    print(f"\n===== 路径 {which}/{len(paths)}: {p['start']} -> {p['end']}  {len(p['lvls'])} 级 =====")
    for tag, cell in (("起点", p['start']), ("终点", p['end'])):
        mod, c = resolve(cell.replace('/', '.'))
        print(f"{tag}: {cell}  模块={mod.split(chr(92))[-1]}  type={c[0] if c else '?'}  "
              f"src={c[1] if c else '?'}  hdl={c[2] if c else '?'}")
    print(f"\n{'扇出':>5} {'增量':>8} {'累计':>8}  {'cell':<30} {'类型':<24} src")
    lastmod = None
    for (fo, d, t, inst, pin, ty) in p["lvls"]:
        mod, c = resolve(inst.replace('/', '.'))
        short = mod.split('\\')[-1]
        mark = '  <<< 跨模块' if short != lastmod else ''
        print(f"{fo:>5} {d:>8.4f} {t:>8.4f}  {inst:<30} {ty:<24} {(c[1] if c else '?')}{mark}")
        lastmod = short

for w in (1, 2):
    show(w)
