# Zybo OPNA USB MIDI firmware

Windows 枚举名称为 **Zybo OPNA MIDI**，VID/PID 为 `CAFE:4014`，USB MIDI 1.0 类设备，使用 Microsoft `usbaudio`。EP1 OUT 接收 4 字节 USB MIDI 事件。中断只收包；主循环执行 MIDI 控制及 FPGA 寄存器写入。

固件使用固定 libOPNMIDI、`xg.wopn` 音色库与单颗 OPNA 的六个 FM 声部。旋律和 MIDI 打击乐共用这六个声部，库负责分配与替换。`fpga_chip.h` 写入实际 MMIO 后端，并设置 OPNA SCH；构建脚本按板卡的 8 MHz 原生时钟校准库的 7.9872 MHz 音高模型。没有软件模拟音频生成或 USB PCM 音频接口。

## SW0 双模式

`--dual-mode` 构建同一固件中的两种 USB 模式。SW0 关闭（0）为 **Zybo OPNA MIDI**（`CAFE:4014`）；开启（1）为 **Zybo PC98 OPNA**（`CAFE:4012`、WinUSB bulk），由电脑发送 YM2608 原始寄存器事件和 ADPCM 样本。切换先停音，再断开并重新枚举；拨码消抖为 50 ms，Windows 枚举另需数秒，Python 播放器自动显示枚举后的设备状态。

原声模式接受单颗 YM2608、7.9872/8 MHz 的 `.vgm`/`.vgz`，按文件顺序播放一次；支持 FM、SSG、固定节奏及初始 ADPCM RAM 数据块，曲目寄存器事件须在 8 MiB 内。Python GUI 直接读取东方旧作 PMD（`.m`、`.m2`、`.m26`、`.m86`），后台通过固定版本 98fmplayer 驱动解码，播放到首轮循环结束；用户无需转换文件。当前不支持带外部 PPC/PPS/PPZ 样本的 PMD。7.9872 MHz 文件在当前 8 MHz 硬件上有约 0.16% 音高差。

从项目根目录构建：

```powershell
& "$env:OPNA_VIVADO_ROOT/bin/vivado.bat" -mode batch `
  -source hardware/vivado/phase7_board.tcl `
  -tclargs J:/lumia/FPGA/PC98/build/usb_dual/board
python scripts/build_phase7_ps.py `
  --xsa build/usb_dual/board/zybo_opna.xsa --out build/usb_dual/board/software
python software/usb_midi/build.py --dual-mode --boot --board build/usb_dual/board
```

输出为 `build/usb_dual/opna_usb_dual.elf` 和 `BOOT.bin`。硬件必须含 SW0 输入及 `0x43C00020` 拨码状态寄存器；签名为 `0x53570000`，bit 0 为同步后的 SW0 电平。默认 `--boot` 构建仍输出原单模式 MIDI 固件。

JTAG 加载双模式固件：

```powershell
& "$env:XILINX_VITIS/bin/xsct.bat" scripts/phase7_jtag.tcl `
  build/usb_dual/board/zybo_opna.xsa build/usb_dual/board/zybo_opna.bit `
  build/usb_dual/opna_usb_dual.elf build/usb_dual/board/software/ps7_init.tcl
```

Python GUI 自动列出本地《东方幻想乡》《东方怪绮谈》51 首原曲；也可用“打开曲目”选择文件。启动：

```powershell
python tools/build_pmd_decoder.py
python tools/pc98_player.py `
  --libusb 'J:/lumia/FPGA/OPL3/opl3_host/.venv/Lib/site-packages/libusb/_platform/windows/x86_64/libusb-1.0.dll'
```

本机可直接运行 `build/pc98_player/dist/PC98Player/PC98Player.exe`，曲库放在旁边的 `music/`。命令行播放器为 `tools/play_pc98.py <原曲文件>`，支持 `--seconds 25` 和 `Ctrl+C`。libusb 在系统搜索路径中时可省略 `--libusb`；Python 依赖为项目已有的 PyUSB。SW0 关闭后可在 Cynthia 等 MIDI 播放器中选择 **Zybo OPNA MIDI**。

## 构建

先按 [硬件说明](../../hardware/vivado/README.md)生成 `build/opna_phase7/board/zybo_opna.xsa`、`.bit`、`.ltx`，再执行：

```powershell
python scripts/build_phase7_ps.py
python software/usb_midi/build.py --test
python software/usb_midi/build.py --boot
```

`build_phase7_ps.py` 为匹配的 XSA 生成实际 BSP。MIDI 编译使用同一 BSP、codec、原生写入和计时器源文件；4 MiB 堆、64 KiB 主栈与其余应用均位于 `0x01000000` 以下，避开样本 DDR。`--boot` 为同一 XSA 生成并编译 FSBL，再由 bootgen 打包。

工具默认 `J:/FPGA/2025.2/Vitis`，可用 `XILINX_VITIS` 指定；主机测试使用 Vivado 随附的 MinGW。可用 `--board <目录>` 选择另一份匹配的 bit/XSA/BSP 输出。上游库保持原样，FPGA 后端替换只写入 `build/usb_midi/opnmidi_opn2.cpp`。

## JTAG 加载

J9 接 Windows、JP1 断开；J11 接调试口。以默认构建目录为例：

```powershell
& "$env:XILINX_VITIS/bin/xsct.bat" scripts/phase7_jtag.tcl `
  build/opna_phase7/board/zybo_opna.xsa `
  build/opna_phase7/board/zybo_opna.bit `
  build/usb_midi/opna_usb_midi.elf `
  build/opna_phase7/board/software/ps7_init.tcl
python software/usb_midi/hardware_test.py --list
```

成功下载显示 `PHASE7_JTAG_STARTED`，稍候 Windows 完成枚举。在 Cynthia 选择 **Zybo OPNA MIDI**，打开 MIDI 并播放。声音从 J5 耳机口输出。USB 只传演奏事件。

## 检查

```powershell
python software/usb_midi/hardware_test.py --seconds 60
& "$env:XILINX_VITIS/bin/xsct.bat" software/usb_midi/hardware_stats.tcl
```

`--midi <文件.mid>` 可通过 Windows WinMM 定时发送整首曲目，需要 `mido`。Cynthia 测试直接使用播放器自身的文件读取和 MIDI 输出。

本机已经通过 USB 到 I2S 的左声道、右声道、双声道及复位静音检查，以及 Cynthia 播放时的实际非零音频捕获。`--ila` 使用实测硬件目录 `build/opna_phase7/pipeline-board` 的 LTX，并保存原始捕获及 JSON；重新构建时应使用与板上配置匹配的 LTX。双声道输出使用原生核心错时产生的左右样本，不把左右数值逐帧相等作为硬件条件。

验证记录位于 [verification/usb-midi](../../verification/usb-midi/)。独立 SD 冷启动及模拟音频测量尚未完成。
