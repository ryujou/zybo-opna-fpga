"""Compare source register usage; these statistics do not prove hardware sound output."""
import collections
import json
from pathlib import Path
import struct
import play_pc98

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/usb_dual/register-probe'


def inspect(path, seconds=None):
    events, memory, duration, counts, clock = play_pc98.load_music(path, seconds)
    registers = collections.defaultdict(collections.Counter)
    keys = collections.Counter()
    rhythms = collections.Counter()
    volumes = [collections.Counter() for _ in range(3)]
    mixer = collections.Counter()
    state = [0] * 16
    previous = tick = 0
    max_burst = 0
    recent = collections.deque()
    for delta, count, bank, reg, value in struct.iter_unpack('<IBBBB', events):
        tick += delta
        held = tick - previous
        for ch in range(3):
            volumes[ch][str(state[8+ch])] += held
        mixer[f'{state[7]:02x}'] += held
        previous = tick
        registers[f'{bank}:{reg:02x}'][f'{value:02x}'] += 1
        if bank == 0 and reg < 16:
            state[reg] = value
        if bank == 0 and reg == 0x28 and value & 0xf0:
            keys[str((value & 3) + (3 if value & 4 else 0) + 1)] += 1
        if bank == 0 and reg == 0x10 and not value & 0x80:
            for ch in range(6):
                if value & (1 << ch): rhythms[str(ch)] += 1
        recent.append(tick)
        while recent[0] < tick - 1000:
            recent.popleft()
        max_burst = max(max_burst, len(recent))
    tail = max(0, round(duration * 1e6) - tick)
    for ch in range(3): volumes[ch][str(state[8+ch])] += tail
    mixer[f'{state[7]:02x}'] += tail
    return dict(duration=duration, chip_clock=clock, writes=counts, sample_bytes=len(memory),
                total_writes=len(events)//8, max_writes_in_1ms=max_burst,
                fm_key_on=keys, rhythm_key_on=rhythms,
                ssg_volume_time_fraction=[{v:round(t/(duration*1e6),6) for v,t in hist.items()} for hist in volumes],
                ssg_mixer_time_fraction={v:round(t/(duration*1e6),6) for v,t in mixer.items()},
                register_value_counts=dict(sorted(registers.items())))


def main():
    paths = list((ROOT/'build/native_music/touhou_original/th01_vgm').glob('*.vgm'))
    paths += list((ROOT/'build/native_music/touhou_original/th03_vgm').glob('*.vgm'))
    paths += [ROOT/'build/native_music/Blue_Nebula.vgm', ROOT/'build/native_music/CT_maintheme.vgm',
              ROOT/'tools/opna_sim/fixtures/counterattack/Counterattack.vgm']
    OUT.mkdir(parents=True, exist_ok=True)
    result = {}
    for path in paths:
        a = inspect(path)
        b = inspect(path, 25)
        result[path.stem] = dict(file=str(path), full=a, first25=b)
        special = {reg:b['register_value_counts'].get(reg,{}) for reg in ('0:27','0:29','0:2d','0:2e','0:2f')}
        loud = [round(sum(t for v,t in h.items() if int(v)<16 and int(v)>=12),3) for h in b['ssg_volume_time_fraction']]
        print(path.stem, 'writes', b['writes'], 'RAM',b['sample_bytes'], 'FM', b['fm_key_on'],
              'SSG volume>=12 fraction', loud, 'mode',special, flush=True)
    (OUT/'register-comparison.json').write_text(json.dumps(result,indent=2),encoding='utf-8')


if __name__ == '__main__':
    main()
