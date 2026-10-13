"""Build the OPNA display DLL from the pinned libvgm and zlib sources."""
from pathlib import Path
import os
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "build/player-native"
VIVADO = Path(os.environ.get("OPNA_VIVADO_ROOT", "J:/FPGA/2025.2/Vivado"))
BIN = VIVADO / "tps/mingw/10.0.0/win64.o/nt/bin"
CXX, CC = BIN / "g++.exe", BIN / "gcc.exe"

def run(*args):
    subprocess.run([str(a).replace(chr(92), "/") for a in args], check=True)

if __name__ == "__main__":
    common = ["-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + str(BIN / "ninja.exe"),
              "-DCMAKE_C_COMPILER=" + str(CC), "-DCMAKE_CXX_COMPILER=" + str(CXX),
              "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"]
    zlib = BUILD / "zlib"
    run("cmake", "-S", ROOT / "third_party/zlib", "-B", zlib, *common)
    run("cmake", "--build", zlib, "--target", "zlibstatic", "--parallel", "4")
    lib = BUILD / "libvgm"
    run("cmake", "-S", ROOT / "third_party/libvgm", "-B", lib, *common,
        "-DBUILD_LIBAUDIO=OFF", "-DBUILD_PLAYER=OFF", "-DBUILD_TESTS=OFF", "-DBUILD_VGM2WAV=OFF",
        "-DSNDEMU__ALL=OFF", "-DSNDEMU_YM2608_ALL=ON", "-DSNDEMU_AY8910_MAME=ON",
        "-DZLIB_INCLUDE_DIR=" + str(ROOT / "third_party/libvgm/libs/include"),
        "-DZLIB_LIBRARY=" + str(zlib / "libzlibstatic.a"))
    run("cmake", "--build", lib, "--parallel", "4")
    output = HERE / "bin/opna_visual.dll"
    output.parent.mkdir(parents=True, exist_ok=True)
    run(CXX, "-std=c++17", "-O2", "-shared", "-static", "-I" + str(ROOT / "third_party/libvgm"),
        HERE / "opna_visual.cpp", "-Wl,--start-group", lib / "bin/libvgm-player.a",
        lib / "bin/libvgm-emu.a", lib / "bin/libvgm-utils.a", zlib / "libzlibstatic.a",
        "-Wl,--end-group", "-lwinmm", "-o", output)
    print(output)
