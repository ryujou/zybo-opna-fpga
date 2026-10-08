"""Actual hardware capture; requires the built ILA stimulus and its matching final board artifacts."""
import argparse,json,subprocess,time,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description='Capture eight cold-start native profiles and six I2S traces on the Zybo board.')
p.add_argument('--board',type=Path,required=True)
p.add_argument('--oracle',type=Path,required=True)
p.add_argument('--profiles',nargs='+',choices=['dc','fm','rhythm','rom','ram8','ram1','write_ram8','write_ram1'],default=['dc','fm','rhythm','rom','ram8','ram1','write_ram8','write_ram1'])
a=p.parse_args();board=a.board.resolve();hw=board/'hardware';oracle=a.oracle.resolve()
sys.path.insert(0,str(root/'tools/opna_sim'))
from phase7_ila_compare import compare_native,compare_audio
symbols=json.loads((hw/'stimulus-symbols.json').read_text(encoding='utf-8'))
connection='connect -url tcp:127.0.0.1:3121\ntargets -set -timeout 10 -filter {name == "APU" && jtag_cable_serial == "210279540276A"}\nloadhw -hw {'+(board/'zybo_opna.xsa').as_posix()+'}\n'
cpu='targets -set -timeout 10 -filter {name == "ARM Cortex-A9 MPCore #0" && jtag_cable_serial == "210279540276A"}\n'
(hw/'hold.tcl').write_text(connection+cpu+'stop\nmwr 0xF8000008 0xDF0D\nmwr 0xF8000240 0xF\ntargets -set -timeout 10 -filter {name == "xc7z010" && jtag_cable_serial == "210279540276A"}\nfpga -file {'+(board/'zybo_opna.bit').as_posix()+'}\nputs OPNA_COLD_ILA_HELD\ndisconnect\n',encoding='utf-8')
(hw/'start-profile.tcl').write_text('set profile [lindex $argv 0]\n'+connection+cpu+
    f'mwr {symbols["opna_ila_result"]} 1\nmwr {symbols["opna_ila_profile"]} $profile\nmwr {symbols["opna_ila_go"]} 1\n'+
    'con\ntargets -set -timeout 10 -filter {name == "APU" && jtag_cable_serial == "210279540276A"}\nmwr 0xF8000008 0xDF0D\nmwr 0xF8000240 0\nafter 100\n'+
    f'set result [lindex [mrd -value {symbols["opna_ila_result"]}] 0]\n'+
    'set status [lindex [mrd -value 0x43C00008] 0]\nif {$result!=2 || ($status & 8)} {error "Board stimulus failed"}\nputs "OPNA_ILA_STIMULUS profile=$profile result=$result status=$status"\ndisconnect\n',encoding='utf-8')
vivado='J:/FPGA/2025.2/Vivado/bin/vivado.bat';xsct='J:/FPGA/2025.2/Vitis/bin/xsct.bat'
def xs(script,args,log,marker):
 with log.open('w',encoding='utf-8') as f: subprocess.run([xsct,str(script),*args],stdout=f,stderr=subprocess.STDOUT,check=True)
 text=log.read_text(encoding='utf-8',errors='replace')
 if marker not in text or 'error executing' in text: raise RuntimeError(str(log))
def capture(name,mode,profile=None):
 out=hw/name;out.mkdir(exist_ok=True);log=out/f'{mode}-capture.log'
 log.unlink(missing_ok=True)
 with (out/f'{mode}-console.log').open('w',encoding='utf-8') as f:
  proc=subprocess.Popen([vivado,'-mode','batch','-source','scripts/phase7_capture.tcl','-log',str(log),'-journal',str(out/f'{mode}-capture.jou'),'-tclargs',str(board/'zybo_opna.ltx'),str(out),mode],stdout=f,stderr=subprocess.STDOUT)
  if profile is not None:
   deadline=time.time()+45
   while time.time()<deadline:
    text=log.read_text(encoding='utf-8',errors='replace') if log.exists() else ''
    if f'\nOPNA_ILA_ARMED mode={mode}\n' in text:
     xs(hw/'start-profile.tcl',[str(profile)],out/'stimulus.log','OPNA_ILA_STIMULUS');break
    if proc.poll() is not None: raise RuntimeError(str(log))
    time.sleep(.5)
   else: raise TimeoutError('ILA arm')
  if proc.wait(timeout=90): raise RuntimeError(str(log))
 if f'\nOPNA_ILA_CAPTURE_COMPLETE mode={mode}\n' not in log.read_text(encoding='utf-8',errors='replace'): raise RuntimeError(str(log))
 print('CAPTURED',name,mode,flush=True)

results={}
xs(root/'scripts/phase7_jtag.tcl',[str(board/'zybo_opna.xsa'),str(board/'zybo_opna.bit'),str(hw/'ila_stimulus.elf'),str(board/'software/ps7_init.tcl')],hw/'jtag-stimulus.log','PHASE7_JTAG_STARTED')
for name in a.profiles:
 profile=['dc','fm','rhythm','rom','ram8','ram1','write_ram8','write_ram1'].index(name)
 xs(hw/'hold.tcl',[],hw/f'{name}-hold.log','OPNA_COLD_ILA_HELD')
 capture(name,'native',profile)
 results[name]={'native':compare_native(hw/name,oracle)}
 if profile<6:
  capture(name,'audio')
  results[name]['audio']=compare_audio(hw/name,name=='dc')
 else:
  results[name]['ddr_readback_bytes']=262144
 print(json.dumps({name:results[name]}),flush=True)
 if not all(r['passed'] for r in results[name].values() if isinstance(r,dict)): raise RuntimeError(name+' comparison failed')
(hw/('ila-result.json' if len(a.profiles)==8 else 'ila-selected-result.json')).write_text(json.dumps({'passed':True,'hardware_capture':True,'profiles':results},indent=2)+'\n',encoding='utf-8')

