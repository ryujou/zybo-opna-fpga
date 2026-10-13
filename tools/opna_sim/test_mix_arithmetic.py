"""Compare RTL against unbounded integer Q16 arithmetic, including gain snapshots."""
from pathlib import Path
import random
import gate
from analyze_music_capture import AMPLITUDE

OUT = gate.ROOT / 'build/usb_dual/volume-fix/mix-tests'


def rounded(value):
    return ((value + 32768) >> 16) if value >= 0 else -((-value + 32768) >> 16)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rng = random.Random(2608)
    vectors = []
    for gp, gs, gm in [(0,0,0),(65536,65536,0),(65536,65536,65536),(131072,21845,8192),
                       (0,65536,65536),(65536,0,65536),(32768,32768,32768),
                       (0xffffffff,0xffffffff,0xffffffff)]:
        for pl,pr in [(0,0),(1,-1),(32767,-32768),(-32768,32767)]:
            for a in [0,1,2,15,31]:
                vectors.append((pl,pr,a,a,a,gp,gs,gm))
    for _ in range(1000):
        vectors.append((*[rng.randrange(-32768,32768) for _ in range(2)],
                        *[rng.randrange(32) for _ in range(3)],
                        *[rng.randrange(2**32) for _ in range(3)]))
    for _ in range(1000):
        vectors.append((*[rng.randrange(-10000,10001) for _ in range(2)],
                        *[rng.randrange(32) for _ in range(3)],
                        *[rng.randrange(4*65536) for _ in range(3)]))
    lines=[]
    for pl,pr,a,b,c,gp,gs,gm in vectors:
        ssg=sum(int(AMPLITUDE[n]) for n in (a,b,c))
        final=[rounded(rounded(p*gp+ssg*gs)*gm) for p in (pl,pr)]
        output=[max(-32768,min(32767,v)) for v in final]
        clips=[int(v>32767 or v< -32768) for v in final]
        lines.append(f'{pl} {pr} {a} {b} {c} {gp:x} {gs:x} {gm:x} '+ ' '.join(map(str,output+clips)))
    (OUT/'vectors.txt').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    gate.run([gate.VIVADO/'xvlog.bat','--sv',gate.ROOT/'hardware/rtl/board/opna_audio_output.sv',
              Path(__file__).with_name('mix_arithmetic_tb.sv')],OUT/'compile.log',OUT)
    gate.run([gate.VIVADO/'xelab.bat','mix_arithmetic_tb','-s','mix','--debug','typical','--timescale','1ns/1ps'],OUT/'elaborate.log',OUT)
    gate.run([gate.VIVADO/'xsim.bat','mix','-runall'],OUT/'simulate.log',OUT)
    log=(OUT/'simulate.log').read_text(encoding='utf-8')
    assert 'MIX_ARITHMETIC_PASS' in log and 'Fatal' not in log, log
    print(f'PASS: {len(vectors)} exact integer vectors')


if __name__=='__main__':
    main()
