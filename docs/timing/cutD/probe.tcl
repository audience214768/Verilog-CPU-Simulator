set report_dir "/work/probe"
set clock_port "clock"
set clock_period 2
read_liberty "/opt/asap7/lib/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib"
read_liberty "/work/build/synth_cutD/opt/ram/fakeram_asap7_16x32.lib"
read_liberty "/work/build/synth_cutD/opt/ram/fakeram_asap7_32x32.lib"
set_cmd_units -time ns -capacitance fF
read_verilog "/work/build/synth_cutD/opt/mapped.v"
link_design student_top
file mkdir $report_dir
source "/work/scripts/timing.tcl"
report_checks -path_delay max -sort_by_slack -group_path_count 60 -format full_clock_expanded -fields {slew capacitance fanout input_pins} -digits 4 > $report_dir/probe_paths.rpt
exit 0