# Controller q changes only at native half_ce edges, separated by at least
# six sys_clk cycles. Prove each physical capture pin inactive between them.
set q_sources [get_cells -hierarchical -filter {NAME =~ "opna_cpu_i/opna/inst/core/control/q_reg*" && NAME !~ "*pcm_valid*" && REF_NAME =~ "FD*"}]
# The host commits only these 48 output bits at raw_half_due boundaries.
# SYS reset inhibits consumption until the first native edge at cycle seven.
# RUN, resetting and reset_pending remain ordinary one-cycle sources.
if {![llength [get_nets -quiet opna_cpu_i/opna/inst/host/raw_half_due]]} { error "Native-boundary AXI host is required" }
set host_boundary_sources {}
foreach field {ic_n cs_n wr_n rd_n core_addr core_din memory_type ddr_base} {
    set cells [get_cells -hierarchical -filter "NAME =~ opna_cpu_i/opna/inst/host/${field}_reg* && REF_NAME =~ FD*"]
    if {![llength $cells]} { error "Native-boundary host output missing: $field" }
    foreach cell $cells {
        if {[get_property IS_INVERTED [get_pins $cell/C]]} { error "Host output uses an inverted clock: $cell" }
        set clocks [get_clocks -quiet -of_objects [get_pins $cell/C]]
        if {[llength $clocks] != 1 || [get_property PERIOD $clocks] != 10.000} { error "Host output is outside sys_clk: $cell" }
    }
    set host_boundary_sources [concat $host_boundary_sources $cells]
}
# chip_phase changes only on an actual half_ce edge; SYS reset inhibits
# native consumption until the first edge at cycle seven.
set native_phase_sources [get_cells -hierarchical -filter {NAME =~ "opna_cpu_i/opna/inst/chip_phase_reg*" && REF_NAME =~ "FD*"}]
foreach cell $native_phase_sources {
    set clocks [get_clocks -quiet -of_objects [get_pins $cell/C]]
    if {[get_property IS_INVERTED [get_pins $cell/C]] || [llength $clocks] != 1 || [get_property PERIOD $clocks] != 10.000} {
        error "Native phase output is outside positive-edge sys_clk: $cell"
    }
}
if {![llength $native_phase_sources]} { error "Native phase register missing" }
set timing_reset_sources [concat $q_sources $host_boundary_sources $native_phase_sources [get_cells -hierarchical -filter {NAME =~ "opna_cpu_i/opna/inst/core/fm.engine/*" && REF_NAME =~ "FD*"}]]
set timing_reset_targets [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ "opna_cpu_i/opna/inst/core/*" && (REF_NAME =~ "FD*" || REF_NAME =~ "RAMB*")}] -filter {REF_PIN_NAME == D || REF_PIN_NAME == R || REF_PIN_NAME == S || REF_PIN_NAME == CE || REF_PIN_NAME =~ "ADDRARDADDR*" || REF_PIN_NAME == ENARDEN}]
# Physopt can change capture enables or feedback LUT pin assignments.
# Reset only our native exception region before proving the current netlist.
set_multicycle_path 1 -setup -reset_path -from $timing_reset_sources -to $timing_reset_targets
set_multicycle_path 0 -hold -from $timing_reset_sources -to $timing_reset_targets
set half_ce_segments [get_nets -segments opna_cpu_i/opna/inst/core/control/half_ce]
# Physical fanout optimization clones this LUT. Accept a clone only when
# its truth table and every input driver are identical to the native enable.
set half_ce_replica_proof {}
set half_ce_driver [get_pins -leaf -of_objects $half_ce_segments -filter {DIRECTION == OUT}]
if {[llength $half_ce_driver] != 1} { error "Native enable must have one driver" }
set half_ce_gate [get_cells -of_objects $half_ce_driver]
set half_ce_type [get_property REF_NAME $half_ce_gate]
if {[regexp {^LUT([1-6])$} $half_ce_type unused half_ce_width]} {
    foreach net [get_nets -hierarchical -filter {NAME =~ "opna_cpu_i/opna/inst/half_ce_repN*"}] {
        set segments [get_nets -segments $net]
        set driver [get_pins -leaf -of_objects $segments -filter {DIRECTION == OUT}]
        if {[llength $driver] != 1} { continue }
        set gate [get_cells -of_objects $driver]
        if {[get_property REF_NAME $gate] ne $half_ce_type ||
            [get_property INIT $gate] ne [get_property INIT $half_ce_gate]} { continue }
        set identical true
        set inputs {}
        for {set bit 0} {$bit < $half_ce_width} {incr bit} {
            set original [get_pins -leaf -of_objects [get_nets -segments -of_objects [get_pins $half_ce_gate/I$bit]] -filter {DIRECTION == OUT}]
            set replica [get_pins -leaf -of_objects [get_nets -segments -of_objects [get_pins $gate/I$bit]] -filter {DIRECTION == OUT}]
            if {[llength $original] != 1 || [llength $replica] != 1 || $original ne $replica} {
                set identical false; break
            }
            lappend inputs $original
        }
        if {$identical} {
            set half_ce_segments [concat $half_ce_segments $segments]
            lappend half_ce_replica_proof "$gate TYPE=$half_ce_type INIT=[get_property INIT $gate] INPUTS=$inputs"
        }
    }
}
array unset half_ce_low_memo
proc half_ce_low_value {pin} {
    global half_ce_segments half_ce_low_memo
    set nets [get_nets -quiet -segments -of_objects $pin]
    if {![llength $nets]} { return unknown }
    foreach net $nets {
        if {[lsearch -exact $half_ce_segments $net] >= 0} { return 0 }
        if {[info exists half_ce_low_memo($net)]} { return $half_ce_low_memo($net) }
    }
    foreach net $nets { set half_ce_low_memo($net) unknown }
    set drivers [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}]
    set value unknown
    if {[llength $drivers] == 1} {
        set driver [lindex $drivers 0]
        set cell [get_cells -of_objects $driver]
        set type [get_property REF_NAME $cell]
        if {$type eq "GND"} { set value 0 }
        if {$type eq "VCC"} { set value 1 }
        if {[regexp {^LUT([1-6])$} $type unused width]} {
            regexp {'h([0-9a-fA-F]+)$} [get_property INIT $cell] unused init_hex
            set init [expr "0x$init_hex"]
            set known {}
            for {set bit 0} {$bit < $width} {incr bit} {
                lappend known [half_ce_low_value [get_pins $cell/I$bit]]
            }
            set value unset
            for {set index 0} {$index < (1 << $width)} {incr index} {
                set possible true
                for {set bit 0} {$bit < $width} {incr bit} {
                    set fixed [lindex $known $bit]
                    if {$fixed ne "unknown" && (($index >> $bit) & 1) != $fixed} { set possible false; break }
                }
                if {!$possible} { continue }
                set output [expr {($init >> $index) & 1}]
                if {$value eq "unset"} { set value $output }
                if {$value != $output} { set value unknown; break }
            }
        }
        if {$type eq "MUXF7" || $type eq "MUXF8"} {
            set select [half_ce_low_value [get_pins $cell/S]]
            if {$select eq "0" || $select eq "1"} {
                set value [half_ce_low_value [get_pins $cell/I$select]]
            } else {
                set low [half_ce_low_value [get_pins $cell/I0]]
                set high [half_ce_low_value [get_pins $cell/I1]]
                if {$low eq $high} { set value $low }
            }
        }
    }
    foreach net $nets { set half_ce_low_memo($net) $value }
    return $value
}
set native_data {}
set native_enables {}
set native_resets {}
set native_addresses {}
set q_unqualified {}
set native_cells [get_cells -hierarchical -filter {NAME =~ "opna_cpu_i/opna/inst/core/*" && REF_NAME =~ "FD*" && NAME !~ "*pcm_valid*"}]
foreach cell $native_cells {
    if {[get_property IS_INVERTED [get_pins $cell/C]]} { continue }
    set clocks [get_clocks -quiet -of_objects [get_pins $cell/C]]
    if {[llength $clocks] != 1 || [get_property PERIOD $clocks] != 10.000} { continue }
    set ce_pin [get_pins -quiet $cell/CE]
    if {[half_ce_low_value $ce_pin] eq "0"} {
        lappend native_data [get_pins $cell/D]
        lappend native_enables $ce_pin
    } elseif {[lsearch -exact $q_sources $cell] >= 0} {
        lappend q_unqualified $cell
    }
    foreach pin [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == R || REF_PIN_NAME == S}] {
        if {[half_ce_low_value $pin] eq "0"} {
            set driver_types [get_property REF_NAME [get_cells -of_objects [get_pins -quiet -leaf -of_objects [get_nets -segments -of_objects $pin] -filter {DIRECTION == OUT}]]]
            if {$driver_types ne "GND"} { lappend native_resets $pin }
        }
    }
}
# Each native FM ROM consumes its address only on a proven gated A-port.
foreach ram [get_cells -hierarchical -filter {(NAME =~ "opna_cpu_i/opna/inst/core/fm.engine/u_op/u_exprom/*" || NAME =~ "opna_cpu_i/opna/inst/core/fm.engine/u_op/u_logsin/*") && REF_NAME =~ "RAMB*"}] {
    set clocks [get_clocks -quiet -of_objects [get_pins $ram/CLKARDCLK]]
    if {[llength $clocks] != 1 || [get_property PERIOD $clocks] != 10.000} { continue }
    set enable [get_pins $ram/ENARDEN]
    if {[half_ce_low_value $enable] eq "0"} {
        lappend native_enables $enable
        set native_addresses [concat $native_addresses [get_pins -of_objects $ram -filter {REF_PIN_NAME =~ "ADDRARDADDR*"}]]
    }
}
# PCM-valid clears every SYS cycle. Its data input is insensitive to native
# state between half_ce edges only when the mapped HAL=0 cofactor is zero.
# Its Q remains an ordinary one-cycle source.
set native_pulse_data {}
set native_pulse_proof {}
foreach cell [get_cells -hierarchical -regexp {^opna_cpu_i/opna/inst/core/control/q_reg\[pcm_valid\]\[[01]\](_replica.*)?$}] {
    if {[get_property REF_NAME $cell] ne "FDRE"} { continue }
    set clocks [get_clocks -quiet -of_objects [get_pins $cell/C]]
    if {[get_property IS_INVERTED [get_pins $cell/C]] || [llength $clocks] != 1 || [get_property PERIOD $clocks] != 10.000} { continue }
    if {[half_ce_low_value [get_pins $cell/D]] eq "0" &&
        [half_ce_low_value [get_pins $cell/CE]] eq "1" &&
        [half_ce_low_value [get_pins $cell/R]] eq "0"} {
        lappend native_pulse_data [get_pins $cell/D]
        lappend native_pulse_proof "$cell TYPE=FDRE CLK=$clocks PERIOD=10.000 INVERTED=0 D_HAL0=0 CE_HAL0=1 R_HAL0=0"
    }
}
set native_targets [concat $native_data $native_enables $native_resets $native_addresses $native_pulse_data]
if {![llength $native_targets]} { error "No native capture pins with proven half_ce gating" }
set qualified_engine_sources {}
foreach cell [get_cells -quiet -hierarchical -filter {NAME =~ "opna_cpu_i/opna/inst/core/fm.engine/*" && (REF_NAME == FDRE || REF_NAME == FDSE)}] {
    if {[get_property IS_INVERTED [get_pins $cell/C]]} { continue }
    set clocks [get_clocks -quiet -of_objects [get_pins $cell/C]]
    if {[llength $clocks] != 1 || [get_property PERIOD $clocks] != 10.000} { continue }
    if {[half_ce_low_value [get_pins $cell/CE]] ne "0"} { continue }
    set resets_gated true
    foreach pin [get_pins -of_objects $cell -filter {REF_PIN_NAME == R || REF_PIN_NAME == S}] {
        if {[half_ce_low_value $pin] ne "0"} { set resets_gated false }
    }
    if {$resets_gated} { lappend qualified_engine_sources $cell }
}
set native_sources [concat $q_sources $qualified_engine_sources $host_boundary_sources $native_phase_sources]
set_multicycle_path 6 -setup -from $native_sources -to $native_targets
set_multicycle_path 5 -hold -from $native_sources -to $native_targets
# A physical always-enabled FF can retain its value through a final LUT.
# Keep its direct Q feedback at one cycle; qualify only other LUT branches
# after proving the half_ce=0 cofactor equals that exact FF's Q for all inputs.
set feedback_branches {}
set direct_feedback {}
foreach cell $q_unqualified {
    set d_pin [get_pins $cell/D]
    set drivers [get_pins -quiet -leaf -of_objects [get_nets -segments -of_objects $d_pin] -filter {DIRECTION == OUT}]
    if {[llength $drivers] != 1} { continue }
    set gate [lindex [get_cells -of_objects $drivers] 0]
    if {![regexp {^LUT([1-6])$} [get_property REF_NAME $gate] unused width]} { continue }
    set feedback_bit -1
    set known {}
    for {set bit 0} {$bit < $width} {incr bit} {
        set pin [get_pins $gate/I$bit]
        set input_drivers [get_pins -quiet -leaf -of_objects [get_nets -segments -of_objects $pin] -filter {DIRECTION == OUT}]
        if {[llength $input_drivers] == 1 && [get_property NAME $input_drivers] eq "$cell/Q"} { set feedback_bit $bit }
        lappend known [half_ce_low_value $pin]
    }
    if {$feedback_bit < 0} { continue }
    regexp {'h([0-9a-fA-F]+)$} [get_property INIT $gate] unused init_hex
    set init [expr "0x$init_hex"]
    set proven true
    for {set index 0} {$index < (1 << $width)} {incr index} {
        set possible true
        for {set bit 0} {$bit < $width} {incr bit} {
            set fixed [lindex $known $bit]
            if {$fixed ne "unknown" && (($index >> $bit) & 1) != $fixed} { set possible false; break }
        }
        if {$possible && (($init >> $index) & 1) != (($index >> $feedback_bit) & 1)} { set proven false; break }
    }
    if {!$proven} { continue }
    lappend direct_feedback [get_pins $gate/I$feedback_bit]
    set branch_pins {}
    for {set bit 0} {$bit < $width} {incr bit} {
        if {$bit != $feedback_bit} { lappend branch_pins [get_pins $gate/I$bit] }
    }
    set_multicycle_path 6 -setup -from $native_sources -through $branch_pins -to $d_pin
    set_multicycle_path 5 -hold -from $native_sources -through $branch_pins -to $d_pin
    lappend feedback_branches [list $d_pin $branch_pins]
}
set native_timing_out [file normalize [file join [file dirname [info script]] ../../build/opna_phase7/board]]
set proof_file [open [file join $native_timing_out native-mcp-targets.txt] w]
puts $proof_file "proven_half_ce_replicas [llength $half_ce_replica_proof]"
puts $proof_file [join $half_ce_replica_proof \n]
foreach {name pins} [list data_D $native_data enable $native_enables reset_set $native_resets rom_address $native_addresses zero_cofactor_pulse_D $native_pulse_data one_cycle_controller $q_unqualified] {
    puts $proof_file "$name [llength $pins]"
    puts $proof_file [join $pins \n]
}
puts $proof_file "proven_next_state_branches [llength $feedback_branches]"
puts $proof_file [join $feedback_branches \n]
puts $proof_file "one_cycle_direct_feedback [llength $direct_feedback]"
puts $proof_file [join $direct_feedback \n]
puts $proof_file "pcm_valid_zero_cofactor_proof [llength $native_pulse_proof]"
puts $proof_file [join $native_pulse_proof \n]
puts $proof_file "native_controller_sources [llength $q_sources]"
puts $proof_file [join $q_sources \n]
puts $proof_file "proven_engine_sources [llength $qualified_engine_sources]"
puts $proof_file [join $qualified_engine_sources \n]
puts $proof_file "native_boundary_host_sources [llength $host_boundary_sources]"
puts $proof_file [join $host_boundary_sources \n]
puts $proof_file "native_phase_sources [llength $native_phase_sources]"
puts $proof_file [join $native_phase_sources \n]
close $proof_file
report_exceptions -summary -file [file join $native_timing_out native-timing-exceptions.rpt]
set budget_file [open [file join $native_timing_out native-path-budgets.tsv] w]
puts $budget_file "category\trequirement_ns\tslack_ns\tfrom\tto"
foreach {category sources targets} [list host_rom $host_boundary_sources $native_addresses phase_native $native_phase_sources $native_targets half_acc_native [get_cells -hierarchical -filter {NAME =~ "opna_cpu_i/opna/inst/half_acc_reg*"}] $native_targets run_native [get_cells -hierarchical -filter {NAME =~ "opna_cpu_i/opna/inst/host/run_enable_reg*"}] $native_targets] {
    if {![llength $sources] || ![llength $targets]} {
        puts $budget_file "$category\tno_qualified_path"
        continue
    }
    set path [get_timing_paths -delay_type max -max_paths 1 -from $sources -to $targets]
    if {[llength $path]} {
        puts $budget_file "$category\t[get_property REQUIREMENT $path]\t[get_property SLACK $path]\t[get_property STARTPOINT_PIN $path]\t[get_property ENDPOINT_PIN $path]"
    }
}
if {[llength $native_pulse_data]} {
    foreach {category sources} [list host_pulse $host_boundary_sources half_acc_pulse [get_cells -hierarchical -filter {NAME =~ "opna_cpu_i/opna/inst/half_acc_reg*"}]] {
        set path [get_timing_paths -delay_type max -max_paths 1 -from $sources -to $native_pulse_data]
        if {[llength $path]} {
            puts $budget_file "$category\t[get_property REQUIREMENT $path]\t[get_property SLACK $path]\t[get_property STARTPOINT_PIN $path]\t[get_property ENDPOINT_PIN $path]"
        }
    }
}
if {[llength $direct_feedback]} {
    set path [get_timing_paths -delay_type max -max_paths 1 -through $direct_feedback -to [get_pins -of_objects $q_unqualified -filter {REF_PIN_NAME == D}]]
    if {[llength $path]} {
        puts $budget_file "direct_feedback\t[get_property REQUIREMENT $path]\t[get_property SLACK $path]\t[get_property STARTPOINT_PIN $path]\t[get_property ENDPOINT_PIN $path]"
    }
}
close $budget_file
puts "OPNA_NATIVE_MCP q_sources=[llength $q_sources] engine_sources=[llength $qualified_engine_sources] host_sources=[llength $host_boundary_sources] phase_sources=[llength $native_phase_sources] data=[llength $native_data] enable=[llength $native_enables] reset_set=[llength $native_resets] rom_address=[llength $native_addresses] pulse_data=[llength $native_pulse_data] one_cycle_controller=[llength $q_unqualified] next_state_branches=[llength $feedback_branches] setup=6 hold=5"
