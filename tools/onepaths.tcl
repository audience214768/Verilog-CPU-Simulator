# onepaths.tcl —— 一次加载网表, 捞**多对**起终点的逐级清单 (归因用, 非判分产物).
#
# onepath.tcl 只捞一对, 而读 liberty + link_design 要几十秒 ⇒ 归因一批族 (载荷/第二梯队)
# 时按"每次一对"跑就是几十次加载。这里约束与 onepath.tcl **逐条相同** (同一组 liberty /
# 3.333 ns / 同一组 IO 延时), 只把 report_checks 放进循环 ⇒ 输出与官方 timing.rpt 同格式,
# tools/path.py --path k 能逐条吃。
#
# 用法 (容器内; 宿主没有 OpenSTA):
#   docker run --rm -v <variation_tree>:/work -w /work \
#       -e OPT_DIR=/work/build/synth_<id>/opt -e PAIRS=/work/pairs.txt \
#       cpu2026:local sta /work/tools/onepaths.tcl
# PAIRS 每行: <from_pin> <to_pin>  (# 开头与空行忽略)
read_liberty "/opt/asap7/lib/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib"
set work_dir $env(OPT_DIR)
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

# 名字里的方括号在 Tcl 里是 glob 字符类 (rd_out[287] 会被当 "rd_out + 2/8/7 之一") ⇒ 转义
proc lit {s} { string map {[ {\[} ] {\]} \\ {\\\\}} $s }

set fp [open $env(PAIRS) r]
set n 0
foreach line [split [read $fp] "\n"] {
    set f [regexp -all -inline {\S+} $line]
    if {[llength $f] != 2} { continue }
    lassign $f from to
    incr n
    puts "########## PAIR $n : $from -> $to"
    if {[catch {
        report_checks -path_delay max -from [lit $from] -to [lit $to] -group_path_count 1 \
            -format full_clock_expanded -fields {slew capacitance fanout input_pins} -digits 4
    } err]} {
        puts "PAIR $n FAILED: $err"
    }
}
close $fp
exit 0
