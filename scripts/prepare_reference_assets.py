"""Prepare the private ROM and original music inputs used by the acceptance gate."""

import argparse
from pathlib import Path
import re
import subprocess
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]
FURNACE_URL = (
    "https://github.com/tildearrow/furnace/releases/download/v0.6.8.3/"
    "furnace-0.6.8.3-win64-console.zip"
)
SONG_URL = (
    "https://raw.githubusercontent.com/tildearrow/furnace/v0.6.8.3/"
    "demos/pc98/Counterattack.fur"
)


def prepare_assets(root, furnace=None):
    source = root / "tools/opna_sim/vendor/ym2608_lle/fmopna_rom.h"
    rom = bytes(int(value, 16) for value in
                re.findall(r"0x([0-9a-fA-F]{2})", source.read_text(encoding="utf-8")))
    if len(rom) != 8192:
        raise RuntimeError("The pinned YM2608-LLE rhythm ROM must contain 8192 bytes")
    target = root / "hardware/rtl/opna_core/jt10_opna_rom.sv"
    target.parent.mkdir(parents=True, exist_ok=True)
    chunks = [f"        128'h{rom[offset:offset + 16][::-1].hex()}"
              for offset in range(8176, -1, -16)]
    target.write_text(
        "// Generated locally from the pinned YM2608-LLE fmopna_rom.h.\n"
        "// This project does not grant a license to the rhythm sample data.\n"
        "// See THIRD_PARTY_NOTICES.md.\n"
        "package jt10_opna_rom;\n"
        "    localparam logic [65535:0] RHYTHM_ROM = {\n" +
        ",\n".join(chunks) + "\n    };\n"
        "    function automatic logic [7:0] rhythm_byte(input logic [12:0] address);\n"
        "        return RHYTHM_ROM[address * 8 +: 8];\n"
        "    endfunction\n"
        "endpackage\n", encoding="utf-8")

    if furnace is None:
        tool_dir = root / "build/private-tools/furnace"
        tool_dir.mkdir(parents=True, exist_ok=True)
        archive = tool_dir / "furnace-0.6.8.3-win64-console.zip"
        urllib.request.urlretrieve(FURNACE_URL, archive)
        with zipfile.ZipFile(archive) as package:
            package.extractall(tool_dir)
        furnace = tool_dir / "furnace.exe"
    else:
        furnace = Path(furnace).resolve()

    fixture = root / "tools/opna_sim/fixtures/counterattack"
    fixture.mkdir(parents=True, exist_ok=True)
    song = fixture / "Counterattack.fur"
    vgm = fixture / "Counterattack.vgm"
    urllib.request.urlretrieve(SONG_URL, song)
    subprocess.run([str(furnace), "-vgmout", str(vgm), str(song)], check=True)
    print(f"Local rhythm ROM: {target}")
    print(f"Local Counterattack input: {vgm}")
    print("ROM, song and sample rights remain with their respective rights holders.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--furnace", type=Path,
                        help="Use an existing official Furnace 0.6.8.3 console furnace.exe")
    args = parser.parse_args()
    prepare_assets(ROOT, args.furnace)
