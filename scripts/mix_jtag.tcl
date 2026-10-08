# Stopped-playback diagnostic path. The caller performs ENTER and RESET first.
if {$argc != 3} { error "Usage: xsct mix_jtag.tcl PCM_Q16 SSG_Q16 MASTER_Q16" }
connect -url tcp:127.0.0.1:3121
targets -set -timeout 10 -filter {name == "ARM Cortex-A9 MPCore #0" && jtag_cable_serial == "210279540276A"}
if {[mrd -force -value 0x43C0001C] != 0x26080008} { error "Mix FPGA interface mismatch" }
mwr -force 0x43C00004 4
if {[mrd -force -value 0x43C00004] != 4} { error "Mix update requires stopped and muted core" }
foreach address {0x43C00024 0x43C00028 0x43C0002C} value $argv {
    mwr -force $address $value
    set actual [mrd -force -value $address]
    if {$actual != $value} { error "Gain readback mismatch: $address $actual $value" }
    puts "GAIN $address $actual"
}
mwr -force 0x43C00030 1
mwr -force 0x43C00034 1
mwr -force 0x43C00004 1
puts "JTAG_MIX_COMPLETE"
disconnect
