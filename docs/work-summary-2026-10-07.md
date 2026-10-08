# OPNA 时序与实板验证状态（2026-10-08）

当前板卡已运行 USB MIDI 应用：Windows 枚举 `Zybo OPNA MIDI`，Cynthia 已完整播放三首东方 MIDI。当前交付见 [README](../README.md)和 [USB MIDI 验证](../verification/usb-midi/result.json)；以下保留 Phase 7 数字板级验收依据。

完整 YM2608 数字核心保持冻结。XC7Z010 整板已完成布线时序收敛，并在 Zybo 上通过数字板测。板卡当前运行正常 USB 播放固件，标识为 `0x26080007`，USB 为 `CAFE:4012`。

## 时序与资源

100 MHz SYS 时钟、8 MHz 芯片时钟及全部声音源、256 KiB 样本空间保持原有契约。DDR 地址查找和写入提交采用寄存级隔离，SSG 混音分级完成。原生 6/5 多周期约束逐个证明捕获条件；物理优化产生的使能副本必须具有相同 LUT 类型、真值表和全部输入驱动。

| 项目 | 最终布线结果 |
| --- | ---: |
| WNS / TNS | +0.262 ns / 0 ns |
| 建立时序违例端点 | 0 |
| WHS / 保持违例端点 | +0.051 ns / 0 |
| WPWS / 脉宽违例端点 | +2.000 ns / 0 |
| DRC Error / Critical Warning | 0 |
| CDC Critical | 0 |
| 音频 mailbox 总线偏斜 / 裕量 | 1.035 ns / +8.965 ns |
| 实现 LUT / FF | 11,576 / 12,343 |
| BRAM / DSP | 38.5 / 0 |

含原生与音频两组 ILA，资源满足 XC7Z010clg400-1。证据：[实现结果](../build/opna_phase7/pipeline-board/result.json)、[布线时序](../build/opna_phase7/pipeline-board/timing-summary.rpt)、[CDC](../build/opna_phase7/pipeline-board/cdc.rpt)、[DRC](../build/opna_phase7/pipeline-board/drc.rpt)、[原生约束证明](../build/opna_phase7/pipeline-board/native-mcp-targets.txt)。

## 实板结果

板卡为原 Zybo，JTAG 序列号 `210279540276A`。以下结果来自实际下载和 ILA 采集。

| 检查 | 结果 |
| --- | --- |
| SSG 固定音量、FM、鼓音、ADPCM ROM/RAM8/RAM1 | 八组冷启动捕获（六组声音源、两组原生 RAM 写入），每组 8192 原生半周期；74 位公开输出全部与固定 LLE/manual ZERO 参考相同 |
| 总比较量 | 65,536 原生半周期，4,849,664 位输出，零差异；从首个原生边沿开始，无丢弃前缀或对齐平移 |
| 激励完整性 | 每组预定寄存器写序列全部出现；FM、鼓音及三种 ADPCM 均有实际非零原生输出 |
| DDR 原生供数 | ROM 40 次、RAM8 40 次、RAM1 256 次稳定引脚样本与预置数据精确一致 |
| 芯片推进 | 正常间隔为 6/7 SYS；ADPCM 样本上传期间各有一次明确的 RUN 暂停，之后恢复正常间隔 |
| 原生 RAM 写回 | RAM8 1 次 WE、RAM1 8 次串行 WE；两组均以全空间底图核对全部 262,144 字节，目标字节更新正确，其他字节及位银行保持一致 |
| I2S | 六组共 24,576 音频时钟，位序、左右槽、填零、帧边界、握手及使能检查零差异 |
| SSG 到 I2S | 固定输出左右均为 17977，即帧 `0x46394639` |
| USB / DDR | HELLO 2.1、EP1 bulk、全部 262,144 字节样本空间回读一致 |
| 音乐控制 | Counterattack 第一秒的 887 次写、34,560 字节样本，上传、读回、暂停、恢复和结束均通过 |
| PS 软件 | 最终含 bit XSA 的真实 BSP 编译与 15 项检查通过，ELF 为 419,592 字节 |

音乐调度实测有 887 次晚启动，最大 804 μs；这是 PS 调度测量，不属于 FPGA STA 违例，也不宣称音乐事件零抖动。鼓音原生捕获包含发声，其稍后音频捕获位于播放结束后的静音段。没有测量 codec 模拟输出，也没有 YM2608 实片对照。

证据：[实板汇总](../build/opna_phase7/pipeline-board/hardware-result.json)、[完整 ILA 比较](../build/opna_phase7/pipeline-board/hardware/ila-result.json)、[USB 与 DDR](../build/opna_phase7/pipeline-board/usb-result.json)、[最终 PS 软件](../build/opna_phase7/pipeline-board/software/result.json)、[正常固件下载记录](../build/opna_phase7/pipeline-board/jtag-restore.log)。

## 回归状态

板级六项定向仿真通过：32,202 次供数比较、74 次内存写、19 次循环、24 次跨行、13 个暂停位置，以及 12 组主机复位边界和 10 个原生 RAM 复位位置。正常 ROM/RAM8/RAM1 无时钟伸缩，最小供数预算 30 SYS，预取提前量 75 SYS，最大复位排写等待 219 SYS。[板级仿真证据](../build/opna_phase7/timing-pipeline-verified/result.json)。

`scripts/run_opna_gate.ps1 -Phase 7 -Step D -Offline` 于 2026-10-08 12:23 完成，Phase 1–7 的 A–D 本轮累计门控全部通过。[最终门控](../build/opna_sim/phase-07/gate-D.json)及[独立完整重建](../build/opna_phase7/board/result.json)复现相同资源和时序结果，最终 XSA 的 PS 软件 15 项检查通过。数字板级汇总为 `board_verified=true`、`phase7_full_acceptance=true`；模拟音频未测量，`chip_verified=false`。离线报告仍保留其独立的 `board_verified=false` 标记。

## 当前交付文件

- [FPGA bitstream](../build/opna_phase7/pipeline-board/zybo_opna.bit)
- [含 bit 的 XSA](../build/opna_phase7/pipeline-board/zybo_opna.xsa)
- [ILA 探针 LTX](../build/opna_phase7/pipeline-board/zybo_opna.ltx)
- [正常 USB 播放 ELF](../build/opna_phase7/pipeline-board/software/opna_ps.elf)

这些文件对应已实测的同一整板实现。核心功能边界和 SCH 工程契约见 [Phase 6](phases/phase-06.md)，板级复现步骤见 [Phase 7](phases/phase-07.md)。
