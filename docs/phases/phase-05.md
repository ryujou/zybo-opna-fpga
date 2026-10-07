# Phase 5：节奏音与ADPCM-B

## 步骤门控

| 步骤 | 状态 | 证据 |
| --- | --- | --- |
| A | 通过 | [检查结果](../../verification/phase-05/gate-A.json) |
| B | 通过 | [检查结果](../../verification/phase-05/gate-B.json) |
| C | 通过 | [检查结果](../../verification/phase-05/gate-C.json) |
| D | 通过 | [检查结果](../../verification/phase-05/gate-D.json) |

## 行为与依据

范围遵循todo.md：六种节奏音的固定ROM、停止/重启、总/独立音量和声道；ADPCM-B的速率、起止/限制地址、循环、复位、外部存储及CPU数据访问；EOS/BRDY/ZERO与IRQ、清除和读副作用。FM、SSG、节奏音和ADPCM-B并行及Phase 1～4累计回归必须通过。

JT12为解码运算基础，依据固定YM2608-LLE适配YM2608原生两相扫描、控制和输出锁存。固定版本及许可证沿用sources.json。芯片数据手册是行为依据，项目侧LLE参考提供原生时序预期，ymfm执行独立功能交叉检查。原始PCM、有效tick、存储地址/数据/读写和状态变化完整比较，不改变对齐或容差。

外部样本存储保留在核心外，参考和测试台依据公开存储引脚的RAS/CAS地址锁存、MDEN/ROMCS读窗口与WE写窗口提供数据。ROM和8位DRAM的地址单位为32字节，1位DRAM为32位并含八个芯片bank；CPU读取含两次启动dummy read。[YM2608应用手册第48、53页](https://csclub.uwaterloo.ca/~pbarfuss/YM2608J_Translated.PDF)。

统一轨迹从tick 3456起验收；样本存储在该复位稳定点加载，随后完整保留所有访问和写入。CPU dummy read也保留在逐tick比较中。

## 必需用例

用例必须覆盖六种节奏ROM的实际结束、组合播放、停止/重启、音量和声道；ADPCM-B的ROM、8位/1位DRAM、所有nibble与符号、速率边界、插值、起止/限制及bank边界、循环、运行中复位、CPU供数、CPU存储读写和dummy read；EOS/BRDY/ZERO的有效范围、IRQ使能、掩码、清除与读锁存。每项均需要独立功能预期及RTL完整比较证据。

| 类别 | 用例数 |
| --- | ---: |
| 六种节奏ROM、音量、声道、停止/重启 | 9 |
| ADPCM存储类型与nibble、速率、声道、音量、循环 | 14 |
| CPU存储读写、地址/bank边界、末端、限制及供数 | 13 |
| ADPCM运行中复位与状态掩码 | 5 |
| ZERO静音、非静音、中断、标志及复位 | 5 |
| 四音源并行与分频 | 2 |

48个正式用例之外，五个时钟暂停用例覆盖节奏停止/重启、1位DRAM读写、四音源并行、ADPCM复位和ZERO静音。

ZERO属于采样/分析路径的持续静音状态，播放路径必须验证其不误置位；其置位、保持和清除需要独立数字激励证据。录音编码和模拟电气特性仍按architecture.md排除，不用虚构状态替代验证。

## 参考模型差异的裁决

按手册和固定源码定位差异，分别断言已确认的功能行为；无法解释的差异不得通过。ymfm的采样率和输出格式不充当原生tick真值。固定ROM字节和外部存储输入必须相同。

ADPCM声道位采用D7=L、D6=R。[日文原始手册第47页的寄存器表及第54页的播放示例](https://raw.githubusercontent.com/grobique/minimal_OPNA_player/master/YM2608J.pdf)相互一致，示例将0x40指定为Rch；第47页正文对D6/D7的说明与表格相反，该矛盾也存在于英文译文。验收采用寄存器表及示例一致的定义，LLE与ymfm的独立声道输出也对应此定义。

ZERO按用户确认的数据手册契约：采样/分析期间连续静音约290 ms后置位，非静音重置静音计数。固定LLE的ad_ad_quiet在采样码接近零时为真，但其LFO复用计数器在该信号为真时复位，与手册相反。项目参考和RTL必须修正此计数极性，并独立验证静音置位、非静音计数复位和状态清除；固定上游源码保持原样。ymfm未实现ZERO，不作为该标志的置位真值。

CPU存储末端按手册保留最后两字节及EOS锁存。倒数第二/最后字节读后的原生状态依次为0x08、0x0C；ymfm依次为0x0C、0x08，其adpcm_b_channel::read先递增地址再检查末端并重写内部状态。ROM及8位DRAM的完整有效载荷一致，末端状态差异分别独立断言。掩码清除后的原生标志需要新事件再次置位；ymfm根据内部音源状态重新生成标志。PCM BUSY的原生START锁存和ymfm播放结束清除行为也分别记录，软件执行手册的结束流程清除START。

1位DRAM的stop=limit=0xFFFF末端存在ymfm额外差异：其读函数在倒数第二字节后提前命中限制并回卷到0，最后一字节返回地址0的数据。该错误返回值单独断言；原生参考及RTL仍必须返回全部四个正确末端字节。ROM和8位DRAM的末端载荷完整一致。

## 实现与证据

RTL包含固定8192字节节奏ROM、六通道原生解码/音量运算、Delta-T原生存储控制及播放运算；ADC数字路径使用外部DAC反馈，不包含录音编码或模拟电气模型。五种ZERO用例打开SAMPLE模式，通过ADC共享的静音检测与计数链验证标志，不作为录音编码路径验收。激励经S/OPO/SH2串行数据反馈DAC试探码，使用偏置中点128及偏离中点64/192的数字输入。限制地址用例满足手册的limit≥stop，并核对地址寄存器环在限制命中后的清零和外部访问范围。

证据目录为build/opna_sim/phase-05。入口为`.\scripts\run_opna_gate.ps1 -Phase 5 -Step D`，顺序执行Phase 1～4累计回归及Phase 5 A～D。reference-contract.json保存两种参考的dummy read、载荷和状态预期；compare-*.json保存所有原始数字值及tick比较。

ZERO静音轨迹的ADC采样码在tick 9409稳定为0xFF，ZERO在tick 4683801置位，间隔约292.15 ms。该轨迹[491682条观察记录](../../verification/phase-05/compare-adpcm_zero_silence.json)的原始数字值和tick完整一致；状态读取为0x1C，包含ZERO、BRDY及EOS。

非静音轨迹保持ADC码0xBF，ZERO不置位，状态读取为0x0C，[491680条记录](../../verification/phase-05/compare-adpcm_zero_nonquiet.json)完整一致。中途声音轨迹在tick 2009377变为0x3F、2208169恢复0xFF，ZERO在6878361置位，重新静音后约291.89 ms；[716942条记录](../../verification/phase-05/compare-adpcm_zero_interrupted.json)完整一致。

## 当前结论

Phase 5 A～D全部通过，检查数分别为103、152、157、158。48个正式RTL用例和五个时钟暂停用例的全部数字值及tick与项目参考完整一致，Phase 1～4累计回归在本轮重新执行并通过。[最终门控证据](../../verification/phase-05/gate-D.json)。

本阶段完成节奏音、ADPCM-B播放与样本存储访问、EOS/BRDY/ZERO及相关IRQ验收；ZERO数字验证范围如上，不包含录音编码或模拟电气特性。完整数字逻辑仿真验收属于Phase 6，综合、布线和实板验证属于Phase 7。
