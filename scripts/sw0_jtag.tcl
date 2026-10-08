# -1 restores the physical switch; 0/1 enters the ordinary debounced mode path.
if {$argc != 2} { error "Usage: xsct sw0_jtag.tcl ELF -1|0|1" }
set elf [file normalize [lindex $argv 0]]
set level [lindex $argv 1]
if {$level ni {-1 0 1}} { error "Expected -1, 0 or 1" }
set nm J:/FPGA/2025.2/Vitis/gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-nm.exe
foreach line [split [exec $nm --defined-only $elf] \n] {
    if {[regexp {^([0-9a-fA-F]+) [A-Za-z] (usb_sw0_override|usb_active_mode|usb_mode_changes)$} $line -> address name]} {
        set addresses($name) 0x$address
    }
}
connect -url tcp:127.0.0.1:3121
targets -set -timeout 10 -filter {name == "ARM Cortex-A9 MPCore #0" && jtag_cable_serial == "210279540276A"}
set physical [expr {[mrd -force -value 0x43C00020] & 1}]
mwr -force $addresses(usb_sw0_override) [expr {$level & 0xffffffff}]
set effective [expr {$level < 0 ? $physical : $level}]
set expected [expr {$effective ? 2 : 1}]
set matched 0
for {set n 0} {$n < 60} {incr n} {
    after 100
    set active [mrd -force -value $addresses(usb_active_mode)]
    if {$active == $expected} {set matched 1; break}
}
if {!$matched} {error "Mode did not change: expected=$expected active=$active"}
after 1200
puts "SW0_JTAG physical=$physical override=$level effective=$effective active=$active changes=[mrd -force -value $addresses(usb_mode_changes)]"
disconnect
