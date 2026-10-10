#!/usr/bin/env python3
"""diagnose 网表: 把关键路径的**跨模块边界**落到具名端口/网上。"""
import re, sys
from pathlib import Path

D = Path(sys.argv[1])
MOD = re.compile(r'^module (\S+)\s*\(')
INST = re.compile(r'^  (\S+)\s+(\S+)\s+\($')
PORT = re.compile(r'^\s+\.(\S+?)\((\S+)\)\s*,?\s*$')
DECL = re.compile(r'^\s+(input|output|inout)\s+(\[[^\]]*\]\s*)?(\S+)\s*;')

mv = {}          # 模块 -> {cell: {port: net}}
ports = {}       # 模块 -> {'in': set, 'out': set}
cur = None; cell = None
for line in open(D / "mapped.v"):
    m = MOD.match(line)
    if m:
        cur = m.group(1); cur = cur[1:] if cur.startswith('\\') else cur
        mv[cur] = {}; ports[cur] = {'in': set(), 'out': set()}; cell = None
        # 端口表在 module 行的参数列表里
        pl = line[line.index('('):]
        continue
    if line.startswith('endmodule'):
        cur = None; continue
    if cur is None: continue
    d = DECL.match(line)
    if d:
        k = {'input': 'in', 'output': 'out', 'inout': 'out'}[d.group(1)]
        ports[cur][k].add(d.group(3)); continue
    if cell is None:
        i = INST.match(line)
        if i:
            cell = i.group(2); mv[cur][cell] = {'__type__': i.group(1)}; continue
    else:
        if line.rstrip().endswith(');'):
            p = PORT.match(line.replace(');', '),'))
            if p: mv[cur][cell][p.group(1)] = p.group(2)
            cell = None; continue
        p = PORT.match(line)
        if p: mv[cur][cell][p.group(1)] = p.group(2)
print(f"mapped.v: {len(mv)} 模块, {sum(len(v) for v in mv.values())} 例化", file=sys.stderr)

# ---- 复用时序报告 + join 的层次解析 ----
sys.argv = ['x', str(D)]
g = {'__name__': '__main__'}
exec(open('/tmp/diag_join.py').read().split("if len(sys.argv) > 2")[0], g)
J = g['J']

def walk(inst_path):
    """返回 [(模块名, 实例名)] 层次链 + 末模块"""
    parts = inst_path.split('.')
    chain = []; mod = 'student_top'
    for p in parts[:-1]:
        c = J.get(mod, {}).get(p)
        if c is None: return chain, mod
        chain.append((mod, p)); mod = c[0]
    return chain, mod

LVL = re.compile(r'^\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)'
                 r'\s+([\^v])\s+(\S+)/(\S+)\s+\((\S+)\)\s*$')
paths, cur_p = [], None
for line in open(D / "timing.rpt"):
    s = re.match(r'^Startpoint: (\S+)', line)
    if s: cur_p = {"start": s.group(1), "end": None, "lvls": []}; paths.append(cur_p); continue
    e = re.match(r'^Endpoint: (\S+)', line)
    if e and cur_p is not None: cur_p["end"] = e.group(1); continue
    m = LVL.match(line)
    if m and cur_p is not None:
        cur_p["lvls"].append((float(m.group(4)), float(m.group(5)), m.group(7), m.group(8), m.group(9)))

p = paths[0]
print(f"\n路径: {p['start']} -> {p['end']}  {len(p['lvls'])} 级")
prev_mod = None; prev = None
for k, (d, t, inst, pin, ty) in enumerate(p['lvls']):
    chain, mod = walk(inst.replace('/', '.'))
    if prev_mod is not None and mod != prev_mod:
        pcell = prev[2].split('/')[-1]          # 局部名
        ppin  = prev[3]
        pmod  = prev_mod
        net = mv.get(pmod, {}).get(pcell, {}).get(ppin, '??')
        print(f"\n>>> 第 {k} 级跨边界  {pmod.split(chr(92))[-1]} → {mod.split(chr(92))[-1]}"
              f"   累计 {t:.4f} ns")
        print(f"    上一级: {pcell}/{ppin} ({prev[4]})  出网 = {net}"
              + ("  [= 本模块输出端口]" if net in ports.get(pmod, {}).get('out', set()) else ""))
        ncell = inst.split('/')[-1]
        print(f"    下一级: {ncell} ({ty}) 在 {mod.split(chr(92))[-1]} 里的连接 = "
              f"{ {a: b for a, b in mv.get(mod, {}).get(ncell, {}).items() if a != '__type__'} }")
        if len(chain) >= 1:
            par_mod, par_inst = chain[-1]
            pc = mv.get(par_mod, {}).get(par_inst.split('/')[-1], {})
            hit = [a for a, b in pc.items() if a != '__type__' and b == net]
            print(f"    父模块 {par_mod.split(chr(92))[-1]} 的例化 {par_inst.split('/')[-1]} 上, "
                  f"网 {net} 出现在端口 {hit}")
    prev = (d, t, inst, pin, ty); prev_mod = mod
