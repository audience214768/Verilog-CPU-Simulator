#!/usr/bin/env python3
"""官方 student_top 波形 (build/sim 非 OJ 波形模式) 的**提交侧**气泡归因 (互斥穷尽)。

首个参数化扫描工具, 与 sweep.sh 的区别: 这是"单点深挖", 跑的是官方二进制。
单发射每拍至多提交 1 条 ⇒ IPC 口径 = set_head_valid; 派发侧 issue_en 不直接对应 IPC
(RS 满而 RS 仍在出货的拍不丢 IPC —— 实测 rsort 派发侧"RS 满"36.5% 不是直接气泡;
但 RS 容量本身对 IPC 有收益, 只是路径藏在"等存储"里, 本分区看不见 —— 见 plan.md §30.4 订正)。
分区: cyc = commit + flush + empty(+IC fill) + head-not-ready(load/store/cf/alu) + ready-nocommit(store 缺 SQ 位)
用法:
  D=testcases/perf_qsort
  ./build/sim $D/program.data $(cat $D/expected.txt) 100000000 10 /tmp/w.qcd
  tools/vcd_bubble.py /tmp/w.vcd [ROB_SIZE]
波形约 8 KB/拍 (qsort 1.9 GB / rsort 2.5 GB), 扫描完即可删; 本脚本按行流式读, 不占内存。
第二个参数是生成该波形的 **ROB_SIZE** (默认 16 = c2): "ROB 空" 的判据是 rob_free == ROB_SIZE,
写死会在放大 ROB 的变体上把"在飞若干条"误判成空。跑非 c2 波形时**必须**显式给。
口径与自校验见 docs/plan.md 的 [§30] 里程碑; 数据表在 [§30]/[§31], 变体侧在 [§31]。
[S3] 的"等存储"再分六类 (head=load 且未在飞): 在飞等回包 / D-cache 闸门 / miss 队列满 /
本拍发射 / **退休窗口** (条目正被提交失效, 提交侧晚一拍) / 更老 store 未执行 (结构上不可达, 哨兵)。
取位口径: cand 是距离索引 (位 gd ↔ 条目 head+gd), 头条目自己的位是 cand[0] —— 见 §38.3a。
"""
import sys
from collections import deque

