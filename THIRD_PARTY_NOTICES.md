# Third-party sources and assets

The project code uses GPL-3.0-or-later. Upstream code retains its own copyright notices and licenses; the project license does not grant rights to third-party ROM data, songs or samples.

| Component | Source and fixed version | License |
| --- | --- | --- |
| JT12 and the `jt12_opna` adaptation | [jotego/jt12](https://github.com/jotego/jt12), `dc9be7c1ff75d5b9a7f9d89da1b7fba212af1257`; Jose Tejada Gomez | GPL-3.0-or-later |
| JT49 and the OPNA SSG adaptation | [jotego/jt49](https://github.com/jotego/jt49), `7f6abfd08a2af9a92dbd5b32c71ea773248a77e2`; Jose Tejada Gomez | GPL-3.0-or-later |
| YM2608-LLE timing and digital arithmetic | [nukeykt/YM2608-LLE](https://github.com/nukeykt/YM2608-LLE), `7a2aca7b6830b96e48e3a4e1a40d15525993fa60`; Copyright 2023–2024 nukeykt | GPL-2.0-or-later |
| ymfm functional reference | [aaronsgiles/ymfm](https://github.com/aaronsgiles/ymfm), `81aec25ccbb98f4873a255f7551ac4dadac59b4a`; Copyright 2021 Aaron Giles | BSD-3-Clause |

The upstream license files are at `hardware/rtl/opna_core/jt12/LICENSE`, `hardware/rtl/opna_core/jt12/jt49/LICENSE`, `tools/opna_sim/vendor/ym2608_lle/LICENSE` and `tools/opna_sim/vendor/ymfm/LICENSE`. The JT12 submodule already pins the listed JT49 revision. The OPNA adaptations retain the original attribution; native control, rhythm and Delta-T behavior also derive from YM2608-LLE.

The six rhythm sounds use the 8192-byte `rss_rom` array in the pinned [YM2608-LLE `fmopna_rom.h`](https://github.com/nukeykt/YM2608-LLE/blob/7a2aca7b6830b96e48e3a4e1a40d15525993fa60/fmopna_rom.h). That data file has no separate sample-rights grant. The public repository supplies a local generator rather than embedding the rhythm data in project RTL. Generating the same bytes locally preserves the Phase 5 ROM comparison; it does not grant a project GPL license to the samples.

The Phase 6 music input is [Counterattack by MelonadeM](https://github.com/tildearrow/furnace/blob/v0.6.8.3/demos/pc98/Counterattack.fur), exported with the official [Furnace 0.6.8.3 console release](https://github.com/tildearrow/furnace/releases/tag/v0.6.8.3). Furnace's [demo rights notice](https://github.com/tildearrow/furnace/blob/v0.6.8.3/demos/README.md) reserves all rights to the original authors and excludes the songs from its GPL license. The public repository includes source metadata and a local preparation script; it does not distribute the song, exported VGM or ADPCM sample payload. The original first-second acceptance input remains the same song and sample bank.

After initializing the pinned submodules, run:

```powershell
py -3 -X utf8 scripts/prepare_reference_assets.py
```

The script downloads the official Windows console ZIP to `build/private-tools/furnace`, runs `furnace.exe -vgmout Counterattack.vgm Counterattack.fur`, and prepares the ignored local ROM and music paths expected by the gate. Use `--furnace <path-to-furnace.exe>` to use an existing official 0.6.8.3 console executable. Local retrieval and export do not grant redistribution or relicensing rights.

The public Phase 6 baseline contains the digital core and its simulation validation. It contains no OPL3 board integration reuse or Vivado/Vitis SDK binaries; board integration and physical verification remain Phase 7 work.
