#!/bin/sh
# run.sh —— 造一个变体树并用**官方容器**跑综合。变体树在 runs/ 下, 不污染工作区。
#
# 为什么用 cp 而不是 git archive: 要能跑**未提交**的 RTL 改动 (改一版测一版是常态)。
# 只拷综合需要的三样 (verilog/ scripts/ 官方 Makefile 与 config.mk), testcases/ 不拷。
#
# 口径: 记录里所有可比数字都用 docs/timing/filelist_t4tmp.f (官方 filelist.f 去掉
# core/memory.v —— 已核对是**唯一**差异, 22 vs 23 个源文件; 没有任何模块例化 memory,
# hierarchy -top student_top 会剪掉它, 两个列表出同一份网表。冻结成文件放 docs/timing/
# 是为了与已归档基线逐位可比)。
#
# 用法:
#   tools/run.sh <id> [参数=值 ...]       # 例: tools/run.sh lsq8 LSQ_SIZE=8
#   tools/run.sh <id> --no-synth          # 只造树不打综合
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ID=$1; shift
[ -n "$ID" ] || { echo "用法: tools/run.sh <id> [参数=值 ...]"; exit 2; }
TREE="$ROOT/runs/$ID"

rm -rf "$TREE"; mkdir -p "$TREE"
cp -R "$ROOT/verilog" "$ROOT/scripts" "$ROOT/Makefile" "$ROOT/config.mk" "$TREE/"
# 冻结口径的源文件列表 (缺了就直接报错 —— 静默跳过会跑出一份不可比的网表)
cp "$ROOT/docs/timing/filelist_t4tmp.f" "$TREE/verilog/" \
    || { echo "缺少冻结口径的源文件列表 docs/timing/filelist_t4tmp.f"; exit 1; }

# 参数补丁: 只改 student_top 的 parameter 默认值 (参数由它显式往下传)
for kv in "$@"; do
    case "$kv" in
        --no-synth) NO_SYNTH=1; continue ;;
        *=*) ;;
        *) echo "跳过无法识别的参数: $kv"; continue ;;
    esac
    k=${kv%%=*}; v=${kv#*=}
    sed -i '' -E "s/^([[:space:]]*parameter[[:space:]]+$k[[:space:]]*=[[:space:]]*)[0-9]+/\1$v/" \
        "$TREE/verilog/top/student_top.v"
    got=$(sed -nE "s/^[[:space:]]*parameter[[:space:]]+$k[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p" \
        "$TREE/verilog/top/student_top.v")
    [ "$got" = "$v" ] || { echo "参数补丁失败: $k (期望 $v, 实得 '$got')"; exit 1; }
    echo "  补丁 $k = $v"
done

echo "变体树: $TREE"
[ -n "$NO_SYNTH" ] && exit 0

# 官方容器: 绝不能传 CONFIG=config.local.mk (容器内 config.mk 全默认才对)
docker run --rm --cpus=2 -v "$TREE":/work -w /work cpu2026:local \
    make synth MODE=opt CLOCK_PERIOD_NS=2.0 \
         FILELIST=verilog/filelist_t4tmp.f SYNTH_OUT=build/synth_$ID \
    > "$TREE/synth_$ID.log" 2>&1 || { echo "综合失败, 见 $TREE/synth_$ID.log"; exit 1; }

cat "$TREE/build/synth_$ID/opt/timing_values.json"
