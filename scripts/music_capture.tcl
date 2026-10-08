if {$argc < 4} {error "Usage: music_capture.tcl LTX OUTPUT windows|bus|clip SECONDS..."}
set out [file normalize [lindex $argv 1]]
file mkdir $out
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [get_hw_targets -filter {NAME =~ "*/210279540276A"}]
set device [get_hw_devices -filter {PART == "xc7z010"}]
current_hw_device $device
set_property PROBES.FILE [file normalize [lindex $argv 0]] $device
refresh_hw_device -update_hw_probes true $device
set native [get_hw_ilas -of_objects $device -filter {CELL_NAME =~ *opna_ila_native*}]
set audio [get_hw_ilas -of_objects $device -filter {CELL_NAME =~ *opna_ila_audio*}]
foreach ila [list $native $audio] {
    set_property CONTROL.TRIGGER_POSITION 0 $ila
}
set_property CONTROL.CAPTURE_MODE BASIC $native
set_property CONTROL.CAPTURE_CONDITION AND $native
set_property CONTROL.DATA_DEPTH 8192 $native
set counter [get_hw_probes -of_objects $native -filter {WIDTH == 32}]
set_property CAPTURE_COMPARE_VALUE eq32'bXXXXXXXXXXXXXXXXXXXXX00000000000 $counter
set_property TRIGGER_COMPARE_VALUE eq32'bXXXXXXXXXXXXXXXXXXXXX00000000000 $counter
set_property CONTROL.DATA_DEPTH 4096 $audio
# The installed audio ILA captures raw I2S clocks (16 stereo frames).
if {[lindex $argv 2] eq "bus"} {
    set half [get_hw_probes -of_objects $native -filter {WIDTH == 1}]
    set inputs [get_hw_probes -of_objects $native -filter {WIDTH == 25}]
    set_property CAPTURE_COMPARE_VALUE eq32'hXXXXXXXX $counter
    set_property TRIGGER_COMPARE_VALUE eq32'hXXXXXXXX $counter
    set_property CAPTURE_COMPARE_VALUE eq1'b1 $half
    set_property TRIGGER_COMPARE_VALUE eq1'b1 $half
    set_property CAPTURE_COMPARE_VALUE eq25'b100XXXXXXXXXXXXXXXXXXXXXX $inputs
    set_property TRIGGER_COMPARE_VALUE eq25'b100XXXXXXXXXXXXXXXXXXXXXX $inputs
    run_hw_ila $native
}
set f [open [file join $out ready] w]; close $f
set deadline [expr {[clock milliseconds]+120000}]
while {![file exists [file join $out start]]} {
    if {[clock milliseconds]>$deadline} {error "Playback start timeout"}
    after 50
}
set f [open [file join $out start] r]; set start [string trim [read $f]]; close $f
if {[lindex $argv 2] eq "bus"} {
    wait_on_hw_ila -timeout 10 $native
    set data [upload_hw_ila_data $native]
    write_hw_ila_data -csv_file -force [file join $out bus.csv] $data
    set_property CAPTURE_COMPARE_VALUE eq1'bX $half
    set_property TRIGGER_COMPARE_VALUE eq1'bX $half
    set_property CAPTURE_COMPARE_VALUE eq25'bXXXXXXXXXXXXXXXXXXXXXXXXX $inputs
    set_property TRIGGER_COMPARE_VALUE eq25'bXXXXXXXXXXXXXXXXXXXXXXXXX $inputs
    set_property CAPTURE_COMPARE_VALUE eq32'bXXXXXXXXXXXXXXXXXXXXX00000000000 $counter
    set_property TRIGGER_COMPARE_VALUE eq32'bXXXXXXXXXXXXXXXXXXXXX00000000000 $counter
    puts MUSIC_BUS_CAPTURED
}
if {[lindex $argv 2] eq "clip"} {
    set delay [expr {$start+5000-[clock milliseconds]}]
    if {$delay>0} {after $delay}
    set frame [get_hw_probes -of_objects $audio -filter {WIDTH == 32}]
    set_property CONTROL.TRIGGER_POSITION 1024 $audio
    set_property TRIGGER_COMPARE_VALUE eq32'h7fffXXXX $frame
    run_hw_ila $audio
    wait_on_hw_ila -timeout 20 $audio
    set data [upload_hw_ila_data $audio]
    write_hw_ila_data -csv_file -force [file join $out clip-audio.csv] $data
    puts MUSIC_CLIP_CAPTURED
} else {
foreach second [lrange $argv 3 end] {
    set delay [expr {$start+$second*1000-[clock milliseconds]}]
    if {$delay>0} {after $delay}
    set stamp [clock milliseconds]
    run_hw_ila $native
    run_hw_ila -trigger_now $audio
    wait_on_hw_ila -timeout 3 $native
    wait_on_hw_ila -timeout 3 $audio
    foreach ila [list $native $audio] mode {native audio} {
        set data [upload_hw_ila_data $ila]
        write_hw_ila_data -csv_file -force [file join $out ${second}-${mode}.csv] $data
    }
    puts "MUSIC_CAPTURE second=$second arm_ms=[expr {$stamp-$start}]"
    flush stdout
}
}
close_hw_target
close_hw_manager
puts MUSIC_CAPTURE_COMPLETE
