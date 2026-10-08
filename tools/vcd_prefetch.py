#!/usr/bin/env python3
"""官方 student_top 波形的**预取选择性**计数（零 RTL）: 每一条被取进 D-cache 的行,
在被驱逐之前到底被消费了几次 —— 用来判定"预取过滤 / 降级"是不是一个真候选。

做法 = 在 Python 里按 (set, way) 建影子, 用波形里的 vset_w / valid_r / tag_r 逐拍对齐:
  - 驱逐     (fill_start_w 上升沿) → 受害路**此刻就被清成无效** (dcache.v:765, 防"旧数据冒充
     新 tag"的假命中), 不是安装时才换 ⇒ 行的寿命 = install → **下次起填**, 结算并落直方图
  - install  (vset_w 上升沿)     → 在 (fill_set_r, fill_way_r) 记 (tag, 来源, 消费计数 = 0)
  - load 命中 (hit_raw_w)        → 该 (q_set_w, hit_way_w) 的计数 +1
  - store 命中 (any_st_hit_w)    → 该 (st_set_w, st_way_w) 的计数 +1
  - 填充旁路 (byp_valid_w, M2)   → 记在**正在填的那一行**上 (交付的是同一份数据)
来源判定: install 继承**起填那拍**锁存的理由 (go = 本拍需求 / pfst = 排队的需求 / dpfst = 预取);
三个理由互斥 (dcache.v:451), 与 vcd_mem.py 同一处锁存 ⇒ 两工具的 install 来源计数应相等 (对账用)。

⚠ 口径上的一处**不对称**(不是 bug, 读结论时必须记住): 需求缺失的数据是走 AXI 回包
(`rsp_busy` 那条)交给原始 load 的, **不算命中** ⇒ 需求行的"消费次数"从 0 起算,
它的第一次使用不计入。所以跨来源比较只看**趋势**(哪一类行更可能零消费), 不要当比率读。

自校验 (P9, 不成立则整轮作废):
  P9a 影子 valid 位图 == RTL `valid_r`   逐拍
  P9b 影子 tag == RTL `tag_r` (有效处)   逐拍
  RTL 的 reg 在事件后一拍生效 ⇒ 事件延迟一拍施加再比。

用法:
  D=testcases/perf_rsort
  ./build/sim $D/program.data $(cat $D/expected.txt) 100000000 10 /tmp/w.vcd
  tools/vcd_prefetch.py /tmp/w.vcd
波形 ≈8~10 KB/拍; 本脚本按行流式读, 内存恒定 (影子只有 DC_WAYS*DC_SETS 格)。
"""
import sys

path = sys.argv[1]
U = 'student_top.u_cpu.'
D = 'student_top.u_mem.u_dc.'
WANT = {
    'student_top.rst_n': 'rst_n',
    U + 'halt_q_r': 'halt',
    # 影子对齐 / 自校验
    D + 'valid_r': 'valid',
    D + 'tag_r': 'tag',
    # install
    D + 'vset_w': 'vset',
    D + 'new_set_w': 'nset',
    D + 'victim_way_w': 'vway',
    D + 'fill_tag_w': 'ftag',
    # 起填来源 (锁存用)
    D + 'fill_start_w': 'fstart',
    D + 'fill_go_w': 'fgo',
    D + 'pf_start_w': 'pfst',
    D + 'dpf_start_w': 'dpfst',
    # 消费事件
    D + 'hit_raw_w': 'hraw',
    D + 'hit_way_w': 'hway',
    D + 'q_set_w': 'qset',
    D + 'st_absorb': 'sthit',      # ★ 必须是 st_absorb 而不是 any_st_hit_w:
    D + 'st_set_w': 'stset',       #   any_st_hit_w = |st_hit_g 是**组合电平** (SQ 队首地址匹配
                                   #   就一直是 1), 按拍计数会把一条 store 放大成几百次
    D + 'st_way_w': 'stway',
    D + 'byp_valid_w': 'byp',
    D + 'fill_set_r': 'fset',
    D + 'fill_way_r': 'fway',
}