path = sys.argv[1]
# ROB_SIZE 必须与生成该波形的参数一致: "ROB 空" 的判据是 rob_free == ROB_SIZE,
# 写死 16 会在放大 ROB 的变体上把"在飞若干条"误判成空 (empty 桶虚高)。
ROB = int(sys.argv[2]) if len(sys.argv) > 2 else 16
U = 'student_top.u_cpu.'
M = 'student_top.u_mem.'
WANT = {
    'student_top.rst_n': 'rst_n',
    U + 'halt_q_r': 'halt',
    U + 'issue_en': 'issue_en',
    U + 'misp_valid': 'misp',
    U + 'flushing_r': 'flushing',
    U + 'set_head_valid': 'commit',
    U + 'sw_ready': 'sw_ready',
    U + 'sw_valid': 'sw_valid',
    U + 'u_rob.ready': 'rob_ready',
    U + 'u_rob.head': 'rob_head',
    U + 'u_rob.opcode': 'rob_op',
    U + 'misp_fs_w': 'misp_fs',
    U + 'u_rob.free_count': 'rob_free',
    U + 'u_lsq.valid': 'lq_v',
    U + 'u_lsq.is_load': 'lq_ld',
    U + 'u_lsq.addr_ready': 'lq_ar',
    U + 'u_lsq.data_ready': 'lq_dr',
    U + 'u_lsq.head': 'lq_h',
    # ★ M1 的**直接**上界: 有一条 load 已就绪 (cand) 但 D-cache 拒收 (ld_busy)。
    #   这才是"M1 放开闸门能救回多少拍"; 单看 dc_busy 占比会高估 (忙 ≠ 挡住别人)。
    U + 'u_lsq.cand': 'lq_cand',
    # §38.3a: cand[0]==0 的例外拍是"条目正在退休"(提交失效延迟一拍) 还是"被更老 store 挡"?
    U + 'u_lsq.invalidate': 'lq_inv',
    M + 'ld_busy': 'ld_busy',
    M + 'u_ic.fill_busy': 'ic_fill',
    M + 'u_ic.miss_w': 'ic_miss',
    M + 'u_dc.miss_pending_w': 'dc_misspend',
    M + 'u_dc.fill_busy': 'dc_fill',
    M + 'u_dc.busy': 'dc_busy',
    M + 'u_dc.fill_wr_w': 'dc_fwr',
    M + 'u_dc.lk_v_r': 'dc_lkv',
    M + 'u_dc.hit_raw_w': 'dc_hraw',
    M + 'u_dc.hit_valid': 'dc_hitv',        # = (hit_raw_w && !rsp_busy) || byp_valid_w (dcache.v:362)
    M + 'u_dc.rsp_busy': 'dc_rspb',
    M + 'u_dc.ms_fire_w': 'dc_msf',
    # ---- S0: dc_busy 三层分解 (查表寄存器 51% 里混了三种原因, 干预完全不同) ----
    M + 'u_dc.lk_wait_r': 'dc_lkwait',      # 同行等待 (coalesce) ⇒ M1/M2
    M + 'u_dc.lk_replay_r': 'dc_lkrep',     # 重放 (读口被偷 / 命中抢不到交付口) ⇒ M3
    M + 'u_dc.lk_miss_r': 'dc_lkmiss',      # park: 等 ms_ready (AXI 读 FIFO 满) ⇒ RD_DEPTH
    M + 'u_dc.rd_ok_r': 'dc_rdok',          # 0 = 本拍这次查表读被写口偷走
    M + 'u_dc.ms_ready': 'dc_msrdy',
    M + 'u_dc.fill_abort_w': 'dc_fabort',   # 污染中止 (整行作废, 行永不安装)
    M + 'u_dc.fill_poison_now_w': 'dc_fpois',
    M + 'u_dc.fill_rsp_valid': 'dc_frsp',
    M + 'u_dc.fill_go_w': 'dc_fgo',
    M + 'u_dc.pf_start_w': 'dc_pfst',
    M + 'u_dc.pf_v_r': 'dc_pfv',            # 单槽填充队列占用 (覆盖式写入 ⇒ M4 动机)
    M + 'u_axi.rd_full_w': 'axi_rdfull',
    M + 'u_axi.wr_full_w': 'axi_wrfull',
    # ---- §35: 等存储细分 (58~72% 的等存储发生在 D-cache 空闲时 ⇒ 必须查清在等谁) ----
    U + 'u_lsq.issued_r': 'lq_iss',         # 该条目已有 load 请求在飞 (完成脉冲未回)
    M + 'u_dc.ms_addr': 'dc_msa',           # 本拍推给存储的**需求 load 字节地址**
    M + 'u_axi.rd_wr_p': 'axi_wp',          # AR 侧: 已压入读队列
    M + 'u_axi.rd_ar_p': 'axi_ap',          # AR 侧: 已发给 AXI 从机
    M + 'u_axi.rd_rd_p': 'axi_rp',          # R 侧: 回包已消化
    # ★ 需求缺失的推送/回包**不另立信号**: Verilator 把"同一条网"的多个层次别名压成**同一个
    #   VCD 码字**, 解析时后声明者覆盖先声明者 ⇒ 另立的名字恒收不到更新 (踩过一次:
    #   `u_mem.dc_ms_fire_w` 与 `u_dc.ms_fire_w` 同码, 新名字永远 MISSING)。
    #   这两条网本来就同码, 直接用已映射的旧名:
    #     dc_ms_fire_w  ≡ u_dc.ms_fire_w  → 'dc_msf'   (需求缺失推送)
    #     u_mem.ld_resp_hs ≡ u_dc.rsp_busy → 'dc_rspb' (需求 load 的 AXI 回包被消化)
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

v = {n: 0 for n in WANT.values()}
C = dict(cyc=0, commit=0, iss=0, flush=0, empty=0, emp_ic=0, ready=0, rc_sw=0,
         ld=0, st=0, cf=0, alu=0, ld_ni=0, ld_mem=0, ld_oth=0,
         misp=0, ld_busy=0, dc_miss=0, dc_fill=0, dc_busy=0,
         axi_rd=0, axi_wr=0, sw=0, ic_fill=0,
         dcb_inst=0, dcb_lk=0, dcb_both=0,
         # S0: lk 侧的三种原因 + 其它
         dcb_wait=0, dcb_rep=0, dcb_park=0, dcb_steal=0, dcb_oth=0,
         dw_run=0, dw_ep=0, dw_max=0,
         dc_msrdy0=0, pf_v=0, f_rsp=0, ldmem_dcbusy=0,
         blk_dc=0, go_ld=0,
         # §35: 等存储六分类 + 需求缺失往返 (lm_ret = 退休窗口, §38.3a 订正后新增)
         lm_flight=0, lm_dc=0, lm_occ=0, lm_go=0, lm_stblk=0, lm_ret=0,
         ms_n=0, resp_n=0, ld_n=0, st_rsp=0, st_hit=0, st_oth=0,
         msd0=0, msd1=0, msd2=0, msd3=0,
         # §40 (V3): 命中交付路径
         rep_n=0, hv_n=0, hv_hi=0, hraw_rsp=0)
# §35 直方图: 在飞段长 / 推送→回包延迟 / 推送那拍的 AR 队列占用 (末格是溢出格)
NH = 80
HF = [0] * NH          # head load 单次"在飞"连续段长 (合计)
HFB = {'rsp': [0] * NH, 'hit': [0] * NH, 'oth': [0] * NH}   # 按段的结束方式分开
HFB_REP = [0] * NH     # §40: 命中结束的段里**发生过查表重放**的那些 (验证 "3 拍 = 重放" 的因果)
HR = [0] * NH          # dc_ms_fire_w → ld_resp_hs 的拍数
HA = [0] * 17          # 推送那拍"已压入未发出"的 AR 数

S0EV = dict(fill_start=0, fill_abort=0, poison=0)   # 边沿事件计数
_prev = {}
MISPB = [0] * 4      # 0=jal 1=jalr(含 ret) 2=条件分支 3=其他 (ROB 只存 7 位 opcode, 分不出 ret/f3)
OP_LOAD, OP_STORE = 0b0000011, 0b0100011
OP_CF = (0b1100011, 0b1101111, 0b1100111)
t, started = 0, False
fl_since = -1                 # §35: 当前"head load 在飞"段的起点拍 (未开段 = -1)
fire_q = deque()              # §35: 需求缺失推送序 (FIFO 配对回包)

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
                C['iss'] += 1 if v['issue_en'] else 0
                if v['misp']:
                    C['misp'] += 1
                    mf = v['misp_fs']
                    mo = (v['rob_op'] >> (mf * 7)) & 0x7f
                    MISPB[0 if mo == 0b1101111 else
                          (1 if mo == 0b1100111 else
                           (2 if mo == 0b1100011 else 3))] += 1
                C['sw'] += 1 if v['sw_valid'] else 0
                C['ld_busy'] += 1 if v['ld_busy'] else 0
                C['dc_miss'] += 1 if v['dc_misspend'] else 0
                C['dc_fill'] += 1 if v['dc_fill'] else 0
                C['dc_busy'] += 1 if v['dc_busy'] else 0
                C['ic_fill'] += 1 if (v['ic_fill'] or v['ic_miss']) else 0
                C['axi_rd'] += 1 if v['axi_rdfull'] else 0
                C['axi_wr'] += 1 if v['axi_wrfull'] else 0
                if v['dc_busy']:
                    ins = v['dc_fwr']
                    lkb = v['dc_lkv'] and (not (v['dc_hraw'] and not v['dc_rspb'])) and (not v['dc_msf'])
                    if ins and lkb:
                        C['dcb_both'] += 1
                    elif ins:
                        C['dcb_inst'] += 1
                    else:
                        C['dcb_lk'] += 1
                    if lkb:
                        # 查表寄存器被占的三种原因 + 边角 (互斥穷尽, 优先级 = 寄存器置位优先级)
                        if v['dc_lkwait']:
                            C['dcb_wait'] += 1
                            C['dw_run'] += 1                     # 同行等待的连续段长 ⇒ 串行化程度
                            C['dw_max'] = max(C['dw_max'], C['dw_run'])
                        elif v['dc_lkrep']:
                            C['dcb_rep'] += 1
                        elif v['dc_lkmiss']:
                            C['dcb_park'] += 1
                        elif not v['dc_rdok']:
                            C['dcb_steal'] += 1     # 本拍读被偷, 下一拍才转 replay
                        else:
                            C['dcb_oth'] += 1       # miss_pending 但 ms_ready=0 (推不出去)
                if not v['dc_lkwait']:
                    if C['dw_run']:
                        C['dw_ep'] += 1
                    C['dw_run'] = 0
                if v['lq_cand']:
                    if v['ld_busy']:
                        C['blk_dc'] += 1
                    else:
                        C['go_ld'] += 1
                C['dc_msrdy0'] += 1 if not v['dc_msrdy'] else 0
                C['pf_v'] += 1 if v['dc_pfv'] else 0
                C['f_rsp'] += 1 if v['dc_frsp'] else 0
                # ---- §35: 需求缺失的往返延迟 (推送序 = 回包序, 严格 FIFO 配对) ----
                # 推送那拍记下"已压入未发出"的 AR 数 (发出指针 rd_ar_p 落后压入指针 rd_wr_p 多少)
                if v['dc_msf'] and not _prev.get('mf'):
                    C['ms_n'] += 1
                    # §35b: 相邻两次需求缺失的**行**关系 ⇒ "下一行预取"能覆盖多少
                    _ln = v['dc_msa'] >> 5
                    if _prev.get('msl') is not None:
                        _d = _ln - _prev['msl']
                        C['msd0' if _d == 0 else
                          ('msd1' if _d == 1 else ('msd2' if _d > 1 else 'msd3'))] += 1
                    _prev['msl'] = _ln
                    fire_q.append((C['cyc'], (v['axi_wp'] - v['axi_ap']) & ((1 << WID['axi_wp']) - 1)))
                _prev['mf'] = v['dc_msf']
                # 命中率口径: 每笔完成的 load 恰是一个交付脉冲 = 命中 (hit_raw 且非回包拍) 或 回包
                C['ld_n'] += 1 if (v['dc_hraw'] and not v['dc_rspb']) else 0
                C['ld_n'] += 1 if v['dc_rspb'] else 0
                if v['dc_rspb'] and fire_q:
                    f0, a0 = fire_q.popleft()
                    C['resp_n'] += 1
                    HR[min(C['cyc'] - f0, NH - 1)] += 1
                    HA[min(a0, 16)] += 1
                # 边沿事件: 起填 (两条路径) / 污染中止 / 新污染
                S0EV['fill_start'] += 1 if ((v['dc_fgo'] and not _prev.get('go')) or
                                            (v['dc_pfst'] and not _prev.get('pf'))) else 0
                S0EV['fill_abort'] += 1 if (v['dc_fabort'] and not _prev.get('ab')) else 0
                S0EV['poison'] += 1 if (v['dc_fpois'] and not _prev.get('po')) else 0
                _prev['go'], _prev['pf'] = v['dc_fgo'], v['dc_pfst']
                _prev['ab'], _prev['po'] = v['dc_fabort'], v['dc_fpois']
                occ = v['rob_free'] < ROB
                ldmem_now = False
                fl_hit = False
                if v['commit']:
                    C['commit'] += 1
                elif v['misp'] or v['flushing']:
                    C['flush'] += 1
                elif not occ:
                    C['empty'] += 1
                    C['emp_ic'] += 1 if (v['ic_fill'] or v['ic_miss']) else 0
                else:
                    hd = v['rob_head']
                    if (v['rob_ready'] >> hd) & 1:
                        C['ready'] += 1
                        C['rc_sw'] += 1 if not v['sw_ready'] else 0
                    else:
                        hop = (v['rob_op'] >> (hd * 7)) & 0x7f
                        if hop == OP_LOAD:
                            C['ld'] += 1
                            lh = v['lq_h']
                            if ((v['lq_v'] >> lh) & 1) and ((v['lq_ld'] >> lh) & 1):
                                if not ((v['lq_ar'] >> lh) & 1):
                                    C['ld_ni'] += 1
                                elif not ((v['lq_dr'] >> lh) & 1):
                                    C['ld_mem'] += 1
                                    ldmem_now = True
                                    # ★ §35: 这条 head load 在等谁 —— 五类互斥穷尽
                                    if (v['lq_iss'] >> lh) & 1:
                                        C['lm_flight'] += 1
                                        fl_hit = True
                                        if fl_since < 0:
                                            fl_since = C['cyc']
                                            fl_rep = False
                                    else:
                                        # cand 是**距离索引** (lsq.v:129,141): 位 gd ↔ 条目 (head+gd)&7,
                                        # 而 lh 是条目号 ⇒ 头条目自己的位是 cand[0]。
                                        # (史: 2026-10-08 §38.3a 之前此处误取 cand[lh], 实测 vvadd/rsort 上
                                        #  100% 的 lm_stblk 判定都是读到了别的条目; 订正见 plan.md §38.3a)
                                        if not ((v['lq_cand'] >> 0) & 1):
                                            # 头条目不可发: 提交失效晚到一拍 ⇒ 条目正在退休 (实测占 100%);
                                            # 真正"被更老 store 挡" (cand[0]=0 且未失效) 结构上不可达, 留作哨兵
                                            C['lm_ret'] += 1 if (v['lq_inv'] >> lh) & 1 else 0
                                            C['lm_stblk'] += 1 if not ((v['lq_inv'] >> lh) & 1) else 0
                                        elif v['dc_busy']:
                                            C['lm_dc'] += 1
                                        elif v['ld_busy']:
                                            C['lm_occ'] += 1
                                        else:
                                            C['lm_go'] += 1
                                else:
                                    C['ld_oth'] += 1
                            else:
                                C['ld_oth'] += 1
                        elif hop == OP_STORE:
                            C['st'] += 1
                        elif hop in OP_CF:
                            C['cf'] += 1
                        else:
                            C['alu'] += 1
                # 等存储的拍里, D-cache 同时是忙的占多少 (M1 的直接上界: 忙=在替别人排队)
                C['ldmem_dcbusy'] += 1 if (ldmem_now and v['dc_busy']) else 0
                # ---- §40 (V3): 命中交付路径 ----
                # lk_replay_r 是**寄存器** (dcache.v:273), 每置一次 = 一笔 load 的查表作废重来;
                # 上升沿计数 = 重放事件数。原因两类: 读口被写口偷 (rd_ok_r=0) / 命中撞上 AXI 回包
                # 占住交付口 (hit_raw_w && rsp_busy, dcache.v:719-723)。后者可直接从波形数。
                if v['dc_lkrep'] and not _prev.get('lkrep'):
                    C['rep_n'] += 1
                    if fl_since >= 0:
                        fl_rep = True                      # 本段内发生过重放
                C['hraw_rsp'] += 1 if (v['dc_hraw'] and v['dc_rspb']) else 0
                # hit_valid = 真正交付给 LSQ 的命中 (含填充旁路); 每笔 load 应恰好 1 拍
                if v['dc_hitv']:
                    if _prev.get('hitv'):
                        C['hv_hi'] += 1            # 连续 2 拍以上 ⇒ 不是脉冲, 口径要另算
                    else:
                        C['hv_n'] += 1
                # §35: 关掉上一段"在飞" (只统计**连续**在飞段 ⇒ 段长 = 这一笔缺失挡住 head 的拍数)
                # 归因: 段**上一拍**是哪种交付脉冲 —— 决定这一段是"等自己的 AR"(⇒ 预取能救)
                #       还是"等同行的填充"(⇒ 只能靠提前发 AR / 更早旁路)
                if not fl_hit and fl_since >= 0:
                    _L = min(C['cyc'] - fl_since, NH - 1)
                    HF[_L] += 1
                    EPD = 'st_rsp' if _prev.get('rsp2') else ('st_hit' if _prev.get('hit2') else 'st_oth')
                    HFB[EPD[3:]][_L] += 1
                    HFB_REP[_L] += 1 if (EPD == 'st_hit' and fl_rep) else 0
                    C[EPD] += 1
                    fl_since = -1
                _prev['rsp2'], _prev['hit2'] = v['dc_rspb'], (v['dc_hraw'] and not v['dc_rspb'])
                _prev['lkrep'], _prev['hitv'] = v['dc_lkrep'], v['dc_hitv']
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

cyc, cm = C['cyc'], C['commit']
hdr = C['ld'] + C['st'] + C['cf'] + C['alu']
pc = lambda x: f"{x}({x*100//cyc}%)"
print(f"cyc={cyc} commit={cm} ipc={cm/cyc:.4f} | issue={C['iss']} squashed={C['iss']-cm} "
      f"| stores-committed={C['sw']}")
print(f"  no-commit={cyc-cm} {pc(cyc-cm)}: flush={pc(C['flush'])} empty={pc(C['empty'])}"
      f"(IC-fill {C['emp_ic']}) store-blocked-SQ={pc(C['rc_sw'])} "
      f"head-notready={pc(hdr)}")
print(f"  head-notready: load={pc(C['ld'])} [未发射 {C['ld_ni']} / 等存储 {C['ld_mem']}]"
      f" store={pc(C['st'])} cf={pc(C['cf'])} alu/其他={pc(C['alu'])}")
print(f"  MEM: ld_busy={pc(C['ld_busy'])} dc_misspend={pc(C['dc_miss'])} dc_fill={pc(C['dc_fill'])}"
      f" dc_busy={pc(C['dc_busy'])} axi_rd_full={pc(C['axi_rd'])} axi_wr_full={pc(C['axi_wr'])}"
      f" ic_fill={pc(C['ic_fill'])} misp={C['misp']}")
print(f"  misp 类型 [jal, jalr/ret, 条件分支, 其他] = {MISPB}")
print(f"  dc_busy 拆: 安装写={pc(C['dcb_inst'])} 查表寄存器={pc(C['dcb_lk'])} 两者={C['dcb_both']}")
if C['dcb_lk']:
    # ★ 子桶的计数口径是 "lk 被占的拍" = dcb_lk + dcb_both (both = 安装写与查表寄存器同拍);
    #   用 dcb_lk 当分母会算出 >100% (踩过一次)。
    lk = C['dcb_lk'] + C['dcb_both']
    q = lambda x: f"{x}({x*100//lk}%lk)"
    print(f"  [S0] 查表寄存器 {lk} 拍 = 同行等待 {q(C['dcb_wait'])} + 重放 {q(C['dcb_rep'])}"
          f" + park {q(C['dcb_park'])} + 读被偷 {q(C['dcb_steal'])} + 推不出 {q(C['dcb_oth'])}")
    print(f"  [S0] 同行等待: {C['dw_ep']} 段, 均长 {C['dcb_wait']/max(C['dw_ep'],1):.1f} 拍,"
          f" 最长 {C['dw_max']} 拍")
print(f"  [S0] 起填 {S0EV['fill_start']} 次, 污染中止 {S0EV['fill_abort']} 次"
      f" ({S0EV['fill_abort']*100//max(S0EV['fill_start'],1)}% 的填充), 新污染 {S0EV['poison']} 次")
print(f"  [S0] pf_v_r 占用={pc(C['pf_v'])} (单槽填充队列被占 ⇒ 第三条缺失行直接丢)")
print(f"  [S0] blk_dc: load 就绪但被 D-cache 拒收={pc(C['blk_dc'])} (放行={pc(C['go_ld'])}),"
      f" 占 dc_busy {C['blk_dc']*100//max(C['dc_busy'],1)}% ← M1 直接上界")
print(f"  [S0] ms_ready=0 拍={pc(C['dc_msrdy0'])}; 等存储∩dc_busy={pc(C['ldmem_dcbusy'])}"
      f" (占等存储 {C['ldmem_dcbusy']*100//max(C['ld_mem'],1)}%)")


def hstat(H):
    """直方图的 (n, 均, 中位, p90, 最长); 末格是溢出格 ⇒ 最长写作 '≥末格'."""
    n = sum(H)
    if not n:
        return 0, 0.0, 0, 0, "-"
    tot = sum(i * h for i, h in enumerate(H))
    acc, p50, p90 = 0, -1, -1
    hi = max(i for i, h in enumerate(H) if h)
    for i, h in enumerate(H):
        acc += h
        if p50 < 0 and acc * 2 >= n:
            p50 = i
        if p90 < 0 and acc * 10 >= n * 9:
            p90 = i
    return n, tot / n, p50, p90, (f"≥{hi}" if hi == len(H) - 1 else hi)


lm = max(C['ld_mem'], 1)
q5 = lambda x: f"{x}({x*100//lm}%)"
print(f"  [S3] 等存储 {C['ld_mem']} 拍 = 在飞等回包 {q5(C['lm_flight'])}"
      f" + D-cache 闸门 {q5(C['lm_dc'])} + miss 队列满 {q5(C['lm_occ'])}"
      f" + 本拍发射 {q5(C['lm_go'])} + 退休窗口 {q5(C['lm_ret'])}"
      f" + 更老 store 未执行 {q5(C['lm_stblk'])}")
_n, _m, _p50, _p90, _mx = hstat(HF)
print(f"  [S3] head 在飞段长: {_n} 段, 均 {_m:.1f} 拍, 中位 {_p50}, p90 {_p90}, 最长 {_mx}")
_h = hstat(HFB['hit'])
print(f"  [S3=§40.V3] **命中/旁路结束**的段长分布 (P12 判据: 中位<=2, p90<=3, 最长<=8):"
      f" {_h[0]} 段, 均 {_h[1]:.1f}, 中位 {_h[2]}, p90 {_h[3]}, 最长 {_h[4]}"
      f" | 直方图 0..7 = {[HFB['hit'][i] for i in range(8)]}")
print(f"              其中**段内发生过查表重放**的: {sum(HFB_REP)} 段"
      f" | 这些段的长度分布 0..7 = {[HFB_REP[i] for i in range(8)]}")
_sn = max(C['st_rsp'] + C['st_hit'] + C['st_oth'], 1)
print(f"  [S3] 段的结束方式: 自己的 AR 回包 {C['st_rsp']}({C['st_rsp']*100//_sn}%)"
      f" + 命中/旁路 {C['st_hit']}({C['st_hit']*100//_sn}%) + 其它(冲刷/换头) {C['st_oth']}")
for _k, _lab in (('rsp', '自己的 AR 回包'), ('hit', '命中/旁路'), ('oth', '其它')):
    H = HFB[_k]
    _nn = sum(H)
    _cc = sum(i * h for i, h in enumerate(H))
    _lng_n = sum(H[6:])
    _lng_c = sum(i * h for i, h in enumerate(H) if i >= 6)
    print(f"      {_lab}: {_nn} 段/{_cc} 拍; 其中段长>5 的 {_lng_n} 段/{_lng_c} 拍"
          f" (短段 = 命中固有延迟 ≤5)")
_n, _m, _p50, _p90, _mx = hstat(HR)
print(f"  [S3] 需求缺失 {C['ms_n']} 次 (回包 {C['resp_n']}), 推送→回包:"
      f" 均 {_m:.1f} 拍, 中位 {_p50}, p90 {_p90}, 最长 {_mx} (裸延迟 = LATENCY + 2)")
_mn = max(C['msd0'] + C['msd1'] + C['msd2'] + C['msd3'], 1)
print(f"  [S3b] 相邻两次需求缺失的行: 同一行 {C['msd0']*100//_mn}% | **正好下一行** {C['msd1']*100//_mn}%"
      f" | 跳跃/回绕 {C['msd2']*100//_mn}% | 回退 {C['msd3']*100//_mn}%")
print(f"  [S3] hit_raw_w 为高的 **拍数** {C['ld_n']} (含回包拍)"
      f" | 需求缺失 {C['ms_n']} 笔 ⇒ D-cache 缺失率 {C['ms_n']*100//max(C['ld_n'],1)}% (同行合并算命中)"
      f"  ⚠ 单位订正 (§40): 此处原写「笔」, 实为**拍数** —— hit_raw_w 每笔命中会连续为高 2 拍"
      f" (见下一行 hv_hi) ⇒ 笔数应看 hit_valid 上升沿")
_hn = max(C['hv_n'], 1)
print(f"  [S3=§40.V3] 命中交付 {C['hv_n']} 笔 (hit_valid 上升沿; 连续>1 拍的 {C['hv_hi']} 拍)"
      f" | 查表重放 {C['rep_n']} 次 = 命中的 {C['rep_n']*100//_hn}% (P13 判据 <5%)"
      f" | 命中撞回包占用 (hit_raw_w && rsp_busy) {C['hraw_rsp']} 拍"
      f" = 运行的 {C['hraw_rsp']*100.0/max(C['cyc'],1):.2f}% (P13 判据 <1.5%)")
_ha = sum(HA)
if _ha:
    _cum = [sum(HA[:k + 1]) * 100 // _ha for k in range(17)]
    print(f"  [S3] 推送时'已压入未发出'的 AR 数: " +
          " ".join(f"{k}:{HA[k]*100//_ha}%" for k in range(9) if HA[k]) +
          f" | ≥1 占 {100 - _cum[0]}%, ≥4 占 {100 - _cum[3]}%, ≥8 占 {100 - _cum[7]}%")
