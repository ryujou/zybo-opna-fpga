set root [file normalize [file join [file dirname [info script]] ../..]]
set out [file join $root build/opna_phase7/core-probe]
file mkdir $out

create_project -in_memory -part xc7z010clg400-1
set_param general.maxThreads 1

set jt [file join $root hardware/rtl/opna_core/jt12]
set adapted {
    jt12_reg jt12_top jt12_kon jt12_mmr jt12_mod jt12_csr jt12_pg jt12_eg
    jt12_eg_ctrl jt12_eg_pure jt12_eg_comb jt12_eg_step jt12_eg_final
    jt12_op jt12_logsin
}
set sources {}
foreach source [concat [lsort [glob $jt/hdl/*.v]] [lsort [glob $jt/hdl/adpcm/*.v]]] {
    if {[lsearch -exact $adapted [file rootname [file tail $source]]] < 0} {
        lappend sources $source
    }
}
foreach name $adapted {
    lappend sources [file join $root hardware/rtl/opna_core/jt12_opna/$name.v]
}
set sources [concat $sources [lsort [glob $jt/jt49/hdl/*.v]]]
read_verilog $sources
foreach name {jt49_opna jt10_opna_rom jt10_opna_rhythm jt10_opna_adpcm ym2608_control ym2608} {
    read_verilog -sv [file join $root hardware/rtl/opna_core/$name.sv]
}

synth_design -top ym2608 -mode out_of_context -part xc7z010clg400-1 -flatten_hierarchy none \
    -generic {ENABLE_FM=1 ENABLE_RHYTHM=1 ENABLE_ADPCM=1}
write_checkpoint -force [file join $out ym2608-synth.dcp]
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -file [file join $out utilization-hierarchical.rpt]
puts "PHASE7_CORE_PROBE_COMPLETE"
