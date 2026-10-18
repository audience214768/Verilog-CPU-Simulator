#!/usr/bin/env python3
"""分解 vcd_bubble.py 里 head-load 的 lm_stblk 拍（旧标签"更老 store 未执行"）。

结构事实（lsq.v）：head 是 LSQ 里最老的条目，cand[0] 的 store_ok[0] 恒 1
⇒ head load 不可能被更老 store 挡住。cand[0]=0 且未 invalidate、未 issued 的真实原因只剩：
  done_r=1   —— 完成脉冲已回（数据在 done_r 一侧），但 ROB ready/提交还没等到 ⇒ 交付链尾拍
  kill (flush_mask) —— 本拍被冲刷
  其它       —— 兜底（应为 0）
用法: tools/vcd_stblk.py <vcd> [LSQ_SIZE]
"""
import sys

path = sys.argv[1]

WANT = {
    'student_top.rst_n': 'rst_n',
    'student_top.u_cpu.halt_q_r': 'halt',
    'student_top.u_cpu.u_rob.ready': 'rob_ready',
    'student_top.u_cpu.u_rob.opcode': 'rob_op',
    'student_top.u_cpu.u_rob.head': 'rob_head',
    'student_top.u_cpu.u_lsq.head': 'h',
    'student_top.u_cpu.u_lsq.cand': 'cand',
    'student_top.u_cpu.u_lsq.invalidate': 'inv',
    'student_top.u_cpu.u_lsq.valid': 'valid',
    'student_top.u_cpu.u_lsq.is_load': 'isld',
    'student_top.u_cpu.u_lsq.addr_ready': 'ar',
    'student_top.u_cpu.u_lsq.data_ready': 'dr',
    'student_top.u_cpu.u_lsq.issued_r': 'iss',
    'student_top.u_cpu.u_lsq.done_r': 'done',
    'student_top.u_cpu.u_lsq.kill': 'kill',
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
C = dict(cyc=0, ld_mem=0, stblk=0, done=0, kill=0, other=0)
OP_LOAD = 0b0000011


def bit(x, i):
    return (x >> i) & 1


started = False
with open(path, 'r', errors='replace') as f:
    for line in f:
        if not started:
            if line.startswith('$enddefinitions'):
                started = True
            continue
        c = line[0]
        if c == '#':
            if int(line[1:]) & 1:
                continue
            if not (v['rst_n'] and not v['halt']):
                continue
            C['cyc'] += 1
            hd = v['rob_head']
            if bit(v['rob_ready'], hd):
                continue
            if ((v['rob_op'] >> (hd * 7)) & 0x7f) != OP_LOAD:
                continue
            h = v['h']
            if not (bit(v['valid'], h) and bit(v['isld'], h)):
                continue
            if not bit(v['ar'], h) or bit(v['dr'], h):
                continue
            C['ld_mem'] += 1
            if bit(v['iss'], h) or bit(v['cand'], 0) or bit(v['inv'], h):
                continue
            C['stblk'] += 1
            if bit(v['done'], h):
                C['done'] += 1
            elif bit(v['kill'], h):
                C['kill'] += 1
            else:
                C['other'] += 1
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

n = max(C['stblk'], 1)
q = lambda x: f"{x}({x * 100 // n}%)"
print(f"cyc={C['cyc']} head-load 等存储={C['ld_mem']} lm_stblk={C['stblk']}")
print(f"  = done_r=1 (完成已回/等 ready) {q(C['done'])} + kill(冲刷) {q(C['kill'])}"
      f" + 其它 {q(C['other'])}")
