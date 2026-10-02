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
口径与自校验见 docs/plan.md §30; 数据表在 §30.2, 变体侧在 §31.5。
"""
import sys

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
    M + 'ld_busy': 'ld_busy',
    M + 'u_ic.fill_busy': 'ic_fill',
    M + 'u_ic.miss_w': 'ic_miss',
    M + 'u_dc.miss_pending_w': 'dc_misspend',
    M + 'u_dc.fill_busy': 'dc_fill',
    M + 'u_dc.busy': 'dc_busy',
    M + 'u_dc.fill_wr_w': 'dc_fwr',
    M + 'u_dc.lk_v_r': 'dc_lkv',
    M + 'u_dc.hit_raw_w': 'dc_hraw',
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
}

scope, id2n = [], {}
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
         blk_dc=0, go_ld=0)
S0EV = dict(fill_start=0, fill_abort=0, poison=0)   # 边沿事件计数
_prev = {}
MISPB = [0] * 4      # 0=jal 1=jalr(含 ret) 2=条件分支 3=其他 (ROB 只存 7 位 opcode, 分不出 ret/f3)
OP_LOAD, OP_STORE = 0b0000011, 0b0100011
OP_CF = (0b1100011, 0b1101111, 0b1100111)
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
                # 边沿事件: 起填 (两条路径) / 污染中止 / 新污染
                S0EV['fill_start'] += 1 if ((v['dc_fgo'] and not _prev.get('go')) or
                                            (v['dc_pfst'] and not _prev.get('pf'))) else 0
                S0EV['fill_abort'] += 1 if (v['dc_fabort'] and not _prev.get('ab')) else 0
                S0EV['poison'] += 1 if (v['dc_fpois'] and not _prev.get('po')) else 0
                _prev['go'], _prev['pf'] = v['dc_fgo'], v['dc_pfst']
                _prev['ab'], _prev['po'] = v['dc_fabort'], v['dc_fpois']
                occ = v['rob_free'] < ROB
                ldmem_now = False
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
