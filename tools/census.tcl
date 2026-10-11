# census.tcl —— 路径普查 (归因用, 非判分产物).
#
# 为什么需要它: 官方 scripts/timing.tcl 里 report_checks 写死 `-group_path_count 5`, 所以归档的
# timing.rpt **永远只有 5 条路径**(ic1k 那 5 条还同属一个 32 位寄存器的相邻位) —— 它回答不了
# "全设计到底有几条独立的长路径", 而这个问题决定了"下一刀要切几处"。
# 本脚本用**与官方完全相同的约束**(时钟/IO 延时/case_analysis), 只把路径数放大。
#
# 用法 (容器内; 宿主没有 OpenSTA):
#   docker run --rm --cpus=2 -e CENSUS_DIR=<树内 opt 目录> -e CENSUS_N=4000 \
#       -v <variation_tree>:/work -w /work cpu2026:local sta /work/census.tcl
#
# 时钟周期固定 3.333 ns (=300 MHz 目标). 时序路径延时**与周期无关**(本流程无 time borrowing),
# 所以 delay ≈ 3.333 - slack, 与官方在 2.0 ns 下报的延时是同一个数(剩下 0.0726 ns 的差是
# set_clock_uncertainty 0.05 + 触发器 setup 时间, 两边都有, 相减即消)。
read_liberty "/opt/asap7/lib/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib"
set work_dir $env(CENSUS_DIR)
# FakeRAM liberty 只在**例化了 SRAM** 的版本里有 (I-cache 落地后才有 ram/ 目录);
# 无 SRAM 的变体树 (如最小参数点) 不能被这一行挡死 —— 否则普查只能跑一半的版本。
# ★ 宏名 = "fakeram_asap7_<DEPTH>x<WRITE_GRANULARITY>", 随 RTL 变 (dcache 由 32 位粒度改成
#   **一整路**后宏是 32x288, icache 仍是 16x32) ⇒ 必须 glob, 写死文件名会在换粒度的那一刀上
#   静默漏读一个宏的 liberty (宏变成无时序的黑盒 ⇒ 普查数不再是判据)。
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

set paths [find_timing_paths -path_delay max -sort_by_slack -group_path_count $env(CENSUS_N)]
puts "CENSUS_COUNT [llength $paths]"
foreach p $paths {
    set slack [get_property $p slack]
    set sp [get_property $p startpoint]
    set ep [get_property $p endpoint]
    puts [format "CENSUS %.4f %.4f %s %s" $slack [expr {3.333 - $slack}] \
              [get_full_name $sp] [get_full_name $ep]]
}
exit 0
