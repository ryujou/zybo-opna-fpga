proc opna_debug_signal {pin} {
    set pins [get_pins -quiet $pin]
    if {[llength $pins] != 1} { error "ILA signal pin missing: $pin" }
    set nets [get_nets -of_objects $pins]
    if {[llength $nets] != 1} { error "ILA signal net missing: $pin" }
    return $nets
}

proc opna_debug_vector {name width} {
    set nets {}
    for {set bit 0} {$bit < $width} {incr bit} {
        set net [get_nets -hierarchical -regexp [format {^%s\[%d\]$} $name $bit]]
        if {[llength $net] != 1} { error "ILA vector bit missing: $name bit $bit" }
        lappend nets $net
    }
    return $nets
}

proc opna_debug_probe {core number nets} {
    if {$number > 0} { create_debug_port $core probe }
    set port [get_debug_ports $core/probe$number]
    set_property PORT_WIDTH [llength $nets] $port
    set_property MARK_DEBUG true $nets
    connect_debug_port $port $nets
}

set native_path opna_cpu_i/opna/inst
set audio_path $native_path/audio
# ILA branches require fabric routing from these output registers.
set_property IOB false [get_cells [list \
    $audio_path/phase_reg\[1\] $audio_path/phase_reg\[7\] $audio_path/i2s_sd_reg]]
create_debug_core opna_ila_native ila
set_property C_DATA_DEPTH 8192 [get_debug_cores opna_ila_native]
set_property C_EN_STRG_QUAL true [get_debug_cores opna_ila_native]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores opna_ila_native]
set_property ALL_PROBE_SAME_MU_CNT 2 [get_debug_cores opna_ila_native]
connect_debug_port opna_ila_native/clk [opna_debug_signal $native_path/half_ce_delayed_reg/C]
opna_debug_probe opna_ila_native 0 [opna_debug_signal $native_path/half_ce_delayed_reg/Q]
opna_debug_probe opna_ila_native 1 [opna_debug_vector $native_path/debug_native_inputs 25]
opna_debug_probe opna_ila_native 2 [opna_debug_vector $native_path/debug_native_outputs 81]
opna_debug_probe opna_ila_native 3 [opna_debug_vector $native_path/debug_sys_counter 32]

create_debug_core opna_ila_audio ila
set_property C_DATA_DEPTH 4096 [get_debug_cores opna_ila_audio]
set_property C_EN_STRG_QUAL false [get_debug_cores opna_ila_audio]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores opna_ila_audio]
connect_debug_port opna_ila_audio/clk [opna_debug_signal $audio_path/phase_reg\[0\]/C]
set frame_nets {}
for {set bit 0} {$bit < 32} {incr bit} {
    lappend frame_nets [opna_debug_signal [format {%s/audio_frame_reg[%d]/Q} $audio_path $bit]]
}
opna_debug_probe opna_ila_audio 0 $frame_nets
set phase_nets {}
for {set bit 0} {$bit < 8} {incr bit} {
    lappend phase_nets [opna_debug_signal [format {%s/phase_reg[%d]/Q} $audio_path $bit]]
}
opna_debug_probe opna_ila_audio 1 $phase_nets
opna_debug_probe opna_ila_audio 2 [list \
    [opna_debug_signal $audio_path/i2s_sd_reg/Q] \
    [opna_debug_signal $audio_path/phase_reg\[7\]/Q] \
    [opna_debug_signal $audio_path/phase_reg\[1\]/Q] \
    [opna_debug_signal ac_mute_n_OBUF_inst/I]]
opna_debug_probe opna_ila_audio 3 [list \
    [opna_debug_signal $audio_path/request_toggle_reg/Q] \
    [opna_debug_signal $audio_path/response_sync_reg\[1\]/Q] \
    [opna_debug_signal $audio_path/mute_sync_reg\[1\]/Q] \
    [opna_debug_signal $audio_path/active_reg/Q] \
    [get_nets -of_objects [get_pins $audio_path/audio_resetn]]]

set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [opna_debug_signal $native_path/half_ce_delayed_reg/C]
puts "OPNA_ILA_NATIVE depth8192 width139 clock100MHz storage_qualifier=probe0_EQ1"
puts "OPNA_ILA_AUDIO depth4096 width49 clock12.288002512562814MHz unqualified"
