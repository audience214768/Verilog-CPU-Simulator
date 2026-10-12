# arrive.tcl —— 定点到达 / 前 N 条排行（只读；跑在官方 mapped.v 上，不改任何产物）
#
# 用途（§3.34 的两个关键量都出自它）：
#   · **定点到达**：官方 timing.rpt 只报路径上各脚的 arrival，问"某个组合脚上到达多少"要用
#     `-through <脚>`：报出来的级清单里**该脚那一行的 Time 就是它的到达**。
#   · **前 N 条排行**：`-from <触发器>` 看族形（同一起点散到哪些终点、带内多宽）；
#     `-through <组合脚> -endpoint_path_count N` 看"切掉头名后谁来"。
#
# 用法（远端；CENSUS_DIR = 树内 opt 目录）：
#   ssh pc 'cat > /tmp/arrive.tcl' < tools/arrive.tcl
#   ssh pc 'cd ~/cpu2026 && docker run --rm --cpus=2 \
#     -e CENSUS_DIR=/work/runs/<id>/build/synth_<id>/opt \
#     -e AR_FROM=_155618_/QN -e AR_PINS=_088847_/B,_088283_/A -e AR_TO=_153594_/D \
#     -e AR_N=40 -e AR_FMT=summary \
#     -v /home/aud_xiejiaye/cpu2026:/work -v /tmp:/t:ro -w /work cpu2026:local sta /t/arrive.tcl'
#
# 坑（真栽过，见 tools/README §2）：
#   · `-to <组合脚>` 会报 “No paths found”（组合脚不是 timing endpoint）⇒ 一律用 `-through`。
#   · `-endpoint_path_count` 默认 **1** ⇒ 不显式给，同一个终点只会出一行。
#   · `-through` 配 `-endpoint_path_count N>1` 会把**同一条路重复 N 行**（实测 40 行逐字相同）
#     ⇒ 只有 `-to` 分支才放大 N（所以本脚本 `-through` 恒用 1）。
#   · `-format summary` 的**起点列会打出终点的 cell 类型**（实测 `DFFASRHQNx1` 打成 `DFFHQNx1`）
#     ⇒ 类型只在 `full_clock_expanded` 或官方 critical_paths.json 里读，`summary` 只读 slack。
#   · OpenSTA 3.1 **没有** `sta::worst_arrival`（`invalid command name`）⇒ 定点到达只能用 `-through`。
#   · slack → arrival：`arrival = period - uncertainty - slack`（本口径 3.333 − 0.05 − slack）。

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
set reset [get_ports -quiet reset]
if {[llength $reset]} { set_case_analysis 0 $reset }

set fmt summary
if {[info exists env(AR_FMT)]} { set fmt $env(AR_FMT) }

if {[info exists env(AR_FROM)]} {
    puts "@@@FROM $env(AR_FROM) N=$env(AR_N)"
    report_checks -path_delay max -from [get_pins $env(AR_FROM)] \
        -group_path_count $env(AR_N) -endpoint_path_count 1 -digits 4 \
        -fields {fanout} -format $fmt
}

foreach p [split [expr {[info exists env(AR_PINS)] ? $env(AR_PINS) : ""}] ,] {
    if {$p eq ""} { continue }
    puts "@@@PIN $p"
    if {[llength [get_pins -quiet $p]] == 0} { puts "@@@NOPIN"; continue }
    # 显式列进 AR_TO 的脚按"进该终点的前 N 条"报（其余一律 -through：组合脚上的定点到达）
    if {[info exists env(AR_TO)] && [string first $p $env(AR_TO)] >= 0} {
        report_checks -path_delay max -to [get_pins $p] -group_path_count $env(AR_N) \
            -endpoint_path_count $env(AR_N) -digits 4 -fields {fanout} -format $fmt
    } else {
        report_checks -path_delay max -through [get_pins $p] -group_path_count $env(AR_N) \
            -endpoint_path_count 1 -digits 4 -fields {fanout} -format $fmt
    }
}
exit 0
