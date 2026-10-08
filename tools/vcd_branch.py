#!/usr/bin/env python3
"""官方 student_top 波形的**分支预测器算法**评估（零 RTL）: 从波形抽出条件分支的
(pc, 实际方向) 动态序列, 离线喂给若干替代预测器, 看误预测能降多少。

为什么这件事可以离线做: 分支的方向由**数据**决定, 与预测器无关 ⇒ 同一条动态分支序列
对任何预测器都是同一个输入 (唯一的偏差: 预测器变强 ⇒ 推测路径变、被带错路径执行的
分支更新数变; 该项对本工具是二阶量, 见下面 [口径] 的 P10 校准)。

trace 的取法: `u_slot.upd_req` 是**执行级**的更新口 (bht.v 的写口), 每个采样拍只要为 1 就
记一条 —— 这**就是** RTL 里 BHT 看到的更新序列 (bht.v 在同一个 posedge 上按它更新)。
`upd_req` 可能连续多拍为 1 (背靠背分支), 也可能同一分支被 q_freeze 扣住多拍 ⇒ 不做边沿
检测, 逐拍记录, 与 RTL 的写口逐拍对齐。

自校验 (P10, 不成立则整轮作废):
  用同一 trace 复刻"2-bit 饱和计数器 @ BHT_SIZE"(复位 2'b01, 方向 = bit[1])——
  ① 逐拍与 RTL 的 `counters` 快照比对 (延迟一拍);
  ② 误预测总数与波形里的 `misp_det` 事件数比对。
  ★ 两条必须同时成立: 计数器逐拍相等说明**更新时机与更新规则**都复刻对了, 误预测数相等
    说明**预测口径** (索引、方向位) 也对。只有前者对而后者差很多 ⇒ 取位/索引错了。
  ⚠ ② 的口径修正 (首轮 vvadd 5 vs 6 时定位): RTL 的 `misp_det` = 条件分支**方向错** ∪
    JALR **目标错** (execute_slot.v:365-366), 而 BHT 只管前者 ⇒ 必须只对**条件分支子集**对账。
    子集判据用 `upd_req` (= sel_valid_q_r && is_branch && !flush_win, 同一寄存 bundle 派生,
    与 misp_det 零偏斜): 事件首拍 flush_win 尚为 0 (flushing_r 是下一拍才置) ⇒ 分类可靠。
    JALR 那一类单列 (属 RAS/BTB 领域, 本工具不评估)。

用法:
  D=testcases/perf_qsort
  ./build/sim $D/program.data $(cat $D/expected.txt) 100000000 10 /tmp/w.vcd
  tools/vcd_branch.py /tmp/w.vcd
波形 ≈8~10 KB/拍; 本脚本按行流式读, 只累积 trace (每程序 ≤ 几十万条)。
"""
import sys

