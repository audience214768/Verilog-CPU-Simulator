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
#       # 换源文件列表。**默认 = 官方 verilog/filelist.f** (与判分口径一致; core/memory.v 在列表里
#       # 但没被 student_top 例化, hierarchy -top 会剪掉, 已核对不影响网表)。
#       # ★ 2026-10-02 起不要再用 docs/timing/filelist_t4tmp.f: 它是 9 月的冻结列表, 不含
#       # icache/dcache/mem_subsystem ⇒ 综合会在 elaborate 阶段报 "unsupported external module dcache"。
#   tools/run.sh <id> --mode=diagnose
#       # 出 -hieropt 的保层次网表 (u_xxx/ 限定名), 给 tools/path.py 做组合级归因用。
#       # **判分口径永远是 opt** —— diagnose 只用来归因, 它的面积/频率数字不可比。
#   tools/run.sh <id> --period=6.0
#       # 把 CLOCK_PERIOD_NS 从默认 2.0 换掉。该值以 ps 传给 ABC 的 -D, 是**映射的时序目标**:
#       # 本设计关键路径 ~12 ns, 默认 -D 2000 等于让 ABC 放弃时序、按面积映射。
#       # OpenSTA 报的最小时钟周期是对产出的网表**重新二分**测出来的, 与这个目标无关。
#   tools/run.sh <id> --constr
#       # **2026-10-14 起是空操作**: 官方框架更新 (302f0cf) 后, `-constr`
#       # (set_driving_cell INVx1_ASAP7_75t_R / set_load 5.0; ABC 走 buffer/upsize/dnsize)
#       # 已是**官方默认** —— 与本脚本旧的 --constr 补丁参数逐字相同。保留本开关只为让
#       # 归档里的老命令行仍表达同一支流程。
#   tools/run.sh <id> --noconstr
#       # 反向对照: 从变体树的 scripts/synth.py 里**删掉** abc 行的 -constr 那一句,
#       # 复现 2026-10-14 之前的旧判分口径 (ABC 不缓冲不 upsize, 宽扇出被全额惩罚)。
#       # 只用于归因 / 复现历史数字, **不当判据**。补丁带自检, 打不上直接失败。
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ID=$1; shift
[ -n "$ID" ] || { echo "用法: tools/run.sh <id> [参数=值 ...]"; exit 2; }
TREE="$ROOT/runs/$ID"
FLIST=verilog/filelist.f
MODE=opt
PERIOD=2.0
NOCONSTR=

# 先扫一遍 --filelist/--mode/--period/--constr, 再走参数补丁 (它们要放进下面那个循环里一起吃掉)
for kv in "$@"; do
    case "$kv" in
        --filelist=*) FLIST=${kv#--filelist=} ;;
        --mode=*)     MODE=${kv#--mode=} ;;
        --period=*)   PERIOD=${kv#--period=} ;;
        --constr)     : ;;              # 2026-10-14 起已是官方默认, 空操作
        --noconstr)   NOCONSTR=1 ;;
    esac
done
[ -f "$ROOT/$FLIST" ] || { echo "缺少源文件列表 $FLIST"; exit 1; }

rm -rf "$TREE"; mkdir -p "$TREE"
cp -R "$ROOT/verilog" "$ROOT/scripts" "$ROOT/Makefile" "$ROOT/config.mk" "$TREE/"
# 冻结口径的源文件列表 (缺了就直接报错 —— 静默跳过会跑出一份不可比的网表)
cp "$ROOT/$FLIST" "$TREE/verilog/" || { echo "缺少源文件列表 $FLIST"; exit 1; }
FNAME=$(basename "$FLIST")

# --noconstr: 从官方脚本的 abc 那一行删掉 ` -constr " + quote(abc_constraints)`, 其余一字不改。
# (abc.constr 仍会被脚本写出, 只是没人读 —— 无害)
if [ -n "$NOCONSTR" ]; then
    # -i.bak 而不是 -i '': BSD sed 与 GNU sed 通吃 (远端 Linux 上 -i '' 会把 '' 当文件名)
    sed -i.bak 's|+ " -constr " + quote(abc_constraints) + |+ |' "$TREE/scripts/synth.py"
    rm -f "$TREE/scripts/synth.py.bak"
    if grep -q -- '-constr' "$TREE/scripts/synth.py"; then
        echo "noconstr 补丁失败"; exit 1
    fi
    echo "  已删 -constr (复现旧口径: ABC 不缓冲不 upsize)"
fi

# 参数补丁: 只改 student_top 的 parameter 默认值 (参数由它显式往下传)
for kv in "$@"; do
    case "$kv" in
        --no-synth) NO_SYNTH=1; continue ;;
        --filelist=*) continue ;;
        --mode=*) continue ;;
        --period=*) continue ;;
        --constr) continue ;;
        --noconstr) continue ;;
        *=*) ;;
        *) echo "跳过无法识别的参数: $kv"; continue ;;
    esac
    k=${kv%%=*}; v=${kv#*=}
    sed -i.bak -E "s/^([[:space:]]*parameter[[:space:]]+$k[[:space:]]*=[[:space:]]*)[0-9]+/\1$v/" \
        "$TREE/verilog/top/student_top.v"
    rm -f "$TREE/verilog/top/student_top.v.bak"
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
