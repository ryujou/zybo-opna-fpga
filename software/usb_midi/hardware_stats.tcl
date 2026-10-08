set root [file normalize [file join [file dirname [info script]] ../..]]
set vitis J:/FPGA/2025.2/Vitis
if {[info exists env(XILINX_VITIS)]} { set vitis $env(XILINX_VITIS) }
set nm [file join $vitis gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-nm.exe]
set elf [file join $root build/usb_midi/opna_usb_midi.elf]
if {$argc > 0} { set elf [file normalize [lindex $argv 0]] }
set symbols [exec $nm -C --defined-only $elf]
foreach line [split $symbols \n] {
    if {[regexp {^([0-9a-fA-F]+) [A-Za-z] (.*)$} $line -> address name]} {
        set addresses($name) 0x$address
    }
}
connect -url tcp:127.0.0.1:3121
targets -set -timeout 10 -filter {name == "ARM Cortex-A9 MPCore #0" && jtag_cable_serial == "210279540276A"}
foreach name {
    midi_processed_events midi_max_dispatch_us midi_max_handler_us
    {(anonymous namespace)::received} {(anonymous namespace)::overflows}
    {(anonymous namespace)::malformed} {(anonymous namespace)::resets}
    midi_usb_setup_count midi_usb_ep0_tx_count midi_usb_send_errors
    __malloc_max_sbrked_mem
} {
    puts "$name = [mrd -force -value $addresses($name)]"
}
set name {(anonymous namespace)::configured}
puts "configured = [mrd -force -size b -value $addresses($name)]"
puts "PORTSC = [mrd -force -value 0xe0002184]"
if {[info exists addresses(usb_active_mode)]} {
    foreach name {usb_active_mode usb_mode_changes} {
        puts "$name = [mrd -force -value $addresses($name)]"
    }
    if {[info exists addresses(usb_sw0_override)]} {
        puts "SW0 override = [mrd -force -value $addresses(usb_sw0_override)]"
    }
    puts "SW0 = [mrd -force -value 0x43C00020]"
}
disconnect
exit
