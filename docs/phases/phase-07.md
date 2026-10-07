# Phase 7：XC7Z010 与板级离线检查

## 验收范围

本次工作包括完整数字核心的 XC7Z010 综合与容量检查，以及容量满足后的 PS、DDR 样本供数、缓冲、立体声采样、I2S、codec 配置、软件编译、布局布线与时序检查。不执行烧录和实板测试；整体板级验收仍需实板证据。

代码公开于 [zybo-opna-fpga](https://github.com/ryujou/zybo-opna-fpga)，保留上游许可。ROM 与音乐数据由本地准备脚本生成或获取，不随公开仓库分发。

## 容量门

目标为 `xc7z010clg400-1`：17,600 LUT、35,200 FF、60 个 36 Kb BRAM、80 DSP。独立综合保持 FM、SSG、六种节奏音、ADPCM-B、控制状态及外部样本存储接口，资源结果来自当前 `ym2608`，不使用旧 FM 包装器的报告。

任一资源超过器件容量即停止后续布线和板级集成，记录实际超限项。容量满足仅允许继续离线集成，不代表时序或板测通过。

## 步骤门控

| 步骤 | 状态 | 证据 |
| --- | --- | --- |
| A | 通过 | [检查结果](../../verification/phase-07/gate-A.json) |
| B | 通过 | [板级定向仿真](../../verification/phase-07/board-tests/result.json) |
| C | 未通过 | [整板容量超限](../../verification/phase-07/board/capacity-stop.json) |
| D | 未通过 | 离线必需项未完成，容量门停止 |

## 实现与证据

综合入口为 `hardware/vivado/phase7_core_probe.tcl`。节奏 ROM 使用 packed 字节数组直接索引，保持全部 8192 字节及组合读出时序；完整地址和 X/Z 地址仿真比较均一致。

Vivado 2025.2、`RuntimeOptimized`、`flatten_hierarchy none` 的完整核心报告为 6096/17600 LUT、5776/35200 FF、1/60 BRAM、0/80 DSP，全部满足器件容量。层次报告保留控制、FM 运算及外部样本接口，无黑盒。资源证据为 [utilization.rpt](../../verification/phase-07/core-probe/utilization.rpt) 和 [层次报告](../../verification/phase-07/core-probe/utilization-hierarchical.rpt)。

整板入口为 `hardware/vivado/phase7_board.tcl`，顶层为 `opna_cpu_wrapper`。PS GP0 接入原生四字节端口、IC、RUN 和状态；HP0 供给完整 256 KiB ROM/RAM8/RAM1 样本空间。100 MHz 系统时钟每 25 周期产生 4 次芯片半周期使能；正常供数保持连续芯片时钟，DDR 错误置位、停止芯片、静音并触发 IRQ。音频完整左右帧保持转换至标称 48 kHz、16 位 I2S；codec 配置依据 SSM2603 Rev. D。

板级定向仿真完成 6 项检查，实际原生核心的 31,571 次供数数据及 tick 一致，覆盖 72 次内存写、11 次循环、24 次跨行、13 个暂停位置及 13 条故障路径。ROM/RAM8/RAM1 的全空间 CPU 读写、RUN 交接、独立 AXI 通道和音频复位均包含在验收中。结果见 [板级测试](../../verification/phase-07/board-tests/result.json)。

完整整板合并综合资源如下，报告状态为 `Synthesized`，包含原生核心、DDR 缓存、主机、音频及 PS/AXI IP。

| 资源 | 使用 | 容量 | 结论 |
| --- | ---: | ---: | --- |
| LUT | 18,734 | 17,600 | 超出 1,134，106.44% |
| FF | 24,409 | 35,200 | 容量内 |
| BRAM | 1 | 60 | 容量内 |
| DSP | 0 | 80 | 容量内 |

证据为 [综合资源报告](../../verification/phase-07/board/utilization-synth.rpt)、[整板层次报告](../../verification/phase-07/board/utilization-synth-hierarchical.rpt) 和 [容量停止记录](../../verification/phase-07/board/capacity-stop.json)。层次中 DDR 样本缓存占 11,494 LUT、17,103 FF；整板内核心占 5,950 LUT、5,833 FF。这些是综合结果，未进行物理优化或布线。

综合还报告异步时钟组约束中的 `clk_fpga_0` 未匹配，时钟约束尚未完成验收。容量超限后保持停止，该提示不作为已通过时序或 CDC 的证据。

PS 软件已基于无 bit 的准备 XSA 生成真实 Cortex-A9 BSP 并编译链接，15 项构建及主机执行检查通过，ELF 为 419,572 字节，全部分配段位于样本 DDR 基址 `0x01000000` 以下。实际原曲第一秒的 887 次寄存器写和 34,560 字节样本通过主机协议比较。证据见 [准备软件结果](../../verification/phase-07/board/software-prepare/result.json)。该结果不属于最终含 bit XSA 的软件验收，也不证明 USB 枚举、DDR 训练或模拟音频输出。

离线门控命令为 `.\scripts\run_opna_gate.ps1 -Phase 7 -Step D -Offline`，要求此前 Phase 1–6 的新鲜累计回归、板级定向验证、完整工程容量与布线时序、bit/XSA 和基于最终 XSA 的软件构建全部满足。本次累计回归在整板容量超限后停止，未取得 Phase 7 C/D 通过结果。所有证据保持 `board_verified=false` 和 `phase7_full_acceptance=false`。

## 当前结论

Phase 7 已因完整整板 LUT 超出 XC7Z010 容量停止，离线验收未通过。核心容量、板级定向仿真及准备软件构建有通过证据；布局布线、setup/hold、DRC/CDC、最终 bit/XSA/ELF 和实板验收未完成。
