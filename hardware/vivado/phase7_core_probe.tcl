set root [file normalize [file join [file dirname [info script]] ../..]]
set out [file join $root build/opna_phase7/core-probe]
file mkdir $out

create_project -in_memory -part xc7z010clg400-1
set_param general.maxThreads 8

source [file join $root hardware/vivado/opna_sources.tcl]
set sources [opna_core_sources $root]
read_verilog [lsearch -all -inline -not -regexp $sources {\.sv$}]
foreach source [lsearch -all -inline -regexp $sources {\.sv$}] {
    read_verilog -sv $source
}

synth_design -top ym2608 -mode out_of_context -part xc7z010clg400-1 \
    -flatten_hierarchy none -directive RuntimeOptimized \
    -generic {ENABLE_FM=1 ENABLE_RHYTHM=1 ENABLE_ADPCM=1}
write_checkpoint -force [file join $out ym2608-synth.dcp]
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -file [file join $out utilization-hierarchical.rpt]
set report_file [open [file join $out utilization.rpt] r]
set report [read $report_file]
close $report_file
if {![regexp {\|\s*Slice LUTs\*?\s*\|\s*([0-9.]+)} $report unused luts] ||
    ![regexp {\|\s*Slice Registers\s*\|\s*([0-9.]+)} $report unused registers] ||
    ![regexp {\|\s*Block RAM Tile\s*\|\s*([0-9.]+)} $report unused brams] ||
    ![regexp {\|\s*DSPs\s*\|\s*([0-9.]+)} $report unused dsps]} {
    error "Resource counts missing from Vivado utilization report"
}
puts "XC7Z010_CORE_RESOURCES LUT=$luts/17600 FF=$registers/35200 BRAM=$brams/60 DSP=$dsps/80"
if {$luts > 17600 || $registers > 35200 || $brams > 60 || $dsps > 80} {
    error "Full YM2608 core exceeds XC7Z010 resource capacity"
}
puts "PHASE7_CORE_PROBE_COMPLETE"
