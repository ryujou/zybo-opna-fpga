# SPDX-License-Identifier: GPL-3.0-or-later
if {[llength $argv] != 3} { error "Usage: vivado -tclargs LTX OUTPUT_DIRECTORY native|audio" }
set ltx [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
set mode [lindex $argv 2]
if {$mode ni {native audio} || ![file isfile $ltx]} { error "Expected an actual LTX and native or audio mode" }
file mkdir $out
open_hw_manager
connect_hw_server -url localhost:3121
set target [get_hw_targets -filter {NAME =~ "*/210279540276A"}]
if {[llength $target] != 1} { error "Expected Zybo cable 210279540276A" }
open_hw_target $target
set device [get_hw_devices -filter {PART == "xc7z010"}]
if {[llength $device] != 1} { error "Expected one XC7Z010" }
current_hw_device $device
set_property PROBES.FILE $ltx $device
refresh_hw_device -update_hw_probes true $device
set ila [get_hw_ilas -of_objects $device -filter "CELL_NAME =~ *opna_ila_${mode}*"]
if {[llength $ila] != 1} { error "Expected one $mode ILA" }
set_property CONTROL.TRIGGER_POSITION 0 $ila
set_property CONTROL.TRIGGER_CONDITION AND $ila
if {$mode eq "native"} {
    set qualifier [get_hw_probes -of_objects $ila -filter {WIDTH == 1}]
    set inputs [get_hw_probes -of_objects $ila -filter {WIDTH == 25}]
    if {[llength $qualifier] != 1 || [llength $inputs] != 1} { error "Native probe layout mismatch" }
    set_property CONTROL.DATA_DEPTH 8192 $ila
    set_property CONTROL.CAPTURE_MODE BASIC $ila
    set_property CONTROL.CAPTURE_CONDITION AND $ila
    set_property CAPTURE_COMPARE_VALUE eq1'b1 $qualifier
    set_property TRIGGER_COMPARE_VALUE eq1'b1 $qualifier
    set_property TRIGGER_COMPARE_VALUE eq25'b0XXXXXXXXXXXXXXXXXXXXXXXX $inputs
    run_hw_ila $ila
} else {
    set_property CONTROL.DATA_DEPTH 4096 $ila
    run_hw_ila -trigger_now $ila
}
puts "OPNA_ILA_ARMED mode=$mode"
flush stdout
wait_on_hw_ila -timeout 0.8 $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -csv_file -force [file join $out $mode.csv] $data
close_hw_target
close_hw_manager
puts "OPNA_ILA_CAPTURE_COMPLETE mode=$mode"

