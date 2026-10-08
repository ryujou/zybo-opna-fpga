#!/usr/bin/env python3
"""Build the Phase 7 Cortex-A9 application and execute its host contracts."""
import argparse
import ast
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "software/ps_baremetal/src"
DEFAULT_XSA = ROOT / "build/opna_phase7/board/zybo_opna.xsa"


def run(command, log, env, *, cwd=ROOT, stdin=None):
    proc = subprocess.run([str(part) for part in command], cwd=cwd, env=env,
                          input=stdin, text=True, encoding="utf-8", errors="replace",
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(proc.stdout, encoding="utf-8")
    if proc.returncode:
        raise RuntimeError(f"Command failed ({proc.returncode}): {command[0]}\n{proc.stdout[-4000:]}")
    return proc.stdout


def music_input(path):
    sys.path.insert(0, str(ROOT / "tools/opna_sim"))
    from acceptance_cases import music_data
    writes, memory, _ = music_data()
    events, previous, count = bytearray(), 0, 0
    for sample, bank, register, value in writes:
        if sample >= 44100:
            break
        due = sample * 1_000_000 // 44100
        events.extend(struct.pack("<IBBBB", due - previous, 1, bank, register, value))
        previous, count = due, count + 1
    samples = bytes(memory.get(index, 0) for index in range(max(memory) + 1))
    if count != 887 or len(samples) != 34560:
        raise ValueError("Counterattack first-second fixture differs from the frozen Phase 6 input")
    path.write_bytes(b"OPN7" + struct.pack("<II", len(events), len(samples)) + events + samples)


def counter_frequency(compiler, include, out, env):
    expression = run([compiler, "-E", "-P", "-x", "c", "-I", include, "-"],
                     out / "timer-preprocess.log", env,
                     stdin='#include "xtime_l.h"\nOPNA_COUNTER_VALUE COUNTS_PER_SECOND\n')
    value = expression.split("OPNA_COUNTER_VALUE", 1)[1].strip()
    # Only the fresh BSP's integer clock/divider expression is evaluated.
    value = re.sub(r"(?<=\d)[uUlL]+\b", "", value).replace("/", "//")
    tree = ast.parse(value, mode="eval")
    if any(not isinstance(node, (ast.Expression, ast.Constant, ast.BinOp,
                                ast.FloorDiv, ast.Mult, ast.Add, ast.Sub))
           for node in ast.walk(tree)):
        raise ValueError(f"Unexpected BSP counter-frequency expression: {value}")
    frequency = eval(compile(tree, "<BSP COUNTS_PER_SECOND>", "eval"), {"__builtins__": {}}, {})
    if not isinstance(frequency, int) or frequency <= 0:
        raise ValueError("Invalid BSP global-counter frequency")
    return frequency


def elf_memory(elf, out, readelf, env):
    report = run([readelf, "-SW", elf], out / "elf-sections.txt", env)
    sections = []
    for line in report.splitlines():
        match = re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s+([0-9a-fA-F]+)\s+\S+\s+(\S+)", line)
        if match and "A" in match[4] and int(match[3], 16):
            address, size = int(match[2], 16), int(match[3], 16)
            if address < 0x00100000 or address + size > 0x01000000:
                raise ValueError(f"ELF allocated section overlaps reserved/native DDR: {match[1]}")
            sections.append({"name": match[1], "address": address, "size": size})
    bss = next(section for section in sections if section["name"] == ".bss")
    if bss["size"] < 8 * 1024 * 1024:
        raise ValueError("ELF does not contain the required 8MiB event buffer")
    header = run([readelf, "-h", elf], out / "elf-header.txt", env)
    if "ARM" not in header or not sections:
        raise ValueError("Output is not an allocated ARM ELF")
    return sections


def build(args):
    xsa = args.xsa.resolve()
    out = args.out.resolve()
    if not out.is_relative_to(ROOT / "build"):
        raise ValueError("PS build output must stay within this project's build directory")
    if not xsa.is_file():
        raise FileNotFoundError(xsa)
    out.mkdir(parents=True, exist_ok=True)
    # Fresh BSP/object directories prevent linking any prior hardware export.
    for child in (out / "bsp", out / "objects"):
        if child.exists():
            if not child.resolve().is_relative_to(out):
                raise ValueError(f"Build directory resolves outside the intended output: {child}")
            shutil.rmtree(child)
        child.mkdir()
    vitis = Path(os.environ.get("XILINX_VITIS", "J:/FPGA/2025.2/Vitis"))
    vivado = Path(os.environ.get("OPNA_VIVADO_ROOT", "J:/FPGA/2025.2/Vivado"))
    compiler_dir = vitis / "gnu/aarch32/nt/gcc-arm-none-eabi/bin"
    gcc, gpp = compiler_dir / "arm-none-eabi-gcc.exe", compiler_dir / "arm-none-eabi-g++.exe"
    host_cxx = args.host_cxx or Path(os.environ.get("CXX", str(vivado / "tps/mingw/10.0.0/win64.o/nt/bin/g++.exe")))
    env = os.environ.copy()
    env["XILINX_VITIS"] = str(vitis)
    env["PATH"] = os.pathsep.join((str(compiler_dir), str(vitis / "gnuwin/bin"), str(host_cxx.parent), env.get("PATH", "")))
    run([vitis / "bin/xsct.bat", ROOT / "scripts/build_phase7_ps.tcl", xsa, out / "bsp"], out / "bsp-generate.log", env)
    run([vitis / "gnuwin/bin/make.exe", "-C", out / "bsp", "SHELL=cmd.exe"], out / "bsp-make.log", env)
    bsp = out / "bsp/ps7_cortexa9_0"
    include = bsp / "include"
    flags = ["-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard", "-O2", "-g", "-Wall",
             "-ffunction-sections", "-fdata-sections", "-I", include, "-I", SOURCE]
    objects = []
    for source in sorted(SOURCE.glob("*")):
        if source.suffix not in (".c", ".cpp"):
            continue
        obj = out / "objects" / (source.name + ".o")
        options = ["-std=c++17", "-fno-exceptions", "-fno-rtti"] if source.suffix == ".cpp" else []
        run([gpp if options else gcc, *flags, *options, "-c", source, "-o", obj], out / (source.name + ".log"), env)
        objects.append(obj)
    elf = out / "opna_ps.elf"
    run([gpp, *flags, "-specs=" + str(vitis / "data/embeddedsw/scripts/specs/arm/Xilinx.spec"),
         "-specs=nosys.specs", "-Wl,--gc-sections", "-Wl,-u,_vector_table",
         "-Wl,-Map," + str(out / "opna_ps.map"), "-Wl,-T," + str(SOURCE / "lscript.ld"),
         *objects, "-L", bsp / "lib", "-Wl,--start-group", "-lxil", "-lc", "-lgcc", "-Wl,--end-group",
         "-o", elf], out / "link.log", env)
    sections = elf_memory(elf, out, compiler_dir / "arm-none-eabi-readelf.exe", env)
    symbols = run([compiler_dir / "arm-none-eabi-nm.exe", elf], out / "elf-symbols.txt", env)
    for symbol in ("_vector_table", "_boot", "_start", "Xil_DCacheFlushRange", "Xil_DCacheInvalidateRange",
                   "Xil_ExceptionRegisterHandler", "XUsbPs_CfgInitialize", "XIicPs_MasterSendPolled"):
        if not re.search(r"\b" + symbol + r"$", symbols, re.MULTILINE):
            raise ValueError(f"Required real BSP/startup symbol missing: {symbol}")
    frequency = counter_frequency(gcc, include, out, env)
    music_input(out / "music_host.bin")
    host_elf = out / "host_contract.exe"
    run([host_cxx, "-std=c++17", "-O2", "-Wall", "-Wextra", "-DCOUNTS_PER_SECOND=" + str(frequency) + "ULL",
         "-I", ROOT / "software/ps_baremetal/tests/mock", ROOT / "software/ps_baremetal/tests/host_contract.cpp",
         "-o", host_elf], out / "host-compile.log", env)
    host = json.loads(run([host_elf, out / "music_host.bin"], out / "host-contract.json", env))
    if host["status"] != "passed" or host["board_verified"]:
        raise ValueError("PS execution contracts did not pass")
    with zipfile.ZipFile(xsa) as archive:
        has_bitstream = any(name.lower().endswith(".bit") for name in archive.namelist())
        (out / "ps7_init.tcl").write_bytes(archive.read("ps7_init.tcl"))
    return {"status": "通过", "board_verified": False, "xsa": str(xsa), "xsa_contains_bitstream": has_bitstream,
            "elf": str(elf), "elf_bytes": elf.stat().st_size, "counter_counts_per_second": frequency,
            "ps7_init": str(out / "ps7_init.tcl"),
            "sample_base": 0x01000000, "sample_bytes": 262144, "sample_physical_reservation_bytes": 524288,
            "event_buffer_bytes": 8388608, "elf_allocated_sections": sections, "host": host,
            "checks": ["fresh XSA BSP generation and real SDK build", "ARM application compile/link with real startup, IRQ/cache/USB/I2C drivers",
                       "all allocated ELF sections stay below native sample DDR", "fresh BSP COUNTS_PER_SECOND used in executed host contracts", *host["checks"]]}


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xsa", type=Path, default=DEFAULT_XSA)
    parser.add_argument("--out", type=Path, default=ROOT / "build/opna_phase7/board/software")
    parser.add_argument("--host-cxx", type=Path)
    args = parser.parse_args()
    try:
        result = build(args)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "result.json").write_text(json.dumps({"status": "未通过", "board_verified": False, "error": str(exc)}, ensure_ascii=False, indent=2), encoding="utf-8")
        raise
    (args.out / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "elf": result["elf"], "checks": len(result["checks"]), "board_verified": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
