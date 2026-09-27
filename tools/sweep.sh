#!/bin/sh
# sweep.sh —— 参数消融 (IPC 维): 每个"点"是一组参数, 逐点重建 + 跑 make perf。
#
# 为什么要在变体树里跑: 官方 Makefile 是 CWD 相对的, 且没有参数覆盖入口 —— 只能改
# student_top.v 的 parameter 默认值再重建。直接在仓库里改会把工作区弄脏 (中断就回不去),
# 所以照 run.sh 的做法拷一棵树进 runs/ (已 gitignore)。
#
# ⚠ 口径: 本脚本只量 **IPC**。面积/频率必须走容器官方流程 (tools/run.sh)。
# ⚠ TB 侧参数是各自复制的 (tb_cpu_prog.v 的 *_SIZE_TB、tb_cpu_top.v 硬编码 TPW=6),
#   本脚本**不动**它们 ⇒ 扫出来的变体不覆盖 make -f Makefile.tb 门控。见 tools/README.md §2.4。
#
# 用法:
#   tools/sweep.sh <id> <标签> "K=V[,K=V...]" [<标签2> "K=V,..." ...]
# 例:
#   tools/sweep.sh sw base ""                                  # 只跑默认参数 (对照)
#   tools/sweep.sh sw rs8 "RS_SIZE=8" rs4 "RS_SIZE=4"
#   tools/sweep.sh sw minall "ROB_SIZE=8,RS_SIZE=4,PRF_SIZE=40,LSQ_SIZE=4,BHT_SIZE=8,\
#                             RAS_SIZE=4,PF_DEPTH=8,PF_WIN=4,LD_INFLIGHT=2,SQ_DEPTH=4"
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ID=$1; shift
[ -n "$ID" ] || { echo "用法: tools/sweep.sh <id> <标签> \"K=V,...\" ..."; exit 2; }
TREE="$ROOT/runs/$ID"

if [ ! -d "$TREE" ]; then
    mkdir -p "$TREE"
    cp -R "$ROOT/scripts" "$ROOT/Makefile" "$ROOT/config.mk" "$ROOT/testcases" "$TREE/"
    cp "$ROOT/config.local.mk" "$TREE/" 2>/dev/null || true
fi
# RTL 每次重取 —— 不希望测到上一轮的旧代码 (变体树里只改参数, 不改代码)
rm -rf "$TREE/verilog"; cp -R "$ROOT/verilog" "$TREE/verilog"

patch() {   # patch "K=V,K=V" —— 逐个改 student_top.v 的参数默认值, 每个都回读校验
    # 允许规格串跨行书写 (去掉所有空白再按逗号切) —— 11 个参数的 min-all 一行放不下
    for kv in $(printf '%s' "$1" | tr -d ' \t\n' | tr ',' ' '); do
        k=${kv%%=*}; v=${kv#*=}
        sed -i '' -E "s/^([[:space:]]*parameter[[:space:]]+$k[[:space:]]*=[[:space:]]*)[0-9]+/\1$v/" \
            "$TREE/verilog/top/student_top.v"
        got=$(sed -nE "s/^[[:space:]]*parameter[[:space:]]+$k[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p" \
            "$TREE/verilog/top/student_top.v")
        [ "$got" = "$v" ] || { echo "参数补丁失败: $k (期望 $v, 实得 '$got')"; exit 1; }
    done
}

while [ $# -ge 1 ]; do
    label=$1; spec=""
    [ $# -ge 2 ] && { spec=$2; shift; }
    shift
    patch "$spec"
    make -C "$TREE" CONFIG=config.local.mk MAX_CYCLES=100000000 build > "/tmp/sweep_build.log" 2>&1 \
        || { echo "构建失败, 见 /tmp/sweep_build.log"; exit 1; }
    # UNOPTFLAT 是硬红线 (§15.10.6): 出现即说明引入了组合环, 这一行不可信
    if grep -q "UNOPTFLAT" "/tmp/sweep_build.log"; then
        echo "SWEEP $label UNOPTFLAT!"; continue
    fi
    make -C "$TREE" CONFIG=config.local.mk MAX_CYCLES=100000000 perf > "/tmp/sweep_perf.log" 2>&1 \
        || { echo "perf 失败, 见 /tmp/sweep_perf.log"; exit 1; }
    ips=$(awk '/^perf_/ {printf "%s ", $4}' "/tmp/sweep_perf.log")
    echo "SWEEP $label $ips"
done
