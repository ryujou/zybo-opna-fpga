# YM2608 工作总结

日期：2026-10-08  
工程：`zybo-opna-fpga`

## 当前结论

**Phase 1～6的A～D门控全部通过，数字逻辑仿真验收完成。** Phase 6完成14个正式用例与14个时钟暂停用例，共15,296,856条原始观察的数字值及tick与项目参考完整一致，D通过66项检查。结果见[Phase 6](phases/phase-06.md)，当前状态见[progress.md](progress.md)。

当前实现包含六通道FM、三通道SSG、六种节奏音及ADPCM-B播放和样本内存访问。完整核心XC7Z010独立综合为6096 LUT、5776 FF、1 BRAM、0 DSP。Phase 7整板综合为18734/17600 LUT，超出1134，已按容量门停止；板级定向仿真及准备软件构建通过，布局布线、时序/CDC和最终bit/XSA未完成。结果见[Phase 7](phases/phase-07.md)。源码已公开于[zybo-opna-fpga](https://github.com/ryujou/zybo-opna-fpga)。

## 技术路线与范围

| 项目 | 约定 |
| --- | --- |
| 芯片与时钟 | YM2608B / OPNA，默认8 MHz；每tick为主时钟半周期62.5 ns |
| RTL基础 | JT12/JT10B六通道适配与JT49；节奏音、Delta-T按YM2608原生扫描及运算适配 |
| 参考 | 手册优先；固定ymfm作功能交叉检查，YM2608-LLE项目参考作关键时序与原生数字输出严格对照 |
| 验证 | SystemVerilog定向testbench、Vivado 2025.2 XSim、Python比较器、PowerShell门控 |
| PS / PL | PS准备事件和传输；PL负责芯片寄存器、定时、波形运算与音频输出 |
| 比较规则 | 原始PCM与有效tick完整比较，不平移、不调增益、不放宽容差 |
| 数字逻辑完成点 | Phase 6；资源与板测属于Phase 7 |

采用用户确认的JT12适配路线，依据LLE修正运算和时序。LLE是电脑上运行的C语言低层参考模型；本工程保留JT12的相位环、包络反馈、调制运算及波形查表，并将所需原生扫描与运算写入RTL。

范围包含FM、SSG、六种节奏音、ADPCM-B播放与样本内存读写、定时器、IRQ、busy和状态。不含录音编码、模拟电气特性、PC-98总线/BIOS、独立86 PCM和未定义测试模式。固定版本见[sources.json](../tools/opna_sim/sources.json)，范围见[architecture.md](architecture.md)。

## 当前实现

- 控制逻辑保持真实引脚读写、寄存器掩码、分频副作用、Timer A/B、busy、IRQ与复位时刻；ADPCM标志和CPU读数据由其原生扫描模块产生。
- FM寄存器扫描使用原生两相时钟。普通/特殊频率各自共享高位锁存，低位写入提交；DT/MUL保存于两个12槽寄存器环。
- PG参数锁存、DT表、PM符号扩展与乘法按LLE时序计算；相位增量提前十二算子槽传入JT12累加级。IC保留相位环，相位由Key/包络事件清零。
- B0调制连接使用前一扫描锁存，反馈使用当前锁存，载波与声道使能使用原生FSM及B0/B4抽头。OP2使用当前OP1输出；算法5的OP3使用保存的OP1输出。
- AR/DR/SR/SL/RR/KS/SSG参数按24算子扫描提交。TL与AM enable拥有独立原生抽头，在算子衰减输出级加入TL和AM并饱和。
- 包络速率使用原生取样后与计时器对齐的历史keycode；运行中频率写入保持包络的取样时刻。
- SSG-EG使用独立方向反馈，在原生输出抽头按当前EN/ATT倒相后加入TL/AM；保持及释放状态执行静音钳位，Key-off从尚未加入TL/AM的实际电平释放。SSG-EG属于FM包络，不等同于Phase 4的三通道SSG。
- SSG独立分频及C/B/A/包络计数环按原生两相推进，支持全部16种包络、零周期、重触发和噪声门控，输出三路5位数字码。
- 六种节奏音使用固定8192字节ROM及原生六通道解码、音量和声道扫描；ADPCM-B执行Delta-T播放、插值、音量和外部存储控制，支持CPU供数及ROM/8位/1位DRAM访问。
- ZERO数字激励经ADC与外部串行DAC反馈路径进入静音检测，计数按手册契约执行；EOS/BRDY/ZERO接入原生状态锁存、IRQ与清除逻辑。
- FM分频切换保留重复及重叠相位、查表透明锁存，并保持默认分频的复位采样时刻。
- 原生18位左右累加、符号扩展、截断、串行移位和DAC接收保持原始输出时刻，包括复位中断串行字的行为。

代码：[ym2608.sv](../hardware/rtl/opna_core/ym2608.sv)、[ym2608_control.sv](../hardware/rtl/opna_core/ym2608_control.sv)、[SSG适配](../hardware/rtl/opna_core/jt49_opna.sv)、[节奏音适配](../hardware/rtl/opna_core/jt10_opna_rhythm.sv)、[ADPCM适配](../hardware/rtl/opna_core/jt10_opna_adpcm.sv)、[JT12适配目录](../hardware/rtl/opna_core/jt12_opna)、[门控](../tools/opna_sim/gate.py)、[FM用例](../tools/opna_sim/fm_cases.py)、[SSG用例](../tools/opna_sim/ssg_cases.py)、[节奏音/ADPCM用例](../tools/opna_sim/adpcm_cases.py)、[总验收用例](../tools/opna_sim/acceptance_cases.py)、[并发仿真](../tools/opna_sim/parallel.py)。固定上游源码保持原样。

## FM验证范围

| 类别 | 用例 | 数量 |
| --- | --- | ---: |
| 静音与声道 | silence、pan_left/right/stereo | 4 |
| 算法与反馈 | algorithm_0～algorithm_7、algorithms_feedback | 9 |
| 六通道与独立算子 | six_channels_slots、key_operator_isolation | 2 |
| 频率 | frequency_detune_multiplier、frequency_latch | 2 |
| 包络与SSG-EG | envelope_boundaries、attack_rounding、sustain_level_change、decay_granularity、ssg_eg_shapes | 5 |
| 调制与特殊模式 | lfo_am_pm、channel3_special、csm_timer_a | 3 |
| 动态写入 | dynamic_writes_keys | 1 |
| SCH与通道模式 | three_six_channel_switch及四组SCH用例 | 5 |
| 运行中复位 | fm_reset_active及11个附加相位 | 12 |

代表性完整观察：[算法/反馈4221条](../verification/phase-03/compare-algorithms_feedback.json)、[DT/MUL 3617条](../verification/phase-03/compare-frequency_detune_multiplier.json)、[包络8142条](../verification/phase-03/compare-envelope_boundaries.json)、[SSG-EG 3508条](../verification/phase-03/compare-ssg_eg_shapes.json)、[AM/PM 6497条](../verification/phase-03/compare-lfo_am_pm.json)、[动态写入1437条](../verification/phase-03/compare-dynamic_writes_keys.json)。观察数包含控制记录。

C累计重跑前两阶段及全部FM用例，并对六通道、AM/PM、动态写入和复位相位011插入每tick三个half_ce=0的系统周期，全部样本与芯片tick保持一致。D已核对清单、比较结果、观察数量、仿真结束标记和文档。

## SSG验证范围

37个正式用例覆盖三通道音调、全部64种混合使能、噪声、16种包络、零周期、周期65535、同形状重触发16种相位、读回、分频和运行中复位。十个FM+SSG用例包含六通道并行和全部八种算法在反馈等级5下的分频切换。最长周期用例运行10031360 tick，71798条观察完整一致：[比较结果](../verification/phase-04/compare-ssg_envelope_periods.json)。

三路SSG保留门控后的5位数字音量码，固定音量为2×寄存器低四位+1；数字码0与1分别保留。FM串行PCM单独比较。四个时钟暂停用例保持数字值与芯片tick一致，完整验收范围见[Phase 4](phases/phase-04.md)。

## 参考与验证边界

SCH采用已确认的SCH-LLE-2026-10-07工程契约：六通道持续计算，SCH参与key通道选择，最后一次28写入随扫描和SCH持续译码。四个边界用例严格通过，ymfm的已知差异有独立断言。[来源与对照](phases/phase-03.md#sch工程契约)。

目前没有可用的YM2608B原片或PC-98声卡，未完成该SCH边界的独立实片核验。LLE模型一致性不能表述为已实测证明原片行为；数字验收不解除这一实片核验限制。SSG已通过Phase 4，节奏音及ADPCM-B已通过Phase 5；板级集成与实板验证属于Phase 7。

Phase 5按用户确认的数据手册契约修正ZERO：持续静音约290 ms后置位，非静音复位计数。固定LLE的原始计数极性与手册相反；修正在项目生成的参考编译单元和RTL内，固定上游源码保持原样。48个参考及RTL用例覆盖节奏ROM、ADPCM播放及存储访问、末端、限制、bank和五种ZERO激励，五个时钟暂停用例及此前累计回归全部通过。ZERO经SAMPLE模式的ADC共享静音检测与计数链验证，静音及声音中断后的重新计时分别约292.15 ms、291.89 ms。状态和参考差异见[Phase 5](phases/phase-05.md)。

## 恢复入口

```powershell
.\scripts\run_opna_gate.ps1 -Phase 6 -Step D
```

该命令顺序重新执行Phase 1～5累计回归及Phase 6 A～D，同阶段独立XSim用例默认八路并发，完整比较规则保持一致。状态见[progress.md](progress.md)，阶段规则见[todo.md](todo.md)，总验收范围与证据见[Phase 6](phases/phase-06.md)。
