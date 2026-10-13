# SPDX-License-Identifier: MIT
# Pin assignments: Digilent original Zybo Rev. B master constraints.
# https://github.com/Digilent/digilent-xdc/blob/master/Zybo-Master.xdc
set_property PACKAGE_PIN L16 [get_ports clk125]
set_property IOSTANDARD LVCMOS33 [get_ports clk125]
create_clock -period 8.000 -name clk125 -waveform {0.000 4.000} -add [get_ports clk125]
set_property PACKAGE_PIN G15 [get_ports sw0]
set_property IOSTANDARD LVCMOS33 [get_ports sw0]
# SW0 is asynchronous; only its first synchronizer stage is excepted.
set_false_path -from [get_ports sw0] -to [get_pins -hierarchical -filter {NAME =~ */mode_meta_reg/D}]
set_property PACKAGE_PIN M14 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property PACKAGE_PIN M15 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property PACKAGE_PIN G14 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property PACKAGE_PIN D18 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]
set_property PACKAGE_PIN K18 [get_ports i2s_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_sclk]
set_property PACKAGE_PIN T19 [get_ports ac_mclk]
set_property IOSTANDARD LVCMOS33 [get_ports ac_mclk]
set_property PACKAGE_PIN P18 [get_ports ac_mute_n]
set_property IOSTANDARD LVCMOS33 [get_ports ac_mute_n]
set_property PACKAGE_PIN M17 [get_ports i2s_sd]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_sd]
set_property PACKAGE_PIN L17 [get_ports i2s_ws]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_ws]
set_property PACKAGE_PIN N18 [get_ports IIC_0_scl_io]
set_property IOSTANDARD LVCMOS33 [get_ports IIC_0_scl_io]
set_property PACKAGE_PIN N17 [get_ports IIC_0_sda_io]
set_property IOSTANDARD LVCMOS33 [get_ports IIC_0_sda_io]

# Only the first synchronizer stage crosses unrelated PS/audio clocks.
set_false_path -from [get_cells opna_cpu_i/opna/inst/audio/request_toggle_reg] -to [get_pins {opna_cpu_i/opna/inst/audio/request_sync_reg[0]/D}]
set_false_path -from [get_cells opna_cpu_i/opna/inst/audio/response_toggle_reg] -to [get_pins {opna_cpu_i/opna/inst/audio/response_sync_reg[0]/D}]
set_false_path -from [get_cells opna_cpu_i/opna/inst/audio/mute_source_reg] -to [get_pins {opna_cpu_i/opna/inst/audio/mute_sync_reg[0]/D}]
# The response toggle travels through two audio FFs before the 48 kHz
# boundary consumes this stable stereo mailbox. Keep its physical delay
# checked; asynchronous clock groups would override this constraint.
set_max_delay -datapath_only -from [get_cells -hierarchical -regexp {^opna_cpu_i/opna/inst/audio/mailbox_reg\[[0-9]+\]$}] -to [get_pins -hierarchical -regexp {^opna_cpu_i/opna/inst/audio/audio_frame_reg\[[0-9]+\]/D$}] 10.000
set_bus_skew -from [get_cells -hierarchical -regexp {^opna_cpu_i/opna/inst/audio/mailbox_reg\[[0-9]+\]$}] -to [get_pins -hierarchical -regexp {^opna_cpu_i/opna/inst/audio/audio_frame_reg\[[0-9]+\]/D$}] 10.000

create_generated_clock -name codec_mclk -source [get_pins opna_cpu_i/audio_clock/inst/mmcm_adv_inst/CLKOUT0] -divide_by 1 [get_ports ac_mclk]
# phase[1] rises at audio cycles 2, 6, ... and falls at cycles 4, 8, ... .
create_generated_clock -name codec_bclk -source [get_pins opna_cpu_i/audio_clock/inst/mmcm_adv_inst/CLKOUT0] -edges {5 9 13} [get_ports i2s_sclk]
# SSM2603 slave-mode Table 4 requires 10 ns setup and hold for SD and WS.
# https://www.analog.com/media/en/technical-documentation/data-sheets/SSM2603.pdf
set_output_delay -clock codec_bclk -max 10.000 [get_ports {i2s_sd i2s_ws}]
set_output_delay -clock codec_bclk -min -10.000 [get_ports {i2s_sd i2s_ws}]
# LEDs and the codec hardware-mute level have no synchronous receiver.
set_false_path -to [get_ports {{led[*]} ac_mute_n}]


