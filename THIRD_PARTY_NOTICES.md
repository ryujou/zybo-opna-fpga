# Third-party sources and assets

The project's digital core, tools and RTL adaptations use GPL-3.0-or-later. Files explicitly marked LGPL-3.0-or-later or MIT in the PS software retain those licenses. Upstream code retains its own copyright notices and licenses; the project license does not grant rights to third-party ROM data, songs or samples.

| Component | Source and fixed version | License |
| --- | --- | --- |
| JT12 and the `jt12_opna` adaptation | [jotego/jt12](https://github.com/jotego/jt12), `dc9be7c1ff75d5b9a7f9d89da1b7fba212af1257`; Jose Tejada Gomez | GPL-3.0-or-later |
| JT49 and the OPNA SSG adaptation | [jotego/jt49](https://github.com/jotego/jt49), `7f6abfd08a2af9a92dbd5b32c71ea773248a77e2`; Jose Tejada Gomez | GPL-3.0-or-later |
| YM2608-LLE timing and digital arithmetic | [nukeykt/YM2608-LLE](https://github.com/nukeykt/YM2608-LLE), `7a2aca7b6830b96e48e3a4e1a40d15525993fa60`; Copyright 2023–2024 nukeykt | GPL-2.0-or-later |
| ymfm functional reference | [aaronsgiles/ymfm](https://github.com/aaronsgiles/ymfm), `81aec25ccbb98f4873a255f7551ac4dadac59b4a`; Copyright 2021 Aaron Giles | BSD-3-Clause |
| PS USB, stream, codec and timer software | [ryujou/zybo-opl3-fpga](https://github.com/ryujou/zybo-opl3-fpga), `49b6efe07d79cb74856c7e70398dfcc612b101cf`; original file notices retained | LGPL-3.0-or-later; file-specific notices apply |
| Zybo Rev. B PS7 preset and pin constraints | [Digilent/vivado-boards](https://github.com/Digilent/vivado-boards/blob/master/new/board_files/zybo/B.3/preset.xml) and [Digilent/digilent-xdc](https://github.com/Digilent/digilent-xdc/blob/master/Zybo-Master.xdc); Copyright 2021 and 2017 Digilent, Inc. | MIT |

The upstream license files are at `hardware/rtl/opna_core/jt12/LICENSE`, `hardware/rtl/opna_core/jt12/jt49/LICENSE`, `tools/opna_sim/vendor/ym2608_lle/LICENSE` and `tools/opna_sim/vendor/ymfm/LICENSE`. The JT12 submodule already pins the listed JT49 revision. The OPNA adaptations retain the original attribution; native control, rhythm and Delta-T behavior also derive from YM2608-LLE.

The six rhythm sounds use the 8192-byte `rss_rom` array in the pinned [YM2608-LLE `fmopna_rom.h`](https://github.com/nukeykt/YM2608-LLE/blob/7a2aca7b6830b96e48e3a4e1a40d15525993fa60/fmopna_rom.h). That data file has no separate sample-rights grant. The public repository supplies a local generator rather than embedding the rhythm data in project RTL. Generating the same bytes locally preserves the Phase 5 ROM comparison; it does not grant a project GPL license to the samples.

The Phase 6 music input is [Counterattack by MelonadeM](https://github.com/tildearrow/furnace/blob/v0.6.8.3/demos/pc98/Counterattack.fur), exported with the official [Furnace 0.6.8.3 console release](https://github.com/tildearrow/furnace/releases/tag/v0.6.8.3). Furnace's [demo rights notice](https://github.com/tildearrow/furnace/blob/v0.6.8.3/demos/README.md) reserves all rights to the original authors and excludes the songs from its GPL license. The public repository includes source metadata and a local preparation script; it does not distribute the song, exported VGM or ADPCM sample payload. The original first-second acceptance input remains the same song and sample bank.

After initializing the pinned submodules, run:

```powershell
py -3 -X utf8 scripts/prepare_reference_assets.py
```

The script downloads the official Windows console ZIP to `build/private-tools/furnace`, runs `furnace.exe -vgmout Counterattack.vgm Counterattack.fur`, and prepares the ignored local ROM and music paths expected by the gate. Use `--furnace <path-to-furnace.exe>` to use an existing official 0.6.8.3 console executable. Local retrieval and export do not grant redistribution or relicensing rights.

The PS adaptation in `software/ps_baremetal` reuses only the stream parser, transport backends, USB descriptors/control requests, codec setup, SCU timer and linker script from the listed source. OPNA changes provide real IC reset and busy handling, full native DDR samples, a common timer frequency and 16-bit/48 kHz codec setup. The timer files retain Sam Bobrowicz / Copyright 2014 Digilent, Inc. attribution and the reference to the Xilinx SCU timer example. The linker script retains its AMD 2023 MIT notice. The original software license texts are in `software/ps_baremetal/LICENSES/`.

The PS7 and pin MIT notices are preserved in `hardware/vivado/LICENSE.digilent`. Vivado/Vitis SDK binaries and generated BSP libraries remain local build dependencies and are not included in the public repository. Physical verification remains pending.
