#!/bin/sh
# s0_dcbusy.sh —— S0 诊断: 六个 perf 程序各跑一条 VCD, 用 vcd_bubble.py 拆 "dc_busy 里的查表寄存器"。
#
# 零 RTL 改动、零面积: 只读波形。产出的分解表是 M1/M2/M3/M4 的预注册依据 (见 docs/plan.md §32)。
# 口径与 `make perf` 一致: MAX_CYCLES/LATENCY 走 config.mk 默认, expected 取 testcase 自带。
# 波形 ~8 KB/拍 (rsort 2.5 GB), 扫完即删 —— 同一时刻只有一条落在磁盘上。
#
# ★ 每条程序的**完整**扫描输出单独存 /tmp/s0/<prog>.txt: 上一版在这里用 grep 过滤,
#   把新加的 blk_dc 行整个丢掉了, 只能整轮重跑 (教训: 扫一次波形很贵, 别在管道里筛)。
#
# 用法: tools/s0_dcbusy.sh [日志]     (默认 /tmp/s0_dcbusy.log, 后台跑: ... &)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOG=${1:-/tmp/s0_dcbusy.log}
OUT=/tmp/s0
cd "$ROOT" || exit 1
mkdir -p "$OUT"
: > "$LOG"
for P in vvadd towers median multiply qsort rsort; do
    D=testcases/perf_$P
    W=/tmp/s0_$P.vcd
    rm -f "$W"
    echo "=== $P: 仿真 ===" >> "$LOG"
    if ! make run SIM=build/sim PROGRAM="$D/program.data" \
                 EXPECTED="$(cat "$D/expected.txt")" WAVE="$W" >> "$LOG" 2>&1; then
        echo "S0FAIL $P sim" >> "$LOG"
        continue
    fi
    if [ ! -f "$W" ]; then
        echo "S0FAIL $P no-vcd" >> "$LOG"
        continue
    fi
    echo "=== $P: 分解 ($(du -h "$W" | cut -f1)) ===" >> "$LOG"
    python3 tools/vcd_bubble.py "$W" 16 > "$OUT/$P.txt" 2>&1 || echo "S0FAIL $P scan" >> "$LOG"
    cat "$OUT/$P.txt" >> "$LOG"
    rm -f "$W"
done
echo "S0 DONE" >> "$LOG"
