set script_dir [file normalize [file dirname [info script]]]
set root [file normalize [file join $script_dir ../..]]
set out [file join $root build/opna_phase7/board]
set project_dir [file join $out project]
file mkdir $out

source [file join $script_dir opna_sources.tcl]
set sources [opna_core_sources $root]
set sources [concat $sources [lsort [glob [file join $root hardware/rtl/board/*.v]]] \
    [lsort [glob [file join $root hardware/rtl/board/*.sv]]]]
set xdc_file [file join $root hardware/rtl/constraints/zybo.xdc]
foreach name {result.json zybo_opna.bit zybo_opna.xsa} {
    file delete -force [file join $out $name]
}

create_project zybo_opna $project_dir -part xc7z010clg400-1 -force
set_param general.maxThreads 8
set_property simulator_language Mixed [current_project]

add_files -norecurse $sources
update_compile_order -fileset sources_1

source [file join $script_dir zybo_ps7.tcl]
source [file join $script_dir zybo_opna_bd.tcl]
create_opna_bd_design opna_cpu
set bd_file [get_files opna_cpu.bd]
generate_target all $bd_file
make_wrapper -files $bd_file -top
add_files -norecurse [file join $project_dir zybo_opna.gen sources_1 bd opna_cpu hdl opna_cpu_wrapper.v]
set_property top opna_cpu_wrapper [current_fileset]
add_files -fileset constrs_1 -norecurse $xdc_file
update_compile_order -fileset sources_1

create_ip_run $bd_file
foreach synth_run [get_runs -filter {IS_SYNTHESIS == 1}] {
    set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE RuntimeOptimized $synth_run
    set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none $synth_run
}
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Board synthesis failed: [get_property STATUS [get_runs synth_1]]"
}
open_run synth_1
report_utilization -file [file join $out utilization-synth.rpt]
report_utilization -hierarchical -file [file join $out utilization-synth-hierarchical.rpt]
set report_file [open [file join $out utilization-synth.rpt] r]
set report [read $report_file]
close $report_file
if {![regexp {\|\s*Slice LUTs\*?\s*\|\s*([0-9.]+)} $report unused luts] ||
    ![regexp {\|\s*Slice Registers\s*\|\s*([0-9.]+)} $report unused registers] ||
    ![regexp {\|\s*Block RAM Tile\s*\|\s*([0-9.]+)} $report unused brams] ||
    ![regexp {\|\s*DSPs\s*\|\s*([0-9.]+)} $report unused dsps]} {
    error "Board resource counts missing from Vivado utilization report"
}
puts "XC7Z010_BOARD_RESOURCES LUT=$luts/17600 FF=$registers/35200 BRAM=$brams/60 DSP=$dsps/80"
if {$luts > 17600 || $registers > 35200 || $brams > 60 || $dsps > 80} {
    error "Full YM2608 board design exceeds XC7Z010 resource capacity"
}
set synth_resources [list $luts $registers $brams $dsps]
close_design

launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Board implementation failed: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
report_utilization -file [file join $out utilization.rpt]
set report_file [open [file join $out utilization.rpt] r]
set report [read $report_file]
close $report_file
if {![regexp {\|\s*Slice LUTs\*?\s*\|\s*([0-9.]+)} $report unused luts] ||
    ![regexp {\|\s*Slice Registers\s*\|\s*([0-9.]+)} $report unused registers] ||
    ![regexp {\|\s*Block RAM Tile\s*\|\s*([0-9.]+)} $report unused brams] ||
    ![regexp {\|\s*DSPs\s*\|\s*([0-9.]+)} $report unused dsps]} {
    error "Implemented board resource counts missing from Vivado utilization report"
}
puts "XC7Z010_IMPLEMENTED_RESOURCES LUT=$luts/17600 FF=$registers/35200 BRAM=$brams/60 DSP=$dsps/80"
if {$luts > 17600 || $registers > 35200 || $brams > 60 || $dsps > 80} {
    error "Implemented board exceeds XC7Z010 resource capacity"
}
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing-summary.rpt]
report_clock_interaction -file [file join $out clock-interaction.rpt]
report_cdc -details -file [file join $out cdc.rpt]
set cdc_critical [llength [get_cdc_violations -quiet -filter {SEVERITY == Critical}]]
report_drc -file [file join $out drc.rpt]
set timing_file [open [file join $out timing-summary.rpt] r]
set timing [read $timing_file]
close $timing_file
if {![regexp {WNS\(ns\)[^\n]*\n\s*-+[^\n]*\n\s*(-?[0-9.]+)\s+(-?[0-9.]+)\s+([0-9]+)\s+([0-9]+)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+([0-9]+)\s+([0-9]+)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+([0-9]+)} \
    $timing unused wns tns failing_endpoints setup_total whs ths hold_failures hold_total wpws tpws pulse_failures]} {
    error "Timing counts missing from Vivado timing summary"
}
set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == "Critical Warning"}]]
puts "OPNA_BOARD_TIMING WNS=$wns TNS=$tns SETUP_FAILURES=$failing_endpoints WHS=$whs HOLD_FAILURES=$hold_failures WPWS=$wpws PULSE_FAILURES=$pulse_failures DRC_ERRORS=$drc_errors CDC_CRITICAL=$cdc_critical"
if {$wns < 0 || $tns < 0 || $failing_endpoints != 0 || $whs < 0 || $hold_failures != 0 || $wpws < 0 || $pulse_failures != 0 || $drc_errors != 0 || $cdc_critical != 0} {
    error "Board timing, DRC or CDC failed"
}
write_checkpoint -force [file join $out zybo_opna-routed.dcp]
close_design
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Bitstream generation failed: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
file copy -force [file join $project_dir zybo_opna.runs impl_1 opna_cpu_wrapper.bit] [file join $out zybo_opna.bit]
write_hw_platform -fixed -include_bit -force -file [file join $out zybo_opna.xsa]
write_bd_tcl -force [file join $out opna_cpu.tcl]
set result_file [open [file join $out result.json] w]
fconfigure $result_file -encoding utf-8
puts $result_file [format {{"status":"通过","part":"xc7z010clg400-1","resources":{"lut":%s,"ff":%s,"bram":%s,"dsp":%s},"synth_resources":{"lut":%s,"ff":%s,"bram":%s,"dsp":%s},"wns":%s,"tns":%s,"failing_endpoints":%s,"whs":%s,"ths":%s,"hold_failures":%s,"wpws":%s,"tpws":%s,"pulse_failures":%s,"drc_errors":%s,"cdc_critical":%s,"bitstream":"%s","xsa":"%s","board_verified":false}} \
    $luts $registers $brams $dsps {*}$synth_resources $wns $tns $failing_endpoints $whs $ths $hold_failures $wpws $tpws $pulse_failures $drc_errors $cdc_critical \
    [file join $out zybo_opna.bit] [file join $out zybo_opna.xsa]]
close $result_file
puts "PHASE7_BOARD_BUILD_COMPLETE"
