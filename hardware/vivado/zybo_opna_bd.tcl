proc create_opna_bd_design {design_name} {
    create_bd_design $design_name
    set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
    configure_zybo_ps7 $ps
    set_property -dict [list \
        CONFIG.PCW_EN_CLK0_PORT {1} \
        CONFIG.PCW_EN_RST0_PORT {1} \
        CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
        CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
        CONFIG.PCW_FCLK_CLK0_BUF {TRUE} \
        CONFIG.PCW_USE_M_AXI_GP0 {1} \
        CONFIG.PCW_USE_S_AXI_HP0 {1} \
        CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
        CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
        CONFIG.PCW_IRQ_F2P_INTR {1} \
        CONFIG.PCW_EN_I2C0 {1} \
        CONFIG.PCW_I2C0_I2C0_IO {EMIO} \
        CONFIG.PCW_EN_EMIO_I2C0 {1} \
        CONFIG.PCW_I2C0_BASEADDR {0xE0004000} \
        CONFIG.PCW_I2C0_HIGHADDR {0xE0004FFF} \
        CONFIG.PCW_I2C0_PERIPHERAL_ENABLE {1} \
        CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {1} \
        CONFIG.PCW_GPIO_PERIPHERAL_ENABLE {1} \
        CONFIG.PCW_USB0_RESET_ENABLE {1} \
        CONFIG.PCW_USB0_RESET_IO {MIO 46} \
    ] $ps
    apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable"} $ps

    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 IIC_0
    connect_bd_intf_net [get_bd_intf_ports IIC_0] [get_bd_intf_pins processing_system7_0/IIC_0]
    create_bd_port -dir I -type clk -freq_hz 125000000 clk125
    foreach port {i2s_sclk i2s_ws i2s_sd ac_mute_n} {
        create_bd_port -dir O $port
    }
    create_bd_port -dir O -from 3 -to 0 led
    create_bd_port -dir I sw0
    create_bd_port -dir O -type clk -freq_hz 12288002 ac_mclk

    set core [create_bd_cell -type module -reference opna_zybo_system opna]
    connect_bd_net [get_bd_ports sw0] [get_bd_pins opna/sw0]
    set control [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 control_axi]
    set_property CONFIG.NUM_MI {1} $control
    set ddr [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 ddr_axi]
    set_property -dict [list CONFIG.SI_PROTOCOL {AXI4} CONFIG.MI_PROTOCOL {AXI3} CONFIG.DATA_WIDTH {64} CONFIG.ID_WIDTH {6}] $ddr

    set audio [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 audio_clock]
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ {125} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {12.288} \
        CONFIG.OVERRIDE_MMCM {true} \
        CONFIG.MMCM_DIVCLK_DIVIDE {8} \
        CONFIG.MMCM_CLKFBOUT_MULT_F {39.125} \
        CONFIG.MMCM_CLKOUT0_DIVIDE_F {49.750} \
        CONFIG.RESET_PORT {resetn} \
        CONFIG.RESET_TYPE {ACTIVE_LOW} \
        CONFIG.USE_RESET {true} \
        CONFIG.USE_LOCKED {true} \
    ] $audio
    set sys_reset [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 sys_reset]
    set audio_reset [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 audio_reset]
    set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $one
    set zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 zero]
    set_property -dict [list CONFIG.CONST_WIDTH {15} CONFIG.CONST_VAL {0}] $zero
    set interrupt [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 interrupt]
    set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {1} CONFIG.IN1_WIDTH {15}] $interrupt

    connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins control_axi/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins control_axi/M00_AXI] [get_bd_intf_pins opna/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins opna/M_AXI] [get_bd_intf_pins ddr_axi/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins ddr_axi/M_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
        [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
        [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK] \
        [get_bd_pins control_axi/ACLK] [get_bd_pins control_axi/S00_ACLK] [get_bd_pins control_axi/M00_ACLK] \
        [get_bd_pins ddr_axi/aclk] [get_bd_pins opna/sys_clk] [get_bd_pins sys_reset/slowest_sync_clk]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
        [get_bd_pins sys_reset/ext_reset_in] [get_bd_pins audio_reset/ext_reset_in] [get_bd_pins audio_clock/resetn]
    connect_bd_net [get_bd_pins one/dout] [get_bd_pins sys_reset/dcm_locked]
    connect_bd_net [get_bd_pins sys_reset/peripheral_aresetn] \
        [get_bd_pins opna/sys_resetn] [get_bd_pins control_axi/ARESETN] \
        [get_bd_pins control_axi/S00_ARESETN] [get_bd_pins control_axi/M00_ARESETN] [get_bd_pins ddr_axi/aresetn]
    connect_bd_net [get_bd_ports clk125] [get_bd_pins audio_clock/clk_in1]
    connect_bd_net [get_bd_pins audio_clock/clk_out1] [get_bd_pins audio_reset/slowest_sync_clk] \
        [get_bd_pins opna/audio_clk] [get_bd_ports ac_mclk]
    connect_bd_net [get_bd_pins audio_clock/locked] [get_bd_pins audio_reset/dcm_locked]
    connect_bd_net [get_bd_pins audio_reset/peripheral_aresetn] [get_bd_pins opna/audio_resetn]
    foreach port {i2s_sclk i2s_ws i2s_sd ac_mute_n led} {
        connect_bd_net [get_bd_ports $port] [get_bd_pins opna/$port]
    }
    connect_bd_net [get_bd_pins opna/irq] [get_bd_pins interrupt/In0]
    connect_bd_net [get_bd_pins zero/dout] [get_bd_pins interrupt/In1]
    connect_bd_net [get_bd_pins interrupt/dout] [get_bd_pins processing_system7_0/IRQ_F2P]

    assign_bd_address
    assign_bd_address -offset 0x43C00000 -range 0x00001000 \
        -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
        [get_bd_addr_segs opna/S_AXI/reg0] -force
    validate_bd_design
    save_bd_design
    set actual_codec_mhz [expr {125.0 * [get_property CONFIG.MMCM_CLKFBOUT_MULT_F $audio] / \
        [get_property CONFIG.MMCM_DIVCLK_DIVIDE $audio] / [get_property CONFIG.MMCM_CLKOUT0_DIVIDE_F $audio]}]
    puts "OPNA_CODEC_CLOCK_MHZ=$actual_codec_mhz"
}
