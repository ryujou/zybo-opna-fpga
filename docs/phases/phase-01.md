# Phase 1：可信仿真对比环境

## 步骤门控

| 步骤 | 状态 | 证据 |
| --- | --- | --- |
| A | 通过 | [检查结果](../../verification/phase-01/gate-A.json) |
| B | 通过 | [检查结果](../../verification/phase-01/gate-B.json) |
| C | 通过 | [检查结果](../../verification/phase-01/gate-C.json) |
| D | 通过 | [检查结果](../../verification/phase-01/gate-D.json) |

## 输入与时间

总线文件首行为总tick数；随后每行七个十进制整数：tick ic cs_n wr_n rd_n address data。tick严格递增，首事件为tick 0；每行表示从该边沿开始保持的引脚值。偶数tick低时钟、奇数tick高时钟，每tick 62.5 ns。禁止同时读写。读返回在解除读选通前一个tick采样。

样本文件每行为字节地址和字节值，tick 0前初始化。Phase 1验证解析和初始化；ADPCM外部存储的芯片总线一致性在Phase 5验收。

IC先高，再低至少576主时钟，再释放并稳定576主时钟。地址和数据分别选通，数据写之间保留默认分频忙窗口所需间隔。

## 输出约定

CSV每行：tick,kind,index,value。read为读返回，irq为1表示请求，busy为1表示忙；pcm的index 0/1为左右有符号16位样本；ssg的index 0/1/2为门控后的5位音量码。记录真实变化时间，不搜索时移或增益。

LLE从S/OPO/SH1/SH2恢复数字音频，SSG提取数字门控/音量，不比较模拟电压。ymfm使用clock/8最高保真率，其第三输出为SSG幅值，标记ssg_pcm；ymfm时间粒度不充当逐边沿真值。两个参考各自验证重复性，不强求不同精度模型逐位相同。

串行样本在S下降沿、SH下降沿锁存完成后取得；SH2对应左声道(index 0)，SH1对应右声道(index 1)。该映射由B4的80/40单声道用例固定，且与[Furnace的LLE输出路由](https://github.com/tildearrow/furnace/blob/master/src/engine/platform/ym2608.cpp)中dacOut[1]到outL、dacOut[0]到outR的连接交叉核对。

XSim本阶段验证输入边沿、引脚重放、读取采样及JT10B可展开，不把JT10B输出当作已通过YM2608验收。

## 必需检查

- A：源码版本/许可证存在，参考编译，复位和SSG读回独立预期成立。
- B：XSim编译/展开和输入逐项重放通过，参考产生非零FM、SSG活动和busy变化；两个模型的左右单声道映射均通过。
- C：参考重复一致；修改样本、漏掉SSG写入、移动一时钟均被比较器拒绝。
- D：A/B/C累计重跑通过；文档、接口、限制和功能清单齐全。

## 实现与证据

- reference.cpp分别驱动固定版本LLE/ymfm，包含定时器回调、busy期限、节奏ROM、样本输入和数字串行音频提取。
- tb_opna_trace_replay.sv在XSim中展开JT10B，重放同一引脚输入并检查读采样边沿。
- compare.py按tick/kind/index排序后精确比较，拒绝空输入和重复观察键，报告首差异和附近总线事件。
- scripts/run_opna_gate.ps1按A/B/C/D累计执行；前置门控未通过则返回非零；当前门控失败会使后续已有门控失效。
- [参考重复性](../../verification/phase-01/repeat-tone-lle.json)。
- [漏写检出](../../verification/phase-01/reject-dropped-write-lle.json)。
- [单时钟偏移检出](../../verification/phase-01/reject-shifted-clock-lle.json)：读值保持15，观察时间由tick 4287移至4289，仍拒绝。
- [样本错误检出](../../verification/phase-01/reject-altered-sample-lle.json)。

## 限制

参考模型分别通过功能和重复性检查，不代表二者互相逐位一致。外部ADPCM存储模式尚未验收，当前LLE桥仅提供字节模式读取，写入及其他模式由Phase 5覆盖。Phase 1不验证JT10B作为YM2608的声音或控制正确性。全部负向故障只写入build目录，不修改上游模型。

## 当前结论

以步骤D的当前门控状态为准。门控输出位于build/opna_sim/phase-01。
