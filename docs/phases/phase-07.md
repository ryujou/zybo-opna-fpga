# Phase 7：XC7Z010 与板级验收

## 验收范围

完整 YM2608 数字核心、PS/DDR、音频及两组 ILA 已满足 XC7Z010clg400-1 容量和布线时序。Zybo 数字板测已通过，板卡当前运行正常 USB 播放固件。

## 容量门

目标器件资源上限为 17600 LUT、35200 FF、60 BRAM、80 DSP。完整工程含双 ILA，容量、setup/hold/pulse、DRC 和 CDC 满足后才输出 bit/XSA/LTX。

## 步骤门控

| 步骤 | 状态 | 证据 |
| --- | --- | --- |
| A | 通过 | [检查结果](../../build/opna_sim/phase-07/gate-A.json) |
| B | 通过 | [检查结果](../../build/opna_sim/phase-07/gate-B.json) |
| C | 通过 | [检查结果](../../build/opna_sim/phase-07/gate-C.json) |
| D | 通过 | [检查结果](../../build/opna_sim/phase-07/gate-D.json) |

## 实现与证据

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 含双 ILA 的整板实现 | LUT 11576、FF 12343、BRAM 38.5、DSP 0 | [实现报告](../../build/opna_phase7/pipeline-board/result.json) |
| 布线时序 | WNS +0.262 ns、TNS 0、WHS +0.051 ns，setup/hold/pulse 违例均为 0 | [时序](../../build/opna_phase7/pipeline-board/timing-summary.rpt) |
| DRC / CDC | Error、Critical Warning、CDC Critical 均为 0 | [DRC](../../build/opna_phase7/pipeline-board/drc.rpt)、[CDC](../../build/opna_phase7/pipeline-board/cdc.rpt) |
| 板级定向仿真 | 六项通过，32,202 次供数比较、74 次内存写；正常供数无时钟伸缩 | [仿真结果](../../build/opna_phase7/timing-pipeline-verified/result.json) |
| 最终 XSA / PS | 含 bit 的 XSA、真实 BSP 编译与 15 项检查通过 | [软件结果](../../build/opna_phase7/pipeline-board/software/result.json) |
| 原生 ILA | SSG、FM、鼓音、ROM、RAM8、RAM1 及两组 RAM 原生写入，共 65,536 半周期 × 74 位，零差异 | [ILA 结果](../../build/opna_phase7/pipeline-board/hardware/ila-result.json) |
| 样本引脚 / I2S | 336 次独立样本核对一致；24,576 音频时钟位序、帧边界与握手通过 | [实板汇总](../../build/opna_phase7/pipeline-board/hardware-result.json) |
| USB / 实际 DDR | 全 256 KiB 回读、887 次音乐写、暂停/恢复/完成通过 | [USB 结果](../../build/opna_phase7/pipeline-board/usb-result.json) |

Phase 1–7 A–D 的本轮累计离线门控已全部通过，见 [最终门控](../../build/opna_sim/phase-07/gate-D.json)。从源码完整重建复现了相同的资源与时序结果，最终 XSA 的 PS 软件 15 项检查通过。结合实际板测，数字板级验收汇总为 `board_verified=true`、`phase7_full_acceptance=true`。离线报告自身仍保持 `board_verified=false` 和 `phase7_full_acceptance=false`，以区分证据来源。

## 实现约束

系统时钟 100 MHz，每 25 SYS 产生 4 次原生半周期使能，对应 8 MHz 芯片。FM 六通道、SSG 三通道、六种节奏音、ADPCM-B 及完整 256 KiB ROM/RAM8/RAM1 空间保留。DDR 缓存为 2 KiB，RAM1 使用八个 32 KiB 位银行。

DDR 地址查找、RAM 索引及写入提交分级处理。正常读取最短原生供数预算为 30 SYS，预取领先量为 75 SYS；RAM1 写入在 AXI 等待阶段准备下一银行地址，复位等待已发出事务排空，最大验证等待为 219 SYS。DDR 故障停止芯片、静音并触发 IRQ。

