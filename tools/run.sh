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
#   tools/run.sh <id> --filelist docs/timing/filelist_ic.f
#       # 换冻结口径的源文件列表。默认仍是 filelist_t4tmp.f —— 冻结口径是归档可比性的前提
#       # (tools/README.md), 只有**新增源文件**时才该另立一个列表并显式指定。
#   tools/run.sh <id> --mode=diagnose
#       # 出 -hieropt 的保层次网表 (u_xxx/ 限定名), 给 tools/path.py 做组合级归因用。
#       # **判分口径永远是 opt** —— diagnose 只用来归因, 它的面积/频率数字不可比。
#   tools/run.sh <id> --period=6.0
#       # 把 CLOCK_PERIOD_NS 从默认 2.0 换掉。该值以 ps 传给 ABC 的 -D, 是**映射的时序目标**:
#       # 本设计关键路径 ~12 ns, 默认 -D 2000 等于让 ABC 放弃时序、按面积映射。
#       # OpenSTA 报的最小时钟周期是对产出的网表**重新二分**测出来的, 与这个目标无关。
#   tools/run.sh <id> --constr
#       # 官方脚本原样 + ABC 的 `-constr` 分支 (助教建议的对照实验)。唯一差别是给 abc 多传
#       # -constr /work/abc.constr, 使 ABC 走 buffer/upsize/dnsize 那一支 —— 官方那一支
#       # **不做缓冲也不做 upsizing**, 宽扇出被全额惩罚 (见 docs/plan.md §15.10.28)。
#       # 补丁锚在官方 scripts/synth.py 那一行, 打不上就直接失败: 静默不生效等于跑了个假对照。
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ID=$1; shift
[ -n "$ID" ] || { echo "用法: tools/run.sh <id> [参数=值 ...]"; exit 2; }
TREE="$ROOT/runs/$ID"
FLIST=docs/timing/filelist_t4tmp.f
MODE=opt
PERIOD=2.0
CONSTR=

# 先扫一遍 --filelist/--mode/--period/--constr, 再走参数补丁 (它们要放进下面那个循环里一起吃掉)
for kv in "$@"; do
    case "$kv" in
        --filelist=*) FLIST=${kv#--filelist=} ;;
        --mode=*)     MODE=${kv#--mode=} ;;
        --period=*)   PERIOD=${kv#--period=} ;;
        --constr)     CONSTR=1 ;;
    esac
done
[ -f "$ROOT/$FLIST" ] || { echo "缺少源文件列表 $FLIST"; exit 1; }

rm -rf "$TREE"; mkdir -p "$TREE"
cp -R "$ROOT/verilog" "$ROOT/scripts" "$ROOT/Makefile" "$ROOT/config.mk" "$TREE/"
# 冻结口径的源文件列表 (缺了就直接报错 —— 静默跳过会跑出一份不可比的网表)
cp "$ROOT/$FLIST" "$TREE/verilog/" || { echo "缺少源文件列表 $FLIST"; exit 1; }
FNAME=$(basename "$FLIST")

# -constr: 只给官方脚本的 abc 那一行多传一个 -constr, 其余一字不改。
# set_driving_cell/set_load 是 ABC 那两个数用的口径 (官方 SDC 只有时钟/输入输出延时,
# 没有 set_load 也没有 set_driving_cell ⇒ 这两个值只能自己定)。
if [ -n "$CONSTR" ]; then
    printf 'set_driving_cell INVx1_ASAP7_75t_R\nset_load 5.0\n' > "$TREE/abc.constr"
    sed -i '' 's|:.9g}"|:.9g} -constr /work/abc.constr"|' "$TREE/scripts/synth.py"
    grep -q -- '-constr /work/abc.constr' "$TREE/scripts/synth.py" || { echo "constr 补丁失败"; exit 1; }
    echo "  已加 -constr (abc.constr: set_driving_cell INVx1 / set_load 5.0)"
fi

# 参数补丁: 只改 student_top 的 parameter 默认值 (参数由它显式往下传)
for kv in "$@"; do
    case "$kv" in
        --no-synth) NO_SYNTH=1; continue ;;
        --filelist=*) continue ;;
        --mode=*) continue ;;
        --period=*) continue ;;
        --constr) continue ;;
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

echo "变体树: $TREE (filelist = $FNAME, mode = $MODE, period = $PERIOD ns)"
[ -n "$NO_SYNTH" ] && exit 0

# 官方容器: 绝不能传 CONFIG=config.local.mk (容器内 config.mk 全默认才对)
docker run --rm --cpus=2 -v "$TREE":/work -w /work cpu2026:local \
    make synth MODE=$MODE CLOCK_PERIOD_NS=$PERIOD \
         FILELIST="verilog/$FNAME" SYNTH_OUT=build/synth_$ID \
    > "$TREE/synth_$ID.log" 2>&1 || { echo "综合失败, 见 $TREE/synth_$ID.log"; exit 1; }

cat "$TREE/build/synth_$ID/$MODE/timing_values.json"
