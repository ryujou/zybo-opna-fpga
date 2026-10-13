set hw [hsi::open_hw_design [lindex $argv 0]]
set vitis J:/FPGA/2025.2/Vitis
if {[info exists env(XILINX_VITIS)]} { set vitis $env(XILINX_VITIS) }
hsi::set_repo_path [file join $vitis data embeddedsw]
hsi::generate_app -hw $hw -os standalone -proc ps7_cortexa9_0 -app zynq_fsbl -dir [lindex $argv 1]
puts OPNA_FSBL_GENERATED
exit
