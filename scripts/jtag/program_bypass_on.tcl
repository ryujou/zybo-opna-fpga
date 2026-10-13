set repo_root [file normalize [file join [file dirname [info script]] .. ..]]
set bit_dir [expr {[info exists ::env(BITSTREAM_DIR)] ? $::env(BITSTREAM_DIR) : [file join $repo_root build bitstreams]}]
set elf_path [expr {[info exists ::env(ELF_PATH)] ? $::env(ELF_PATH) : [file join $repo_root build software opna_bringup.elf]}]
set bit_path [file join $bit_dir opna_bypass_on.bit]

set ps7_init ""
foreach candidate [list \
    [file join $repo_root build vivado_zybo_opna zybo_opna.gen sources_1 bd opna_cpu ip opna_cpu_processing_system7_0_0 ps7_init.tcl] \
    [file join $repo_root build xsa ps7_init.tcl] \
    [file join $repo_root build vitis_ws opna_plat hw ps7_init.tcl] \
] {
    if {[file exists $candidate]} {
        set ps7_init $candidate
        break
    }
}

proc require_file {label path} {
    if {![file exists $path]} {
        puts "ERROR: $label not found: $path"
        exit 1
    }
    puts "$label: $path"
}

puts "============================================"
puts "JTAG PROGRAM bypass_on"
puts "============================================"
require_file "bitstream" $bit_path
require_file "ELF" $elf_path
if {$ps7_init eq ""} {
    puts "ERROR: ps7_init.tcl not found"
    exit 1
}
puts "ps7_init: $ps7_init"

puts "Connecting JTAG..."
connect
puts "ps7_init"
cd [file dirname $ps7_init]
source ps7_init.tcl
cd $repo_root

puts "Programming FPGA..."
targets -set -nocase -filter {name =~ "*xc7z010*"}
fpga -file $bit_path
after 500

targets -set -nocase -filter {name =~ "*APU*"}
catch {stop}
ps7_init
puts "ps7_post_config"
ps7_post_config

targets -set -nocase -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
if {[catch {rst -processor} rst_err]} {
    puts "ERROR: rst -processor failed: $rst_err"
    exit 1
}

puts "dow opna_bringup.elf"
if {[catch {dow $elf_path} dow_err]} {
    puts "ERROR: dow failed: $dow_err"
    exit 1
}

catch {stop}
puts "con"
if {[catch {con} con_err]} {
    if {[string match "*Already running*" $con_err]} {
        puts "INFO: target already running after dow"
    } else {
        puts "ERROR: con failed: $con_err"
        exit 1
    }
}
