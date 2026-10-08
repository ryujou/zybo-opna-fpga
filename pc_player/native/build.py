"""Build the Windows x64 desktop OPL DLL with the existing LLVM-MinGW toolchain."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LIB = ROOT / "third_party/libadlmidi"
OUT = ROOT / "build/player-native/opl"
DEFAULT_CXX = Path(os.environ.get("OPNA_VIVADO_ROOT", "J:/FPGA/2025.2/Vivado")) / "tps/mingw/10.0.0/win64.o/nt/bin/g++.exe"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cxx", default=os.environ.get("CXX") or shutil.which("g++") or str(DEFAULT_CXX))
    args = parser.parse_args()
    cxx = Path(args.cxx)
    cc = cxx.with_name(cxx.name.replace("g++", "gcc").replace("clang++", "clang"))
    OUT.mkdir(parents=True, exist_ok=True)
    defines = ["ADLMIDI_DESKTOP_VISUAL", "ADLMIDI_DISABLE_MIDI_SEQUENCER",
               "ADLMIDI_DISABLE_DOSBOX_EMULATOR", "ADLMIDI_DISABLE_OPAL_EMULATOR",
               "ADLMIDI_DISABLE_JAVA_EMULATOR"]
    sources = [LIB / "src" / name for name in (
        "adlmidi.cpp", "adlmidi_load.cpp", "adlmidi_midiplay.cpp", "adlmidi_opl3.cpp",
        "adlmidi_private.cpp", "inst_db.cpp", "wopl/wopl_file.c",
        "chips/nuked_opl3.cpp", "chips/nuked_opl3_v174.cpp",
        "chips/nuked/nukedopl3.c", "chips/nuked/nukedopl3_174.c")]
    sources.append(HERE / "opl_visual.cpp")
    flags = ["-O2", "-Wall", *[f"-D{x}" for x in defines],
             f"-I{LIB / 'include'}", f"-I{LIB / 'src'}"]
    objects = []
    for index, source in enumerate(sources):
        obj = OUT / f"{index:02d}_{source.stem}.o"
        cpp = source.suffix == ".cpp"
        subprocess.run([str(cxx if cpp else cc), *flags,
                        *(["-std=c++17"] if cpp else []), "-c", str(source), "-o", str(obj)], check=True)
        objects.append(str(obj))
    destination = HERE / "bin/opl_visual.dll"
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(cxx), "-shared", "-static", *objects, "-o", str(destination)], check=True)
    print(destination)


if __name__ == "__main__":
    main()
