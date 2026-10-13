proc opna_core_sources {root} {
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
    foreach name {jt49_opna jt10_opna_rom jt10_opna_rhythm jt10_opna_adpcm ym2608_control ym2608} {
        lappend sources [file join $root hardware/rtl/opna_core/$name.sv]
    }
    return $sources
}
