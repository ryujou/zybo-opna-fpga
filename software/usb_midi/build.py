"""Build USB MIDI against the closed OPNA hardware's standalone BSP."""
import argparse
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LIB = ROOT / "third_party/libopnmidi"
OUT = ROOT / "build/usb_midi"
VITIS = Path(os.environ.get("XILINX_VITIS", "J:/FPGA/2025.2/Vitis"))
SOURCE = ROOT / "software/ps_baremetal/src"
DEFINES = ["OPNMIDI_DISABLE_MIDI_SEQUENCER"] + ["OPNMIDI_DISABLE_" + name + "_EMULATOR" for name in
    ("NUKED", "MAME", "GENS", "GX", "NP2", "MAME_2608", "PMDWIN", "YMFM")]


def run(args):
    subprocess.run([str(a) for a in args], check=True)


def main():
    global OUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--boot", action="store_true", help="also build a matching FSBL and BOOT.bin")
    parser.add_argument("--dual-mode", action="store_true", help="SW0 selects USB MIDI or native PC-98 register playback")
    parser.add_argument("--board", type=Path, default=ROOT / "build/opna_phase7/board")
    parser.add_argument("--out", type=Path, help="output directory for a matching diagnostic build")
    args = parser.parse_args()
    if args.dual_mode:
        OUT = ROOT / "build/usb_dual"
    if args.out:
        OUT = args.out.resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    # Keep upstream unmodified: the only backend changes are in this generated translation unit.
    backend = (LIB / "src/opnmidi_opn2.cpp").read_text(encoding="utf-8")
    backend = backend.replace('#error "No emulators enabled. You must enable at least one emulator to use this library!"', '')
    backend = backend.replace('#include "models/opn_models.h"', '#include "models/opn_models.h"\n#include "fpga_chip.h"')
    backend = backend.replace('static const unsigned opn2_emulatorSupport = 0', 'static const unsigned opn2_emulatorSupport = (1u << OPNMIDI_EMU_MAME_2608)')
    backend = backend.replace('        switch(emulator)\n        {', '        switch(emulator)\n        {\n        case OPNMIDI_EMU_MAME_2608:\n            chip = new FpgaOPNA(family);\n            break;')
    # Upstream frequency tables target 7.9872 MHz; this board implements exactly 8 MHz.
    backend = backend.replace('ftone = m_getFreq(tone, &mul_offset);', 'ftone = m_getFreq(tone - 0.027722429, &mul_offset);')
    generated = OUT / "opnmidi_opn2.cpp"
    generated.write_text(backend, encoding="utf-8")
    bank = (LIB / "fm_banks/xg.wopn").read_bytes()
    (OUT / "bank_data.h").write_text('static const unsigned char bank_data[] = {' + ','.join(str(b) for b in bank) + '};\n', encoding="utf-8")
    sources = [HERE / n for n in ("midi_parser.cpp", "midi_synth.cpp", "usb_descriptors.cpp")]
    sources += [LIB / "src" / n for n in ("opnmidi.cpp", "opnmidi_load.cpp", "opnmidi_midiplay.cpp", "opnmidi_private.cpp", "wopn/wopn_file.c")]
    sources += sorted((LIB / "src/models").glob("*.c")) + [generated]
    includes = [HERE, OUT, LIB / "include", LIB / "src", SOURCE]
    flags = ["-O2", "-g", "-Wall", "-ffunction-sections", "-fdata-sections"]
    if args.test:
        binaries = Path("J:/FPGA/2025.2/Vivado/tps/mingw/10.0.0/win64.o/nt/bin")
        cxx, cc = binaries / "g++.exe", binaries / "gcc.exe"
        sources += [HERE / "tests.cpp"]
        link = ["-static"]
        output = OUT / "tests.exe"
        objects = OUT / "host_obj"
    else:
        binaries = VITIS / "gnu/aarch32/nt/gcc-arm-none-eabi/bin"
        cxx, cc = binaries / "arm-none-eabi-g++.exe", binaries / "arm-none-eabi-gcc.exe"
        bsp = args.board / "software/bsp/ps7_cortexa9_0"
        includes += [bsp / "include"]
        flags += ["-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard", "-Wno-psabi"]
        sources += [HERE / ("main_dual.cpp" if args.dual_mode else "main.cpp"), HERE / "usb_device.cpp"]
        sources += [SOURCE / n for n in ("opl_hw.cpp", "ssm2603.cpp", "timer_ps.cpp")]
        if args.dual_mode:
            sources += [SOURCE / n for n in ("opl_stream.cpp", "transport.cpp", "transport_usb.cpp", "transport_uart.cpp", "usb_ch9.c", "usb_descriptors.c")]
            flags += ["-DOPNA_DUAL_MODE"]
        link = [f"-specs={VITIS / 'data/embeddedsw/scripts/specs/arm/Xilinx.spec'}", "-specs=nosys.specs",
                "-Wl,-u,_vector_table", f"-L{bsp / 'lib'}", f"-T{SOURCE / 'lscript.ld'}",
                "-Wl,--defsym,_HEAP_SIZE=0x400000", "-Wl,--defsym,_STACK_SIZE=0x10000",
                f"-Wl,-Map,{OUT / 'opna_usb_midi.map'}", "-Wl,--start-group,-lxil,-lstdc++,-lc,-lm,-lgcc,--end-group"]
        output = OUT / ("opna_usb_dual.elf" if args.dual_mode else "opna_usb_midi.elf")
        objects = OUT / "arm_obj"
    os.environ["PATH"] = str(binaries) + os.pathsep + os.environ["PATH"]
    objects.mkdir(exist_ok=True)
    compiled = []
    for i, source in enumerate(sources):
        obj = objects / f"{i}_{source.stem}.o"
        cpp = source.suffix == ".cpp"
        run([cxx if cpp else cc, *flags, *(["-std=c++17"] if cpp else []),
             *[f"-D{d}" for d in DEFINES], *[f"-I{p}" for p in includes], "-c", source, "-o", obj])
        compiled.append(obj)
    run([cxx, *flags, *compiled, "-Wl,--gc-sections", *link, "-o", output])
    if args.test:
        run([output])
    else:
        run([binaries / "arm-none-eabi-size.exe", output])
        if args.boot:
            run([VITIS / "bin/xsct.bat", HERE / "build_fsbl.tcl", args.board / "zybo_opna.xsa", OUT / "fsbl"])
            os.environ["PATH"] = str(VITIS / "gnuwin/bin") + os.pathsep + os.environ["PATH"]
            run([VITIS / "gnuwin/bin/make.exe", "-C", OUT / "fsbl", "SHELL=cmd.exe"])
            bif = OUT / "usb_midi.bif"
            bif.write_text('the_ROM_image:\n{\n' +
                           f' [bootloader] "{(OUT / "fsbl/executable.elf").as_posix()}"\n' +
                           f' "{(args.board / "zybo_opna.bit").as_posix()}"\n' +
                           f' "{output.as_posix()}"\n}}\n', encoding="utf-8")
            run([VITIS / "bin/bootgen.bat", "-image", bif, "-arch", "zynq", "-o", OUT / "BOOT.bin", "-w", "on"])
    print(output)


if __name__ == "__main__":
    main()
