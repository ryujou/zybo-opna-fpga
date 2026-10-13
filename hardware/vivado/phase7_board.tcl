set script_dir [file normalize [file dirname [info script]]]
set root [file normalize [file join $script_dir ../..]]
set out [file join $root build/opna_phase7/board]
if {$argc > 0} { set out [file normalize [lindex $argv 0]] }
set project_dir [file join $out project]
file mkdir $out

source [file join $script_dir opna_sources.tcl]
set sources [opna_core_sources $root]
set sources [concat $sources [lsort [glob [file join $root hardware/rtl/board/*.v]]] \
    [lsort [glob [file join $root hardware/rtl/board/*.sv]]]]
set xdc_file [file join $root hardware/rtl/constraints/zybo.xdc]
foreach name {result.json zybo_opna.bit zybo_opna.xsa zybo_opna.ltx} {
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
set_property PROCESSING_ORDER LATE [get_files $xdc_file]
set_property USED_IN_SYNTHESIS false [get_files $xdc_file]
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
set ila_xdc [file join $out ila.xdc]
close [open $ila_xdc w]
add_files -fileset constrs_1 -norecurse $ila_xdc
set_property USED_IN_SYNTHESIS false [get_files $ila_xdc]
set_property PROCESSING_ORDER LATE [get_files $ila_xdc]
set_property TARGET_CONSTRS_FILE $ila_xdc [current_fileset -constrset]
source [file join $script_dir phase7_debug.tcl]
save_constraints -force
# Saving debug constraints can rename the clock net in the open design.
# Resolve each clock from its preserved source pin when implementation opens it.
set debug_file [open $ila_xdc r]
set debug_constraints [read $debug_file]
close $debug_file
regsub -line {^connect_debug_port opna_ila_native/clk .*} $debug_constraints \
    {connect_debug_port opna_ila_native/clk [get_nets -of_objects [get_pins opna_cpu_i/opna/inst/half_ce_delayed_reg/C]]} debug_constraints
regsub -line {^connect_debug_port opna_ila_audio/clk .*} $debug_constraints \
    {connect_debug_port opna_ila_audio/clk [get_nets -of_objects [get_pins {opna_cpu_i/opna/inst/audio/phase_reg[0]/C}]]} debug_constraints
regsub -line {^connect_debug_port dbg_hub/clk .*} $debug_constraints \
    {connect_debug_port dbg_hub/clk [get_nets -of_objects [get_pins opna_cpu_i/opna/inst/half_ce_delayed_reg/C]]} debug_constraints
set debug_file [open $ila_xdc w]
puts -nonewline $debug_file $debug_constraints
close $debug_file
implement_debug_core
write_checkpoint -force [file join $out zybo_opna-debug-synth.dcp]
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

set_property STEPS.PLACE_DESIGN.TCL.PRE [file join $script_dir phase7_native_timing.tcl] [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.TCL.PRE [file join $script_dir phase7_native_timing.tcl] [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.TCL.POST [file join $script_dir phase7_native_timing.tcl] [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set module_checkpoint [get_files -quiet -all *opna_cpu_opna_0.dcp]
set module_run_checkpoint [file join $project_dir zybo_opna.runs opna_cpu_opna_0_synth_1 opna_cpu_opna_0.dcp]
if {[llength $module_checkpoint] != 1 || ![file isfile $module_checkpoint] || ![file isfile $module_run_checkpoint]} {
    error "Board module OOC checkpoint is missing; regenerate and synthesize the frozen HDL sources"
}
foreach source_file $sources {
    if {[file mtime $source_file] > [file mtime $module_run_checkpoint]} {
        error "HDL source changed after board module synthesis: $source_file"
    }
}
launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Board implementation failed: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
source [file join $script_dir phase7_native_timing.tcl]
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
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
# Match STA by merging the native reset_path and proven multicycle exceptions.
report_methodology -merge_exceptions true -file [file join $out methodology.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing-summary.rpt]
report_timing -delay_type max -max_paths 80 -slack_lesser_than 0 -path_type full_clock_expanded -file [file join $out negative-setup.rpt]
report_timing -delay_type min -max_paths 30 -slack_lesser_than 0 -path_type full_clock_expanded -file [file join $out negative-hold.rpt]
report_bus_skew -file [file join $out mailbox-bus-skew.rpt]
report_timing -delay_type max -max_paths 32 \
    -from [get_cells -hierarchical -regexp {^opna_cpu_i/opna/inst/audio/mailbox_reg\[[0-9]+\]$}] \
    -to [get_pins -hierarchical -regexp {^opna_cpu_i/opna/inst/audio/audio_frame_reg\[[0-9]+\]/D$}] \
    -file [file join $out mailbox-timing.rpt]
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
write_debug_probes -force [file join $out zybo_opna.ltx]
write_bitstream -force [file join $project_dir zybo_opna.runs impl_1 opna_cpu_wrapper.bit]
file copy -force [file join $project_dir zybo_opna.runs impl_1 opna_cpu_wrapper.bit] [file join $out zybo_opna.bit]
write_hw_platform -fixed -include_bit -force -file [file join $out zybo_opna.xsa]
open_bd_design [get_files opna_cpu.bd]
write_bd_tcl -force [file join $out opna_cpu.tcl]
set result_file [open [file join $out result.json] w]
fconfigure $result_file -encoding utf-8
puts $result_file [format {{"status":"\u901a\u8fc7","part":"xc7z010clg400-1","resources":{"lut":%s,"ff":%s,"bram":%s,"dsp":%s},"synth_resources":{"lut":%s,"ff":%s,"bram":%s,"dsp":%s},"wns":%s,"tns":%s,"failing_endpoints":%s,"whs":%s,"ths":%s,"hold_failures":%s,"wpws":%s,"tpws":%s,"pulse_failures":%s,"drc_errors":%s,"cdc_critical":%s,"bitstream":"%s","xsa":"%s","ltx":"%s","board_verified":false}} \
    $luts $registers $brams $dsps {*}$synth_resources $wns $tns $failing_endpoints $whs $ths $hold_failures $wpws $tpws $pulse_failures $drc_errors $cdc_critical \
    [file join $out zybo_opna.bit] [file join $out zybo_opna.xsa] [file join $out zybo_opna.ltx]]
close $result_file
puts "PHASE7_BOARD_BUILD_COMPLETE"
