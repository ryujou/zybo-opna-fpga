"""Build the pinned 98fmplayer PMD decoder with the installed Vivado MinGW."""
from pathlib import Path
import subprocess
import os

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "third_party/98fmplayer"
OUT = ROOT / "pc_player/native/bin"
OUT.mkdir(parents=True, exist_ok=True)
sources = [ROOT / "tools/pmd_decode.c",
           SOURCE / "fmdriver/fmdriver_pmd.c", SOURCE / "fmdriver/fmdriver_common.c"]
sources += sorted((SOURCE / "libopna").glob("*.c"))
subprocess.run([str(Path(os.environ.get("OPNA_VIVADO_ROOT", "J:/FPGA/2025.2/Vivado")) / "tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe"),
                "-std=c99", "-O2", "-I", str(SOURCE), *map(str, sources),
                "-lm", "-o", str(OUT / "pmd_decode.exe")], check=True)
