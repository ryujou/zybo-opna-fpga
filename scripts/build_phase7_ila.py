"""Build the bounded on-board ILA stimulus against an already verified PS BSP."""
import argparse,json,os
from pathlib import Path
from build_phase7_ps import ROOT,SOURCE,run

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--software',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args();sw=a.software.resolve();out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
software=json.loads((sw/'result.json').read_text(encoding='utf-8'))
if software['status']!='通过' or not software['xsa_contains_bitstream']: raise RuntimeError('Final XSA software build is required')
vitis=Path('J:/FPGA/2025.2/Vitis');cc=vitis/'gnu/aarch32/nt/gcc-arm-none-eabi/bin'
bsp=sw/'bsp/ps7_cortexa9_0';env=os.environ.copy()
flags=['-mcpu=cortex-a9','-mfpu=vfpv3','-mfloat-abi=hard','-O2','-g','-Wall','-ffunction-sections','-fdata-sections','-I',bsp/'include','-I',SOURCE]
run([cc/'arm-none-eabi-g++.exe',*flags,'-std=c++17','-fno-exceptions','-fno-rtti','-c',ROOT/'software/ps_baremetal/tests/ila_stimulus.cpp','-o',out/'ila_stimulus.o'],out/'stimulus-compile.log',env)
elf=out/'ila_stimulus.elf'
run([cc/'arm-none-eabi-g++.exe',*flags,'-specs='+str(vitis/'data/embeddedsw/scripts/specs/arm/Xilinx.spec'),'-specs=nosys.specs','-Wl,--gc-sections','-Wl,-u,_vector_table','-Wl,-T,'+str(SOURCE/'lscript.ld'),out/'ila_stimulus.o',*[sw/'objects'/n for n in ['opl_hw.cpp.o','ssm2603.cpp.o','timer_ps.cpp.o']],'-L',bsp/'lib','-Wl,--start-group','-lxil','-lc','-lgcc','-Wl,--end-group','-o',elf],out/'stimulus-link.log',env)
symbols=run([cc/'arm-none-eabi-nm.exe',elf],out/'ila-symbols.txt',env)
addresses={line.split()[2]:int(line.split()[0],16) for line in symbols.splitlines() if len(line.split())==3 and line.split()[2].startswith('opna_ila_')}
(out/'stimulus-symbols.json').write_text(json.dumps(addresses,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'elf':str(elf),'symbols':addresses}))

# Build the same pinned native oracle used by the RTL/ILA correspondence test.
compiler=Path(os.environ.get('OPNA_VIVADO_ROOT','J:/FPGA/2025.2/Vivado'))/'tps/mingw/10.0.0/win64.o/nt/bin'
lle=ROOT/'tools/opna_sim/vendor/ym2608_lle'
source=(lle/'fmopna_impl.c').read_text(encoding='utf-8')
pattern='chip->lfo_cnt_rst = chip->lfo_mode ? chip->ad_ad_quiet :'
if source.count(pattern)!=1: raise RuntimeError('Pinned ZERO contract changed')
source=source.replace(pattern,'chip->lfo_cnt_rst = chip->lfo_mode ? !chip->ad_ad_quiet :')
(out/'lle-zero-manual.c').write_text('#define FMOPNA_YM2608\n#define FMOPNA_Clock FMOPNA_ClockZeroManual\n'+source,encoding='utf-8')
run([compiler/'gcc.exe','-O2','-I',lle,'-c',out/'lle-zero-manual.c','-o',out/'lle-zero-manual.o'],out/'oracle-compile-lle.log',env)
run([compiler/'g++.exe','-std=c++14','-O2','-static','-I',lle,ROOT/'tools/opna_sim/phase7_ila_oracle.cpp',out/'lle-zero-manual.o','-o',out/'oracle.exe'],out/'oracle-compile.log',env)
