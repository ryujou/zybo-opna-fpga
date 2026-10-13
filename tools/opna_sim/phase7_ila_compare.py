"""Compare a cold-start native ILA capture with the pinned LLE oracle."""
import argparse
import csv
import json
import subprocess
from pathlib import Path

FIELDS = {'dout': (0,8), 'irq_n': (8,1), 'busy': (9,1), 'pcm_valid': (10,2),
          'pcm_left': (12,16), 'pcm_right': (28,16), 'ssg_a': (44,5),
          'ssg_b': (49,5), 'ssg_c': (54,5), 'dm': (59,8), 'dm_d': (67,1),
          'a8': (68,1), 'ras_n': (69,1), 'cas_n': (70,1), 'we_n': (71,1),
          'romcs_n': (72,1), 'mden': (73,1)}

def compare_native(directory, oracle):
    rows = list(csv.reader((directory/'native.csv').open(encoding='utf-8')))[2:]
    if len(rows) != 8192 or any(int(r[3],16)!=1 for r in rows):
        raise ValueError('Expected 8192 qualified native ticks')
    inputs = [int(r[4],16) for r in rows]
    counters = [int(r[6],16) for r in rows]
    if counters[0]!=7 or inputs[0]>>24 or (inputs[0]>>1)&1:
        raise ValueError('Capture must start at the first cold native tick')
    with (directory/'consumed.txt').open('w',encoding='utf-8') as output:
        for i,x in enumerate(inputs):
            values = [(x>>s)&((1<<w)-1) for s,w in [(1,1),(24,1),(23,1),(22,1),(21,1),(19,2),(11,8),(3,8),(2,1)]]
            output.write(' '.join(map(str,[i]+values))+'\n')
    subprocess.run([str(oracle),str(directory/'consumed.txt'),str(directory/'expected.csv')],check=True)
    expected = list(csv.DictReader((directory/'expected.csv').open(encoding='utf-8')))
    if len(expected)!=len(rows): raise ValueError('Reference row count mismatch')
    differences=[]; values={k:set() for k in FIELDS}; fault_ticks=0
    ports=[]; previous_write=False
    for x in inputs:
        writing=not(x>>23&1) and not(x>>22&1)
        if writing and not previous_write: ports.append(((x>>19)&3,(x>>11)&255))
        previous_write=writing
    registers=[]; addresses=[0,0]
    for port,value in ports:
        if port&1: registers.append([port>>1,addresses[port>>1],value])
        else: addresses[port>>1]=value
    sequences={
        'dc':[[0,7,63],[0,8,15],[0,9,8],[0,10,0]],
        'fm':[[0,r,v] for r,v in [(0x29,0x9f),(0x30,1),(0x50,31),(0x80,15),(0xb0,7),(0xb4,0x80),(0xa4,0x22),(0xa0,0x69),(0x28,0x10)]],
        'rhythm':[[0,0x11,63],[0,0x18,0xdf],[0,0x10,1]]}
    for name,kind in [('rom',1),('ram8',2),('ram1',0)]:
        sequences[name]=[[1,r,v] for r,v in [(1,0xc0|kind),(4,1),(0xc,255),(0xd,255),(9,255),(10,255),(11,255),(0,0xb0)]]
    for name,kind in [('write_ram8',2),('write_ram1',0)]:
        sequences[name]=[[1,r,v] for r,v in [(1,0xc0|kind),(2,1),(4,8),(12,255),(13,255),(0,0x60),(8,0xa5)]]
    stimulus_complete=registers==sequences[directory.name]
    phase_errors=sum(((a>>1)&1)==((b>>1)&1) for a,b in zip(inputs,inputs[1:]))
    for i,(row,reference) in enumerate(zip(rows,expected)):
        x=int(row[5],16); fault_ticks+=(x>>75)&1
        for name,(shift,width) in FIELDS.items():
            value=(x>>shift)&((1<<width)-1)
            if name in ('pcm_left','pcm_right') and value>=32768: value-=65536
            values[name].add(value)
            if value!=int(reference[name]): differences.append([i,name,value,int(reference[name])])
    gaps=[(b-a)&0xffffffff for a,b in zip(counters,counters[1:])]
    result={'passed':not differences and fault_ticks==0 and stimulus_complete and phase_errors==0,'hardware_capture':True,
            'native_ticks':len(rows),'public_bits_per_tick':74,'warmup_discarded':0,
            'differences':len(differences),'first_differences':differences[:20],
            'fault_ticks':fault_ticks,'stimulus_complete':stimulus_complete,'register_writes':registers,'phase_errors':phase_errors,'sys_tick_gaps':sorted(set(gaps)),
            'programmed_write_ticks':sum(not(x>>23&1) and not(x>>22&1) for x in inputs),
            'active_nonzero_pcm_left_ticks':sum(int(r['pcm_left'])!=0 for r in expected[2304:]),
            'active_nonzero_pcm_right_ticks':sum(int(r['pcm_right'])!=0 for r in expected[2304:]),
            'value_ranges':{k:[min(v),max(v)] for k,v in values.items()}}
    if directory.name in ('rom','ram8','ram1'):
        address=0; old_ras=old_cas=1; previous=0; changed_at=0
        memory_checks=0; memory_errors=[]; read_addresses=set()
        pattern=(1,35,69,103,137,171,205,239)
        for i,row in enumerate(rows):
            x=int(row[4],16); y=int(row[5],16)
            # Six native intervals exceed the measured 30 SYS pin-to-data budget.
            if previous>>67&1 and (not(previous>>72&1) or previous>>73&1) and i-changed_at>=6:
                if directory.name=='ram1':
                    want=sum((((pattern[(bank*32768+(address>>3))%8] if bank*32768+(address>>3)<2048 else 0)>>(address&7))&1)<<bank for bank in range(8))
                else: want=pattern[address%8] if address<2048 else 0
                got=x>>3&255; memory_checks+=1; read_addresses.add(address)
                if got!=want: memory_errors.append([i,address,got,want])
            bus=y>>59&511; ras=y>>69&1; cas=y>>70&1; next_address=address
            if old_ras and not ras: next_address=(next_address&~511)|bus
            if old_cas and not cas: next_address=(next_address&511)|(bus<<9)
            if address!=next_address: changed_at=i
            address=next_address;old_ras=ras;old_cas=cas;previous=y
        result['sample_memory']={'stable_pin_sample_checks':memory_checks,'addresses':sorted(read_addresses),'differences':len(memory_errors),'first_differences':memory_errors[:20]}
        result['passed'] &= memory_checks>0 and not memory_errors and result['active_nonzero_pcm_left_ticks']>0 and result['active_nonzero_pcm_right_ticks']>0
    if directory.name in ('fm','rhythm'):
        result['passed'] &= result['active_nonzero_pcm_left_ticks']>0
    if directory.name.startswith('write_'):
        writes=[]; old_we=old_cas=1
        for i,row in enumerate(rows):
            y=int(row[5],16); we=y>>71&1; cas=y>>70&1
            if not we and not cas and not(y>>69&1) and not(y>>67&1) and (old_we or old_cas):
                writes.append([i,y>>59&255])
            old_we=we;old_cas=cas
        result['native_memory_writes']=writes
        result['passed'] &= ([w[1] for w in writes]==[0xa5] if directory.name=='write_ram8' else [w[1]&1 for w in writes]==[1,0,1,0,0,1,0,1])
    (directory/'native-result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return result

def compare_audio(directory, dc=False):
    rows=list(csv.reader((directory/'audio.csv').open(encoding='utf-8')))[2:]
    if len(rows)!=4096: raise ValueError('Expected 4096 audio clocks')
    data=[[int(x,16) for x in r[3:]] for r in rows]
    phases=[r[1]|r[2]<<1|r[3]<<2|r[4]<<7 for r in data]
    errors=[]
    for i,(a,b) in enumerate(zip(data,data[1:])):
        phase=phases[i]
        if phases[i+1]!=(phase+1)%256: errors.append([i,'phase'])
        sd=a[5]
        if phase&3==3:
            bit=(phase>>2)&31
            sd=(a[0]>>((15 if phase&128 else 31)-bit))&1 if bit<16 and not a[11] else 0
        if b[5]!=sd: errors.append([i,'i2s_sd'])
        if a[6]!=(phase>>7) or a[7]!=((phase>>1)&1): errors.append([i,'i2s_clocks'])
        if not a[8] or a[11] or not a[12] or not a[13]: errors.append([i,'audio_enable'])
        if b[0]!=a[0] and phases[i+1]!=0: errors.append([i,'frame_boundary'])
        if b[9]!=(a[9]^(phase==255)): errors.append([i,'request_toggle'])
        if phase==255 and a[10]!=a[9]: errors.append([i,'missed_mailbox_frame'])
    frames=set(r[0] for r in data)
    if dc and frames!={0x46394639}: errors.append([0,'dc_frame',sorted(frames)])
    result={'passed':not errors,'hardware_capture':True,'audio_clocks':len(rows),
            'errors':len(errors),'first_errors':errors[:20],'distinct_frames':len(frames),
            'nonzero_frames':sum(r[0]!=0 for r in data),'frame_examples':[f'{x:08x}' for x in sorted(frames)[:8]],
            'dc_expected_frame':'46394639' if dc else None}
    (directory/'audio-result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',type=Path);p.add_argument('--oracle',type=Path,required=True)
    p.add_argument('--audio',action='store_true');p.add_argument('--dc',action='store_true')
    a=p.parse_args();results={'native':compare_native(a.directory,a.oracle.resolve())}
    if a.audio: results['audio']=compare_audio(a.directory,a.dc)
    print(json.dumps(results))
    raise SystemExit(0 if all(r['passed'] for r in results.values()) else 1)