path = sys.argv[1]
U = 'student_top.u_cpu.'
S = U + 'slt[0].u_slot.'   # 执行槽在 generate 块 slt[0] 内
B = U + 'u_fetch.u_bht.'
WANT = {
    'student_top.rst_n': 'rst_n',
    U + 'halt_q_r': 'halt',
    S + 'pc': 'pc',                    # RS 里带 pc (execute_slot.v:202) ⇒ 分支 PC 可重建
    S + 'upd_req': 'ureq',
    S + 'upd_taken': 'utkn',
    S + 'misp_det': 'misp',
    B + 'counters': 'cnt',             # 2*BHT_SIZE 位计数器快照 (自校验①)
    B + 'upd_idx': 'uidx',             # BHT 写口索引 (校验 pc↔索引映射)
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

BHT = WID['cnt'] // 2
BMASK = BHT - 1
assert BHT & BMASK == 0, 'BHT_SIZE 非 2 的幂, 离线索引 (% 与 &) 不等价'

trace = []                      # (pc, taken)
misp_ev = 0                     # 全部 misp_det 事件 (含 JALR 目标错)
misp_branch = 0                 # 其中条件分支方向错 (与 BHT 模型可比)
C = dict(cyc=0, cb_bad=0, cb_chk=0, ibad=0)
misp_p, ureq_p = 0, 0
# 现役 BHT 的离线复刻 (自校验用)
cur = [1] * BHT
snap_next = None                # 下一拍应等于 RTL 的 counters
v = {n: 0 for n in WANT.values()}
t, started = 0, False

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
                # ---- 自校验①: 上一拍施加的更新应与 RTL 的 counters 相等 ----
                if snap_next is not None:
                    C['cb_chk'] += 1
                    if snap_next != v['cnt']:
                        C['cb_bad'] += 1
                if v['ureq']:
                    pc, tk = v['pc'], v['utkn']
                    trace.append((pc, tk))
                    i = (pc >> 2) & BMASK
                    if i != v['uidx']:
                        C['ibad'] += 1
                    c2 = cur[i]
                    cur[i] = min(c2 + 1, 3) if tk else max(c2 - 1, 0)
                snap_next = 0
                for i2 in range(BHT):
                    snap_next |= cur[i2] << (2 * i2)
                # ---- 误预测事件数 (边沿: 脉冲, 同分支被扣住时不该重复计) ----
                # 首拍按 upd_req 分类: 条件分支 (BHT 可比) vs JALR 目标错 (BHT 不可比)
                if v['misp'] and not misp_p:
                    misp_ev += 1
                    misp_branch += 1 if v['ureq'] else 0
                misp_p = v['misp']
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


def run_bimodal(n):
    """2-bit 饱和计数器, 索引 (pc>>2) % n, 复位 2'b01, 方向 = bit[1]。"""
    ct = [1] * n
    bad = 0
    for pc, tk in trace:
        i = (pc >> 2) % n
        if (ct[i] >> 1) != tk:
            bad += 1
        ct[i] = min(ct[i] + 1, 3) if tk else max(ct[i] - 1, 0)
    return bad


def run_gshare(h, n):
    """gshare: 索引 = ((pc>>2) ^ ghr) % n; ghr 为 h 位全局历史。"""
    ct = [1] * n
    ghr, hmask, bad = 0, (1 << h) - 1, 0
    for pc, tk in trace:
        i = ((pc >> 2) ^ ghr) % n
        if (ct[i] >> 1) != tk:
            bad += 1
        ct[i] = min(ct[i] + 1, 3) if tk else max(ct[i] - 1, 0)
        ghr = ((ghr << 1) | tk) & hmask
    return bad


def run_oracle():
    """按 PC 的多数派方向预测 —— **仅"无历史"预测器**的不可达上界。

    ⚠ 不是全家族上界: 带历史的预测器可以超过它 (median 上 gshare-10 = 388 < 446),
    因为同一 PC 在不同历史下的方向不同 ⇒ 单一多数派被两类样本互相拉扯。
    """
    cnt = {}
    for pc, tk in trace:
        a = cnt.get(pc)
        if a is None:
            cnt[pc] = [0, 0]
        cnt[pc][tk] += 1
    bad = 0
    for pc, tk in trace:
        a = cnt[pc]
        if (a[1] >= a[0]) != bool(tk):
            bad += 1
    return bad


def run_oracle_hist(h, n):
    """(pc, ghr) 上下文的多数派 —— **历史类预测器**的不可达上界 (两遍, 直接用将来信息)。

    这是"换预测器"这一候选的**天花板**: 若连它都够不到门槛, 则整个家族都不必再看。
    """
    hmask = (1 << h) - 1
    cnt = {}
    ghr = 0
    for pc, tk in trace:
        k = ((pc >> 2) ^ ghr) % n
        if k not in cnt:
            cnt[k] = [0, 0]
        cnt[k][tk] += 1
        ghr = ((ghr << 1) | tk) & hmask
    bad = 0
    ghr = 0
    for pc, tk in trace:
        k = ((pc >> 2) ^ ghr) % n
        a = cnt[k]
        if (a[1] >= a[0]) != bool(tk):
            bad += 1
        ghr = ((ghr << 1) | tk) & hmask
    return bad


n_tr = len(trace)
print(f"cyc={C['cyc']}  (官方 make perf 周期 - 16, 见 [§30.1]; 对账用)")
print(f"[口径] BHT_SIZE={BHT} (从 counters 宽度推) | 分支更新 {n_tr} 条 | "
      f"misp_det 事件 {misp_ev} = 条件分支方向错 {misp_branch} + JALR 目标错 {misp_ev - misp_branch}")
p10 = run_bimodal(BHT)
gap = abs(p10 - misp_branch) * 100.0 / max(misp_branch, 1)
print(f"[口径] P10 自校验: 离线 2-bit@{BHT} 误预测 {p10} vs 波形**条件分支** {misp_branch} "
      f"(差 {gap:.1f}%) | "
      f"计数器逐拍: {C['cb_chk']} 拍比对, 不符 {C['cb_bad']} 拍 | "
      f"pc↔BHT 索引不符 {C['ibad']} 次")
print(f"       BHT_SIZE={BHT} 索引位宽应 = {BHT.bit_length() - 1} | "
      f"样本 {misp_branch} 条 ⇒ 判据 ±5% 在 <20 条时无分辨力, 取 max(1, 5%)")
ok = (C['cb_bad'] == 0 and C['ibad'] == 0) and (abs(p10 - misp_branch) <= max(1, misp_branch * 0.05))
print(f"       {'✓ 口径可信' if ok else '✗ 口径错, 结果作废'}")

res = [(f"2-bit@{BHT} (现役)", p10),
       ("2-bit@1024 (容量对照)", run_bimodal(1024)),
       ("gshare-8", run_gshare(8, 256)),
       ("gshare-10", run_gshare(10, 1024)),
       ("gshare-12", run_gshare(12, 4096)),
       ("PC 多数派 (无历史上界)", run_oracle()),
       ("(pc,ghr) 多数派 (历史上界)", run_oracle_hist(10, 1024))]
print(f"[V2] 同一 trace 上的误预测数与相对现役的降幅:")
for nm, b in res:
    d = (p10 - b) * 100.0 / max(p10, 1)
    print(f"       {nm:<24} {b:>7}  ({d:+.1f}%)")
print(f"[V2] 密度换算: 现役误预测 {misp_branch * 1000.0 / max(C['cyc'], 1):.1f} / 千拍"
      f" (每次冲刷代价见 vcd_bubble.py 的 flush 桶: 实测 2.0~3.4 拍/次)")

# 误预测 PC 的集中度 (现役口径)
ct2 = [1] * BHT
badpc = {}
for pc, tk in trace:
    i = (pc >> 2) & BMASK
    if (ct2[i] >> 1) != tk:
        badpc[pc] = badpc.get(pc, 0) + 1
    ct2[i] = min(ct2[i] + 1, 3) if tk else max(ct2[i] - 1, 0)
top = sorted(badpc.values(), reverse=True)
tot = sum(top)
print(f"[V2] 误预测集中在 {len(top)} 个 PC 上; top-10 占 {sum(top[:10]) * 100 // max(tot, 1)}%"
      f" / top-32 占 {sum(top[:32]) * 100 // max(tot, 1)}%")
print(f"     top-10 PC (误预测次数, 该 PC 的总执行次数):")
tot_pc = {}
for pc, tk in trace:
    tot_pc[pc] = tot_pc.get(pc, 0) + 1
for pc in sorted(badpc, key=lambda k: -badpc[k])[:10]:
    print(f"       0x{pc:08x}  {badpc[pc]:>6} / {tot_pc[pc]:>6} = {badpc[pc] * 100 // tot_pc[pc]}%")
