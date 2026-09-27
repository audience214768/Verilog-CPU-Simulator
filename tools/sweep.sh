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
SWEEP_MAX_CYCLES=${SWEEP_MAX_CYCLES:-10000000}   # 见下方 run 里的说明 (perf 用)
# 正确性套件**不能**用 1e7: `pi` 是亿级周期 (docs/plan.md:52 记 1.5e8 拍; §15.2 已警告过
# "1e6 上限会制造假失败, 须抬到 1e8")。1e7 会把 pi 变成一条必然的假失败 (实测 18 passed / 1 failed,
# 且失败用例名只能在 stdout 缓冲刷出后按"哪个用例头后面没有 PASS"解析 —— FAIL 行走 stderr, 总是先刷)。
SWEEP_TEST_MAX_CYCLES=${SWEEP_TEST_MAX_CYCLES:-100000000}

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
    # SWEEP_TEST=1: 同一个变体树里先跑官方正确性套件 (make test, 官方 correctness_* 全集)。
    # 消融矩阵要的是"该参数点功能是否成立", 只有 perf 的 IPC 数字不能证明这一点。
    if [ "${SWEEP_TEST:-0}" = "1" ]; then
        make -C "$TREE" CONFIG=config.local.mk MAX_CYCLES=$SWEEP_TEST_MAX_CYCLES test > "/tmp/sweep_test_$label.log" 2>&1 || true
        echo "SWEEP $label TEST $(grep -E '^Results:' /tmp/sweep_test_$label.log | tail -1)"
        # 失败用例名: FAIL 行走 stderr (无缓冲), 用例头走 stdout (有缓冲) ⇒ 不能按邻近行归属,
        # 只能找"后面没有 PASS 的那个用例头"
        awk '/^\[/{if(p!=""&&!ok)print "  失败用例: "p; p=$0; ok=0} /^PASS/{ok=1} END{if(!ok&&p!="")print "  失败用例: "p}' \
            "/tmp/sweep_test_$label.log"
    fi
    # 周期上限 1e7 (不是官方的 1e8): 默认参数下最长的 perf 是 perf_rsort 的 655666 周期
    # ⇒ 15× 余量。官方 1e8 在这里是**陷阱** —— 一个卡死的参数组合要跑 18 分钟才报错
    # (实测 ~93k 周期/秒), 12 个点的扫描会变成几小时。**卡死点标 TIMEOUT 而不是静默丢弃**。
    # `|| true`: set -e 会在 make 非零退出时直接终止, 那样下面的 TIMEOUT 判定就永远走不到
    make -C "$TREE" CONFIG=config.local.mk MAX_CYCLES=$SWEEP_MAX_CYCLES perf > "/tmp/sweep_perf.log" 2>&1 || true
    if grep -q "timeout or finish before exit write response" "/tmp/sweep_perf.log"; then
        echo "SWEEP $label TIMEOUT(cycles=$SWEEP_MAX_CYCLES) 卡死或极慢, IPC 无效"
        continue
    fi
    ips=$(awk '/^perf_/ {printf "%s ", $4}' "/tmp/sweep_perf.log")
    echo "SWEEP $label $ips"
done
