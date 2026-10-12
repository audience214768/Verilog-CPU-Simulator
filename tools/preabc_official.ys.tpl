# preabc_official.ys.tpl —— 官方 pass-1 **截断在 `abc` 之前**的网表（RTL 名字保留）
#
# 不是模板的用法就别用：本文件是**模板**，两个占位符要替换成绝对路径：
#   __OPT__  = 变体树里的 opt 目录（含 ram/prepared.json 与 ram/wrappers.v），例 /work/build/synth_cutW/opt
#   __OUT__  = 输出网表路径，例 /t/preabc_cutW.v
#
# 唯一可信的生成方式（容器 0.63；宿主 0.68 的产物已判不可信，见 tools/README.md §0）：
#   ssh pc 'sed -e "s|__OPT__|/work/build/synth_cutW/opt|g" -e "s|__OUT__|/t/preabc_cutW.v|g" \
#            /t/preabc_official.ys.tpl > /t/pre.ys'
#   ssh pc 'docker run --rm --cpus=2 -v /home/aud_xiejiaye/cpu2026/runs/cutW:/work -v /tmp/fwdtool:/t:ro \
#            -w /work cpu2026:local yosys -Q -T -s /t/pre.ys'
#
# 逐行等于官方 scripts/synth.py 的 pass-1（`run_yosys(..., "synth", script)`）**去掉 abc 及其之后**：
#   后处理那几步（clean / delete $scopeinfo / hilomap / write_json / write_verilog）都要求"已映射"，
#   在 `abc` 之前跑会直接报错，所以本模板只保留到 `dfflibmap` 为止。
# ★ 改动本模板前先对一遍 scripts/synth.py（官方文件勿改）—— 少一条 read_liberty 或多一条 pass
#   都会让归因结果与判分产物脱钩。

read_json __OPT__/ram/prepared.json
read_verilog __OPT__/ram/wrappers.v
read_liberty -lib -ignore_miss_func /opt/asap7/lib/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib
read_liberty -lib -ignore_miss_func /opt/asap7/lib/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib
read_liberty -lib -ignore_miss_func /opt/asap7/lib/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib
read_liberty -lib -ignore_miss_func /opt/asap7/lib/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib
read_liberty -lib -ignore_miss_func /opt/asap7/lib/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib
read_liberty -lib -ignore_miss_func __OPT__/ram/fakeram_asap7_16x32.lib
read_liberty -lib -ignore_miss_func __OPT__/ram/fakeram_asap7_32x288.lib
hierarchy -check -top student_top
synth -top student_top -noabc -flatten
check -assert
select -assert-none a:init t:$dlatch* t:$_DLATCH*
dfflibmap -liberty /opt/asap7/lib/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib
write_verilog -noattr -noexpr __OUT__
