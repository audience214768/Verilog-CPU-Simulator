#!/usr/bin/env python3
"""官方 student_top 波形的**访存并发度 + D-cache 组占用**计数（零 RTL）。

回答两个决定性问题（预注册见 docs/plan.md 的本轮小节；判据写于测量之前）:

Q1 全机同时有几笔 D 需求缺失在飞？需求缺失撞上"填充引擎忙"的比例多大？
   ⇒ 判定"多 MSHR / 并行填充"候选是留还是删。
   关键结构事实: dcache.v:392 "填充器 = 单 MSHR + 1 条排队" ⇒ AR 可以多笔在飞,
   但**起填/安装**是串行的。故 `ld_occ_w >= 2` 的拍才说明"真有多笔在飞"。

Q2 D-cache 的组满不满？install 时受害路有效（= 真冲突驱逐）的比例多大？
   ⇒ 判定"4 路 + 真 LRU / 组索引"候选是留还是删。

口径（与 vcd_bubble.py 一致, 便于逐位对账）:
  - 采样 = 每个**偶数** `#t` 且 `rst_n && !halt`; `cyc` 应 = 官方 `make perf` 周期 − 16（[§30.1]）。
  - 本脚本复算的 `lm_flight` 比 vcd_bubble.py **多 0~15 拍**: 后者把 `commit`/`flush` 拍先行分类,
    不计入该桶（六程序实测差 +0/+2/+4/+15）⇒ 对账看趋势不看相等。
  - `ld_occ_w = ld_wr_p - ld_rd_p + dc_ms_fire_w`（mem_subsystem.v:231）⇒
    本脚本**逐拍断言**这条恒等式; 不成立即口径错, 直接退出（不解释数据）。
  - `valid_r` 位序 = `way*DC_SETS + set`（dcache.v:276）; install = `vset_w`（dcache.v:755）。
  - `victim_f` 优先选**空路** ⇒ `vic_v_w` 在 install 那拍为 1 ⟺ 目标组**两路全满**。

用法:
  D=testcases/perf_qsort
  ./build/sim $D/program.data $(cat $D/expected.txt) 100000000 10 /tmp/w.vcd
  tools/vcd_mem.py /tmp/w.vcd [ROB_SIZE]     # ROB_SIZE 默认 16 = 基准
波形约 8~10 KB/拍（qsort 2.0 GB / rsort 2.6 GB）; 本脚本按行流式读, 内存恒定。
"""
import sys

