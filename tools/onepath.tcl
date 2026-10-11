# onepath.tcl —— 捞**指定起终点**那一条路径的逐级清单 (归因用, 非判分产物).
#
# 为什么需要它: 官方 timing.rpt 只有 5 条, 而 census.tcl 只报 (slack, 起点, 终点) ——
# 第二、第三梯队的路径"贵在哪一级"从这两份产物里都读不出来。做法: 用与 census.tcl **逐条相同**的
# 约束 (同一组 liberty / 3.333 ns / 同一组 IO 延时), 只把 report_checks 换成 -from/-to 定点的,
# 输出格式与官方 timing.rpt 一致 ⇒ tools/path.py / pathsrc.py 能直接吃。
#
# 用法 (容器内; 宿主没有 OpenSTA):
#   docker run --rm -e CENSUS_DIR=<树内 opt 目录> -e OP_FROM=_159033_/QN -e OP_TO=_157948_/D \
#       -v <variation_tree>:/work -w /work cpu2026:local sta /work/tools/onepath.tcl
read_liberty "/opt/asap7/lib/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib"
set work_dir $env(CENSUS_DIR)
foreach _lib [lsort [glob -nocomplain "$work_dir/ram/*.lib"]] {
    read_liberty $_lib
}
set_cmd_units -time ns -capacitance fF
read_verilog "$work_dir/mapped.v"
link_design student_top

set clock_input [get_ports clock]
create_clock -name core_clock -period 3.333 $clock_input
set_clock_transition 0.05 [get_clocks core_clock]
set_clock_uncertainty 0.05 [get_clocks core_clock]
set data_inputs {}
foreach port [all_inputs] {
    if {[get_full_name $port] ne "clock"} { lappend data_inputs $port }
}
if {[llength $data_inputs]} {
    set_input_delay -max 0.2 -clock core_clock $data_inputs
    set_input_delay -min 0.0 -clock core_clock $data_inputs
    set_input_transition 0.05 $data_inputs
}
if {[llength [all_outputs]]} {
    set_output_delay -max 0.2 -clock core_clock [all_outputs]
    set_output_delay -min 0.0 -clock core_clock [all_outputs]
    set_load 5.0 [all_outputs]
}
set reset [get_ports -quiet reset]
if {[llength $reset]} { set_case_analysis 0 $reset }

report_checks -path_delay max -from $env(OP_FROM) -to $env(OP_TO) -group_path_count 1 \
    -format full_clock_expanded -fields {slew capacitance fanout input_pins} -digits 4
exit 0
