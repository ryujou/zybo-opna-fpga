# SPDX-License-Identifier: GPL-3.0-or-later
if {[llength $argv] < 4 || [llength $argv] > 6} {
    error "Usage: xsct phase7_jtag.tcl XSA BIT ELF PS7_INIT_TCL ?URL? ?CABLE_SERIAL?"
}
foreach variable {xsa bitfile elffile psinit} index {0 1 2 3} {
    set $variable [file normalize [lindex $argv $index]]
    if {![file isfile [set $variable]]} { error "Missing $variable: [set $variable]" }
}
set url [expr {[llength $argv] >= 5 ? [lindex $argv 4] : "tcp:127.0.0.1:3121"}]
set serial [expr {[llength $argv] >= 6 ? [lindex $argv 5] : "210279540276A"}]
connect -url $url

# Each selection must match exactly one target on the actual Zybo cable.
targets -set -timeout 10 -filter [format {name == "APU" && jtag_cable_serial == "%s"} $serial]
loadhw -hw $xsa
rst -system -stop
targets -set -timeout 10 -filter [format {name == "xc7z010" && jtag_cable_serial == "%s"} $serial]
fpga -file $bitfile
targets -set -timeout 10 -filter [format {name == "APU" && jtag_cable_serial == "%s"} $serial]
source $psinit
ps7_init
ps7_post_config
targets -set -timeout 10 -filter [format {name == "ARM Cortex-A9 MPCore #0" && jtag_cable_serial == "%s"} $serial]
rst -processor -clear-registers
set board_id [lindex [mrd -value 0x43C0001C] 0]
if {$board_id != 0x26080008} {
    error "OPNA board ID mismatch: $board_id"
}
dow $elffile
con
puts "PHASE7_JTAG_STARTED cable=$serial board_id=$board_id elf=$elffile"
disconnect
