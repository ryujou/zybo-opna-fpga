# Phase 6：数字总验收

## 步骤门控

| 步骤 | 状态 | 证据 |
| --- | --- | --- |
| A | 通过 | [检查结果](../../build/opna_sim/phase-06/gate-A.json) |
| B | 通过 | [检查结果](../../build/opna_sim/phase-06/gate-B.json) |
| C | 通过 | [检查结果](../../build/opna_sim/phase-06/gate-C.json) |
| D | 通过 | [检查结果](../../build/opna_sim/phase-06/gate-D.json) |

## 行为与依据

验收范围为architecture.md定义的YM2608B完整数字播放路径。数据手册是行为依据；固定LLE提供原生半周期时序和数字运算预期，ymfm提供独立功能及音乐长流交叉检查。录音编码、模拟电气特性、PC-98总线和实板验证不属于本阶段。

MIX检查FM、六种节奏和ADPCM-B的混合、符号扩展、截断、饱和与声道；三路SSG保留独立数字门控与音量码。RUN检查固定种子合法寄存器事件、运行中复位、真实音乐及样本输入，以及持续运行的数字值和时刻。

统一8 MHz主时钟，每tick为62.5 ns半周期；输入在边沿计算前生效，tick 3456起完整验收。half_ce暂停时系统时钟继续运行，芯片tick及状态保持。原始PCM、SSG码、读返回、IRQ/busy、存储引脚及数据、ADPCM状态和混音观察都完整逐值、逐tick比较，不调整时间偏移、增益或误差容限。

## 必需用例

功能清单BUS、CLK、TIM、FM、EG、MOD、SCH、SSG、RHY、ADP、STA由本轮重新执行Phase 1～5全部门控提供证据；MIX与RUN由本阶段正式用例、暂停用例及独立功能断言提供证据。每项必须对应可读取的结果文件，缺失、未知或未执行不得通过。

| 类别 | 用例 | 数量 |
| --- | --- | ---: |
| 混音、声道、正负饱和及分离音源 | mix_pan_00/40/80/c0、mix_clipping、mix_split_sources | 6 |
| 固定种子合法事件及SSG读回 | run_seed_2608、run_seed_cafe | 2 |
| 串行输出、定时器/IRQ及存储运行中复位 | run_reset_serial_even/odd、run_reset_timer_irq、run_reset_memory | 4 |
| 真实音乐首秒及ADPCM样本 | run_music_counterattack | 1 |
| 持续运行、周期动作及无漂移 | run_long_drift | 1 |

14个正式用例都执行正常和每tick插入三个half_ce=0系统周期的暂停重放。固定种子用例各含192次动作；复位后独立检查状态清零、SSG复位码、重新发声及样本载荷读回。

真实音乐使用Furnace官方示例[《Counterattack》](https://github.com/tildearrow/furnace/blob/v0.6.8.3/demos/pc98/Counterattack.fur)，作者MelonadeM；[示例歌曲权利说明](https://github.com/tildearrow/furnace/blob/v0.6.8.3/demos/README.md)保留原作者全部权利。原曲、官方导出的VGM和来源记录位于tools/opna_sim/fixtures/counterattack。输入保留寄存器值、写入顺序及真实ADPCM样本，将VGM时间展开到本项目8 MHz半周期并按手册写入等待序列化；同采样时刻的密集写入因此可能延后，具体数量与延迟写入参考契约文件。

固定种子事件遵守寄存器及写入等待要求，节奏键寄存器0x10写后等待至少576主时钟周期。SSG-EG启用时AR低五位固定为0x1F，KS高位仍可变化，依据[日文原始应用手册第31页](https://raw.githubusercontent.com/grobique/minimal_OPNA_player/master/YM2608J.pdf)。门控独立解码每个算子在两个端口上的写入，检查该条件和复位后重新设置的顺序。长程用例的持续窗口为1600万tick，即1秒；完整比较所有样本及原生tick，并核对样本数、顺序和末端状态。

音乐首秒保留887次真实寄存器写入，并载入原作九个ADPCM样本的34560字节样本库，包含FM、节奏音和ADPCM播放。该原作片段关闭SSG音调及噪声，三路原生固定静音码为1，ymfm的SSG音频为0；这两种输出分别按自身格式独立断言。四音源同时活动由混音与长程用例覆盖。

## 参考模型差异的裁决

ymfm的采样率和输出格式不作为原生tick真值；其明确的功能差异必须有独立预期，不通过过滤输出或放宽比较解决。ZERO持续静音计数采用Phase 5的数据手册修正，固定上游源码保持原样。

SCH继续采用用户确认的SCH-LLE-2026-10-07工程契约：六通道持续运算，SCH改变最后锁存key的译码目标。该契约没有实片验证；数字总验收通过也不能将此模型推断表述为已证明的YM2608B实片事实。

## 实现与证据

入口为`.\scripts\run_opna_gate.ps1 -Phase 6 -Step D`，顺序执行Phase 1～5当前累计回归，再执行Phase 6 A→B→C→D，任一步失败即停止。证据目录为build/opna_sim/phase-06。

XSim用例采用独立运行目录并发执行，同阶段只编译一次，每个用例将对应快照复制到自己的运行目录。每个用例保留独立输入、输出和日志，完成标记及严格比较仍逐项必需。混音观察在本阶段显式打开，保留18位有符号DAC加载值和各声音源的原生数字值。

默认并发数为8，可通过OPNA_SIM_WORKERS调整。同八个完整短用例的[实测](../../build/opna_sim/parallel-bench-_2ojntxx/benchmark.json)为串行82.98秒、四路26.50秒、八路14.48秒；八路约提速5.73倍，输出字节、完整参考比较和仿真结束标记全部一致。该结果适用于这组短用例，长时单例仍有连续运行耗时。

混音饱和用例在默认分频下逐次检查DAC加载值：110 tick后同声道的公开PCM必须等于其有符号16位饱和值，并实际跨越正负两端边界。ADPCM输出的低两位必须为0；分离音源用例检查左侧节奏贡献恒为0。SSG保持独立数字输出，不并入FM串行PCM。

FM包络输出使用同算子的原始电平、key与旧SSG-EG方向，在原生输出抽头采样当前EN/ATT后倒相，再加入TL/AM并饱和。方向更新按ALT/HOLD和溢出条件反馈到该算子的下一轮；key-off从尚未加入TL/AM的实际包络电平释放。包络速率使用与原生计时器对齐的历史keycode，运行中修改频率仍保留其取样时刻。

## 当前结论

Phase 6数字逻辑仿真验收通过。本轮Phase 1～5累计门控全部通过，Phase 6 A～D分别完成35、50、64、66项检查。14个正常用例与14个暂停用例共15,296,856条原始观察的数字值及tick完整一致。

[总门控结果](../../build/opna_sim/phase-06/gate-D.json)及[功能证据清单](../../build/opna_sim/phase-06/feature-coverage.json)覆盖13项数字功能。SCH仍采用已确认的工程契约，实片边界尚未核验。Phase 7完整核心独立容量检查通过，整板综合18734/17600 LUT超出器件容量，已按容量门停止；未进行布局布线或实板验证。
