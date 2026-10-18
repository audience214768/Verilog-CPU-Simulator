#!/usr/bin/env python3
"""D$ 单口预算 + 偷读口归因 + store 行局部性（K010 树波形口径）。

背景：vcd_bubble.py 的 S0 把"读被偷"记成一类，但不说是谁偷的。本工具直接读
dcache.v 的判决信号，回答三个问题：
  1. 端口被谁占：load 查表 / store RMW 读 / RMW 写 / 填充安装写；
  2. 查表读被偷时，上一拍是哪个不可重放的读（sram_we_w / wb_cap_w / rmw_rd_w / probe 硬抢）；
  3. 提交 store 的行局部性 —— K 行写合并缓冲能把 RMW 次数降到多少（窗口按笔数）。

结构事实：D$ 宏写粒度 = 一整路（544 位），故每笔 store 必须读-改-写；
store RMW 读/写各占一拍单口。用法: tools/vcd_dcport.py <vcd> [WINDOW]
"""
import sys

path = sys.argv[1]
WINDOW = int(sys.argv[2]) if len(sys.argv) > 2 else 16

D = 'student_top.u_mem.u_dc.'
WANT = {
    'student_top.rst_n': 'rst',
    'student_top.u_cpu.halt_q_r': 'halt',
    'student_top.u_cpu.sw_valid': 'sv',
    'student_top.u_cpu.sw_addr': 'sa',
    D + 'busy': 'busy',
    D + 'lk_v_r': 'lkv',
    D + 'lk_wait_r': 'lkwait',
    D + 'lk_replay_r': 'lkrep',
    D + 'lk_miss_r': 'lkmiss',
    D + 'rd_ok_r': 'rdok',
    D + 'hit_raw_w': 'hraw',
    D + 'rsp_busy': 'rspb',
    D + 'ms_fire_w': 'msf',
    D + 'sram_we_w': 'we',
    D + 'wb_cap_w': 'wbcap',
    D + 'rmw_rd_w': 'rmwrd',
    D + 'rmw_v_r': 'rmwv',
    D + 'probe_steal_w': 'psteal',
    D + 'fill_wr_w': 'fwrw',
    D + 'fill_wr_r': 'fwrr',
    D + 'fill_start_w': 'fstart',
}

scope, id2n = [], {}
with open(path, errors='replace') as f:
    for line in f:
        s = line.strip()
        if s.startswith('$scope'):
            scope.append(s.split()[2]); continue
        if s.startswith('$upscope'):
            scope.pop(); continue
        if s.startswith('$enddefinitions'):
            break
        if s.startswith('$var'):
            p = s.split(); full = '.'.join(scope[1:] + [p[4]])
            if full in WANT:
                id2n[p[3]] = WANT[full]
missing = set(WANT.values()) - set(id2n.values())
if missing:
    print('# MISSING SIGNALS:', sorted(missing), file=sys.stderr)

v = {n: 0 for n in WANT.values()}
prev = dict(v)
C = dict(cyc=0, lk=0, rmwrd=0, rmwv=0, fwrw=0, fwrr=0, wbcap=0, psteal=0,
         sv=0, rmw_start=0)
steal = {}
addrs = []
started = False
with open(path, errors='replace') as f:
    for line in f:
        if not started:
            if line.startswith('$enddefinitions'):
                started = True
            continue
        c = line[0]
        if c == '#':
            if int(line[1:]) & 1:
                continue
            if v['rst'] and not v['halt']:
                C['cyc'] += 1
                for k in ('rmwrd', 'rmwv', 'fwrw', 'fwrr', 'wbcap', 'psteal', 'sv'):
                    C[k] += 1 if v[k] else 0
                if v['lkv'] and not v['lkwait']:
                    C['lk'] += 1
                if v['rmwrd'] and not prev['rmwrd']:
                    C['rmw_start'] += 1
                if v['sv']:
                    addrs.append(v['sa'])
                lkb = v['lkv'] and not (v['hraw'] and not v['rspb']) and not v['msf']
                if v['busy'] and lkb and not v['lkwait'] and not v['lkrep'] \
                        and not v['lkmiss'] and not v['rdok']:
                    src = []
                    if prev['rmwv']: src.append('RMW写')
                    if prev['we'] and not prev['rmwv']: src.append('填充写')
                    if prev['wbcap']: src.append('wb_cap')
                    if prev['rmwrd']: src.append('RMW读')
                    if prev['psteal']: src.append('probe抢')
                    if prev['fstart']: src.append('fill_start')
                    key = '+'.join(src) if src else '未归因'
                    steal[key] = steal.get(key, 0) + 1
            prev = dict(v)
        elif c in '01xzXZ':
            n = id2n.get(line[1:].strip())
            if n is not None:
                v[n] = 1 if c == '1' else 0
        elif c in 'bB':
            sp = line[1:].split()
            if len(sp) == 2:
                n = id2n.get(sp[1])
                if n is not None:
                    v[n] = int(sp[0].replace('x', '0').replace('z', '0'), 2)

n = max(C['cyc'], 1)
p = lambda k: f"{C[k]}({C[k] * 100 // n}%)"
print(f"cyc={C['cyc']} 提交store={C['sv']} | 端口占用: load查表 {p('lk')}"
      f" + RMW读 {p('rmwrd')} + RMW写 {p('rmwv')} + 填充写 {p('fwrr')}"
      f" + wb_cap {p('wbcap')} + probe抢 {p('psteal')}")
print(f"store RMW 起始 {C['rmw_start']} 次 (每笔=读+写两拍);"
      f" 填充安装 {C['fwrw']} 次")
tot = sum(steal.values())
print(f"查表读被偷 {tot} 拍归因:")
for k, x in sorted(steal.items(), key=lambda kv: -kv[1]):
    print(f"  {k}: {x}({x * 100 // max(tot, 1)}%)")

N = len(addrs)
if N > 1:
    same = sum(1 for i in range(1, N) if addrs[i] >> 6 == addrs[i - 1] >> 6)
    print(f"提交 store {N} 笔 | 与上一笔同 64B 行 {same}({same * 100 // (N - 1)}%)")
    for K in (1, 2, 4):
        buf, ins = [], 0
        for i, a in enumerate(addrs):
            ln = a >> 6
            buf = [(l, j) for (l, j) in buf if i - j <= WINDOW]
            if not any(l == ln for (l, j) in buf):
                ins += 1
                if len(buf) >= K:
                    buf.pop(0)
                buf.append((ln, i))
        print(f"  K={K} 行缓冲(窗口 {WINDOW} 笔): RMW {ins} 次, 相对提交数省"
              f" {100 - ins * 100 // N}%")