原生 6-cycle setup / 5-cycle hold 仅作用于逐针证明在间隔内不捕获的目标。物理优化复制的 half_ce LUT 必须具有完全相同的类型、INIT 和输入驱动才纳入证明，计数器、RUN、DDR 及其他真实 SYS 路径仍按 10 ns 检查。方法学报告使用 `-merge_exceptions true` 合并有效约束，与 STA 保持一致，TIMING-16 计数为 0。[约束证明](../../build/opna_phase7/pipeline-board/native-mcp-targets.txt)及[篡改副本负向检查](../../build/opna_phase7/replica-proof-test/result.json)。

音频采用完整原生左右帧的最近帧保持，混合固定幅度表的 SSG，分级加法与饱和后经 mailbox 传递到标称 48 kHz、16 位 I2S。独立音频时钟为 12.2880025126 MHz。mailbox 偏斜为 1.035 ns，满足 10 ns 限值；两级同步器及握手协议保持完整。

## 实板比较范围

每组 native 捕获从 FPGA 冷启动的第一个原生边沿开始，深度 8192，逐行重放实际 consumed inputs 到固定 LLE/manual ZERO 参考。全部公开输出 74 位严格比较，不丢弃初始化前缀，不容许时间平移或数值容差。激励检查要求所有预定寄存器写入出现，且 FM、鼓音、三种 ADPCM 具有非零原生 PCM。三种 ADPCM 样本上传期间有一次主动 RUN 暂停，正常推进间隔为 6/7 SYS。

RAM8 原生写入产生 1 次 WE；RAM1 CPU 写入产生 8 次串行 WE，通过 DM0 更新目标字节并透传保留 DM[7:1] 对应位银行。两组均在写入排空后由 PS 核对全部 262,144 字节非零底图，目标更新及其他字节保持均通过。

audio 捕获六组，每组 4096 音频时钟，核对完整帧、I2S 位流、左右槽、填零、phase、request/response 和静音使能。固定 SSG 音量的左右输出均为 17977。FM 仅左声道发声；鼓音音频捕获位于播放结束后的静音段，发声证据来自其原生捕获。比较器的单比特负向检查见 [结果](../../build/opna_phase7/pipeline-board/hardware/comparator-negative/result.json)。

USB 音乐控制测试的最大调度晚启动为 804 μs，887 次写均被计入晚启动诊断，不宣称事件调度零抖动。未测量 codec 模拟输出；未与 YM2608 实片比较，`chip_verified=false`。

## 复现命令

从项目根目录运行。离线入口生成的默认产物目录为 `build/opna_phase7/board`；当前已实测交付位于 `build/opna_phase7/pipeline-board`。

```powershell
.\scripts\run_opna_gate.ps1 -Phase 7 -Step D -Offline
python scripts/build_phase7_ila.py --software build/opna_phase7/pipeline-board/software --out build/opna_phase7/pipeline-board/hardware
python scripts/phase7_ila_run.py --board build/opna_phase7/pipeline-board --oracle build/opna_phase7/pipeline-board/hardware/oracle.exe
& 'J:/FPGA/2025.2/Vitis/bin/xsct.bat' scripts/phase7_jtag.tcl build/opna_phase7/pipeline-board/zybo_opna.xsa build/opna_phase7/pipeline-board/zybo_opna.bit build/opna_phase7/pipeline-board/software/opna_ps.elf build/opna_phase7/pipeline-board/software/ps7_init.tcl
Start-Sleep -Seconds 3 # 等待 USB 重新枚举
python scripts/phase7_usb.py --libusb 'J:/lumia/FPGA/OPL3/opl3_host/pc_player/libusb-1.0.dll' --music --out build/opna_phase7/pipeline-board/usb-result.json
```

ILA 脚本下载测试 ELF，按冷启动条件重配置 FPGA 并通过 JTAG 写入测试触发字；后续下载命令恢复正常 USB ELF。XSCT 下载以 `PHASE7_JTAG_STARTED` 完成标记核验，不只依赖进程退出码。

项目源码入口为 `hardware/vivado/phase7_board.tcl`。公开仓库为 [zybo-opna-fpga](https://github.com/ryujou/zybo-opna-fpga)，当前测试和产物均在本地；ROM、音乐和二进制不随公开源码分发。


## 当前结论

含双 ILA 的整板容量、布线时序、Phase 1–7 累计离线回归及实际数字板测全部通过。Phase 7 数字板级验收完成，板卡运行正常 USB 固件；模拟音频测量与 YM2608 实片对照不在本次完成范围内。