path = sys.argv[1]
ROB = int(sys.argv[2]) if len(sys.argv) > 2 else 16
U = 'student_top.u_cpu.'
M = 'student_top.u_mem.'
D = M + 'u_dc.'
WANT = {
    'student_top.rst_n': 'rst_n',
    U + 'halt_q_r': 'halt',
    # ---- Q1: 在飞需求缺失 ----
    M + 'ld_occ_w': 'occ',          # 在飞数 (含本拍推送)
    M + 'ld_wr_p': 'wrp',           # 推送指针
    M + 'ld_rd_p': 'rdp',           # 回包指针
    D + 'ms_fire_w': 'msf',         # 需求缺失推送
    D + 'rsp_busy': 'rspb',         # 需求 load 的 AXI 回包被消化
    D + 'fill_pend_w': 'fpend',     # 需求缺失撞上"引擎忙/被挡" ⇒ 落进 1 格排队
    D + 'fill_busy': 'fbusy',       # 填充引擎忙
    D + 'pf_v_r': 'pfv',            # 1 格排队寄存器占用
    # ---- Q2: 组占用 / 冲突驱逐 ----
    D + 'valid_r': 'valid',         # DC_WAYS*DC_SETS 位图
    D + 'dirty_r': 'dirty',
    D + 'vset_w': 'vset',           # 行真正置有效的唯一时刻
    D + 'vic_v_w': 'vicv',          # 受害路此刻有效
    D + 'vic_dirty_w': 'vicd',
    D + 'new_set_w': 'nset',        # 本次填充装进哪一组
    D + 'victim_way_w': 'vway',
    # 起填来源: 三个理由**互斥** (dcache.v:451), 安装那拍早已不是它们 ⇒ 必须在**起填那拍锁存**
    # (踩过一次: 直接在 vset_w 那拍采 dpf_start_w ⇒ vvadd 报"预取 0%", 而它全机只有 2 笔需求缺失)
    D + 'fill_start_w': 'fstart',
    D + 'fill_go_w': 'fgo',         # 本拍的需求缺失起填
    D + 'pf_start_w': 'pfst',       # 排队的那条需求起填
    D + 'dpf_start_w': 'dpfst',     # 预取起填
    # ---- 校准用: 复算 vcd_bubble.py 的 lm_flight (本脚本不计 commit/flush 拍 ⇒ 恒 >= 它) ----
    U + 'u_rob.free_count': 'rob_free',
    U + 'u_rob.ready': 'rob_ready',
    U + 'u_rob.head': 'rob_head',
    U + 'u_rob.opcode': 'rob_op',
    U + 'u_lsq.valid': 'lq_v',
    U + 'u_lsq.is_load': 'lq_ld',
    U + 'u_lsq.addr_ready': 'lq_ar',
    U + 'u_lsq.data_ready': 'lq_dr',
    U + 'u_lsq.issued_r': 'lq_iss',
    U + 'u_lsq.head': 'lq_h',
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

DC_SETS, DC_WAYS = WID['valid'] // 2, 2          # 基准 DC_WAYS=2 (位图 = WAYS*SETS)
OP_LOAD = 0b0000011
OCCMAX = 5                                        # 直方图 0..4, 末格 = >=5
OCC = [0] * OCCMAX
OCCLMF = [0] * OCCMAX                             # 只在 lm_flight 拍上
INSTOCC = [0] * 3                                 # install 前目标组占用 0/1/2 路
C = dict(cyc=0, occ_sum=0, occ_max=0, occ_ge2=0, mismatch=0,
         msf=0, rspb=0, fpend=0, fbusy=0, pfv=0, pfv_full=0,
         vset=0, vicv=0, vicd=0, dpf=0, valid_sum=0, dtot_sum=0,
         setfull_sum=0, lmf=0, lmf_ge2=0)
SRC = [0, 0, 0]          # 安装来源: 0=需求(本拍) 1=排队的需求 2=预取
CUR = 0                  # 最近一次起填的来源 (锁存到安装那拍)
v = {n: 0 for n in WANT.values()}
p = {}                       # 上一拍: 边沿检测
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
                # ---- P4 口径断言: occ == wrp - rdp + msf (逐拍) ----
                mw = WID['wrp']
                exp = ((v['wrp'] - v['rdp']) & ((1 << mw) - 1)) + v['msf']
                if v['occ'] != exp:
                    C['mismatch'] += 1
                o = min(v['occ'], OCCMAX - 1)
                OCC[o] += 1
                C['occ_sum'] += v['occ']
                C['occ_max'] = max(C['occ_max'], v['occ'])
                C['occ_ge2'] += 1 if v['occ'] >= 2 else 0
                # 边沿事件
                if v['msf'] and not p.get('msf'):
                    C['msf'] += 1
                if v['rspb'] and not p.get('rspb'):
                    C['rspb'] += 1
                if v['fpend'] and not p.get('fpend'):
                    C['fpend'] += 1
                if v['pfv']:
                    C['pfv_full'] += 1
                C['fbusy'] += 1 if v['fbusy'] else 0
                C['pfv'] += 1 if v['pfv'] else 0
                # ---- Q2: 组占用 (时间加权) ----
                val = v['valid']
                C['valid_sum'] += bin(val).count('1')
                C['dtot_sum'] += bin(v['dirty']).count('1')
                full = 0
                for gj in range(DC_SETS):
                    if ((val >> gj) & 1) and ((val >> (DC_SETS + gj)) & 1):
                        full += 1
                C['setfull_sum'] += full
                # ---- 起填来源锁存 (三个理由互斥, 优先级 = dcache.v:451 的拼接序) ----
                if v['fstart'] and not p.get('fstart'):
                    CUR = 2 if v['dpfst'] else (1 if v['pfst'] else 0)
                # ---- install ----
                if v['vset'] and not p.get('vset'):
                    C['vset'] += 1
                    C['vicv'] += 1 if v['vicv'] else 0
                    C['vicd'] += 1 if (v['vicv'] and v['vicd']) else 0
                    C['dpf'] += 1 if v['dpfst'] else 0
                    SRC[CUR] += 1
                    ns = v['nset']
                    occ_pre = ((val >> ns) & 1) + ((val >> (DC_SETS + ns)) & 1)
                    INSTOCC[min(occ_pre, 2)] += 1
                # ---- 校准: 复算 vcd_bubble 的 lm_flight ----
                lmf = False
                if v['rob_free'] < ROB and not ((v['rob_ready'] >> v['rob_head']) & 1):
                    hd = v['rob_head']
                    if (((v['rob_op'] >> (hd * 7)) & 0x7f) == OP_LOAD):
                        lh = v['lq_h']
                        if ((v['lq_v'] >> lh) & 1) and ((v['lq_ld'] >> lh) & 1) \
                           and ((v['lq_ar'] >> lh) & 1) and not ((v['lq_dr'] >> lh) & 1) \
                           and ((v['lq_iss'] >> lh) & 1):
                            lmf = True
                if lmf:
                    C['lmf'] += 1
                    OCCLMF[min(v['occ'], OCCMAX - 1)] += 1
                    C['lmf_ge2'] += 1 if v['occ'] >= 2 else 0
                p['msf'], p['rspb'], p['fpend'] = v['msf'], v['rspb'], v['fpend']
                p['vset'], p['fstart'] = v['vset'], v['fstart']
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
print(f"[口径] P4 逐拍断言 occ == wrp-rdp+msf : 不符 {C['mismatch']} 拍 "
      f"{'✓' if C['mismatch'] == 0 else '✗ 口径错, 结果作废'}")
print(f"[Q1] 在飞需求缺失 ld_occ_w: 均 {C['occ_sum'] / cyc:.3f} 峰值 {C['occ_max']} "
      f"| >=2 占 {pc(C['occ_ge2'], cyc)}")
print(f"     直方图 0..{OCCMAX - 1}(溢出) = {OCC}")
print(f"     推送 {C['msf']} / 回包 {C['rspb']} (应相等) | 撞引擎忙(落队) {C['fpend']}"
      f" = 推送的 {pc(C['fpend'], C['msf'])}")
print(f"     引擎忙 {pc(C['fbusy'], cyc)} | 1 格排队被占 {pc(C['pfv'], cyc)} (事件数 {C['pfv_full']})")
print(f"[Q1b] lm_flight(校准 vcd_bubble) {pc(C['lmf'], cyc)} 拍; 其中 occ>=2 "
      f"{pc(C['lmf_ge2'], C['lmf'])} | 直方图 = {OCCLMF}")
print(f"[Q2] 有效行 均 {C['valid_sum'] / cyc:.1f}/{DC_WAYS * DC_SETS}"
      f" | 脏行 均 {C['dtot_sum'] / cyc:.1f} | 满组(两路全有效) 均 {C['setfull_sum'] / cyc:.2f}/{DC_SETS}")
print(f"     install {C['vset']} 次: 来源 = 本拍需求 {SRC[0]} / 排队需求 {SRC[1]} / 预取 {SRC[2]}"
      f"; 受害路有效 {pc(C['vicv'], C['vset'])} (其中脏 {pc(C['vicd'], C['vset'])} 需写回)")
print(f"     install 前目标组占用 0/1/2 路 = {INSTOCC}")