scope, id2n, WID = [], {}, {}
with open(path, 'r', errors='replace') as f:
    for line in f:
        s = line.strip()
        if s.startswith('$scope'):
            scope.append(s.split()[2])
            continue
        if s.startswith('$upscope'):
            scope.pop()
            continue
        if s.startswith('$enddefinitions'):
            break
        if s.startswith('$var'):
            p = s.split()
            full = '.'.join(scope[1:] + [p[4]])
            if full in WANT:
                id2n[p[3]] = WANT[full]
                WID[WANT[full]] = int(p[2])
missing = set(WANT.values()) - set(id2n.values())
if missing:
    print('# MISSING SIGNALS:', sorted(missing), file=sys.stderr)
    sys.exit(2)

VALID_W = WID['valid']
TAG_W   = WID['tag'] // VALID_W               # 每格 tag 位宽 (tag_r 是 WAYS*SETS 格拼起来的)
SETS    = 1 << WID['nset']
WAYS    = VALID_W // SETS
SRCNAME = ['需求(本拍)', '需求(排队)', '预取']
MASK_T  = (1 << TAG_W) - 1

# 影子: meta[(set, way)] = [tag, src, ld_hits, st_hits, byp_hits, install_cyc]
meta = {}
EV    = [0, 0, 0]                              # 被驱逐的行数 (按来源)
ZERO  = [0, 0, 0]                              # 其中零消费
HIST  = [[0, 0, 0, 0] for _ in range(3)]       # 消费次数 0 / 1 / 2 / >=3
LIFE  = [0, 0, 0]                              # 存活拍数求和
INST  = [0, 0, 0]                              # install 计数 (应与 vcd_mem.py 的来源计数相等)
HIT_SRC = [0, 0, 0, 0]                         # 命中事件按来源: 需求/排队/预取/未登记
BYPSRC  = [0, 0, 0]
C = dict(cyc=0, hraw=0, sthit=0, byp=0, vbad=0, tbad=0, unreg=0, excl=0)
CUR, PEND_HITS = 2, 0                          # 起填来源锁存 / 本次填充期间的旁路次数
in_evt = []                                    # {驱逐, 安装} 事件, 下一拍施加 (对齐 RTL 的 reg)
v = {n: 0 for n in WANT.values()}
p = {}
t, started = 0, False


def settle(set_, way, cyc):
    e = meta.get((set_, way))
    if e is None:
        return
    src = e[1]
    hits = e[2] + e[3] + e[4]
    EV[src] += 1
    if hits == 0:
        ZERO[src] += 1
    HIST[src][min(hits, 3)] += 1
    LIFE[src] += cyc - e[5]


with open(path, 'r', errors='replace') as f:
    for line in f:
        if not started:
            if line.startswith('$enddefinitions'):
                started = True
            continue
        c = line[0]
        if c == '#':
            t = int(line[1:])
            if t & 1:
                continue
            if v['rst_n'] and not v['halt']:
                C['cyc'] += 1
                # ---- 1. 施加上一拍锁存的事件 (RTL 的 reg 晚一拍) ----
                for (kind, st, wy, tg, src, ph, tc) in in_evt:
                    if kind == 0:                       # 驱逐 (起填那拍)
                        settle(st, wy, tc)
                        meta.pop((st, wy), None)
                    else:                               # 安装 (vset_w 那拍)
                        settle(st, wy, tc)              # 防御: 目标格若还有人 (异常路径) 也结算
                        meta[(st, wy)] = [tg, src, 0, 0, ph, tc]
                        INST[src] += 1
                in_evt.clear()
                # ---- 2. 自校验 P9 ----
                val = v['valid']
                mv = 0
                for (st, wy) in meta:
                    mv |= 1 << (wy * SETS + st)
                if mv != val:
                    C['vbad'] += 1
                tag = v['tag']
                for (st, wy), e in meta.items():
                    if ((tag >> ((wy * SETS + st) * TAG_W)) & MASK_T) != e[0]:
                        C['tbad'] += 1
                # ---- 3. 本拍事件 ----
                if v['fstart'] and not p.get('fstart'):
                    CUR = 2 if v['dpfst'] else (1 if v['pfst'] else 0)
                    PEND_HITS = 0
                    in_evt.append((0, v['nset'], v['vway'], 0, 0, 0, C['cyc']))
                if v['vset'] and not p.get('vset'):
                    in_evt.append((1, v['fset'], v['fway'], v['ftag'], CUR, PEND_HITS, C['cyc']))
                    PEND_HITS = 0
                    # 不变量 1 (dcache.v:781): 安装那拍把同组其它持有同一 tag 的路作废。
                    # 按归纳法它永不触发 ⇒ 计到 C['excl'] 上, 非 0 说明模型与 RTL 不一致。
                    for wy in range(WAYS):
                        if wy == v['fway']:
                            continue
                        e = meta.get((v['fset'], wy))
                        if e is not None and e[0] == v['ftag']:
                            C['excl'] += 1
                            settle(v['fset'], wy, C['cyc'])
                            meta.pop((v['fset'], wy))
                if v['byp']:
                    C['byp'] += 1
                    PEND_HITS += 1
                    BYPSRC[CUR] += 1
                if v['hraw']:
                    C['hraw'] += 1
                    e = meta.get((v['qset'], v['hway']))
                    if e is not None:
                        e[2] += 1
                        HIT_SRC[e[1]] += 1
                    else:
                        C['unreg'] += 1
                        HIT_SRC[3] += 1
                if v['sthit'] and not p.get('sthit'):
                    C['sthit'] += 1
                    e = meta.get((v['stset'], v['stway']))
                    if e is not None:
                        e[3] += 1
                        HIT_SRC[e[1]] += 1
                    else:
                        C['unreg'] += 1
                        HIT_SRC[3] += 1
                p['fstart'], p['vset'], p['sthit'] = v['fstart'], v['vset'], v['sthit']
            elif v['halt']:
                break
            continue
        if c in '01xzXZ':
            n = id2n.get(line[1:].strip())
            if n is not None:
                v[n] = 1 if c == '1' else 0
        elif c in 'bB':
            sp = line[1:].split()
            if len(sp) == 2:
                n = id2n.get(sp[1])
                if n is not None:
                    v[n] = int(sp[0].replace('x', '0').replace('z', '0'), 2)

cyc = C['cyc']
pc = lambda x, d: f"{x}({x * 100 // d}%)" if d else f"{x}(-)"
print(f"cyc={cyc}  (官方 make perf 周期 - 16, 见 [§30.1]; 对账用)")
print(f"[口径] P9 自校验: valid 不符 {C['vbad']} 拍 / tag 不符 {C['tbad']} 拍 / 同 tag 排它清除 {C['excl']} 次 "
      f"{'✓' if (C['vbad'] == 0 and C['tbad'] == 0 and C['excl'] == 0) else '✗ 口径错, 结果作废'}")
print(f"[V1] 缓存规模: {WAYS} 路 × {SETS} 组, tag {TAG_W} 位 | "
      f"install 来源 = 需求(本拍) {INST[0]} / 需求(排队) {INST[1]} / 预取 {INST[2]}"
      f"  (与 vcd_mem.py 对账)")
nh = sum(HIT_SRC)
print(f"[V1] 命中事件 load {C['hraw']} + store {C['sthit']} + 填充旁路 {C['byp']} = {nh + C['byp']}"
      f"  (未登记 {C['unreg']})")
print(f"     命中来源分布 (按所命中行的填充来源):")
for i in range(4):
    nm = SRCNAME[i] if i < 3 else '未登记'
    print(f"       {nm:<10} {pc(HIT_SRC[i], nh)}")
print(f"     填充旁路来源: 需求(本拍) {BYPSRC[0]} / 需求(排队) {BYPSRC[1]} / 预取 {BYPSRC[2]}")
tot_ev = sum(EV)
print(f"[V1] 行在被驱逐前的消费次数 (load + store + 旁路):")
for i in range(3):
    if EV[i] == 0:
        continue
    h = HIST[i]
    print(f"       {SRCNAME[i]:<10} 驱逐 {EV[i]:>5} ({EV[i] * 100 // max(tot_ev, 1)}%)"
          f" | 零消费 {pc(ZERO[i], EV[i])}"
          f" | 次数 0/1/2/≥3 = {h[0]}/{h[1]}/{h[2]}/{h[3]}"
          f" | 平均存活 {LIFE[i] / EV[i]:.1f} 拍")
print(f"     (未结算留存 {len(meta)} 行 / 共 {sum(EV)} 行被驱逐)")
