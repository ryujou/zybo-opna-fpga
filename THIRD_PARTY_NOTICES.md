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

The PS7 and pin MIT notices are preserved in `hardware/vivado/LICENSE.digilent`. Vivado/Vitis SDK binaries and generated BSP libraries remain local build dependencies and are not included in the public repository. Digital board verification is recorded in `verification/phase-07/`. Analog audio has not been measured.

## USB MIDI firmware

`software/usb_midi` adapts the USB class transport and MIDI packet parser from [ryujou/zybo-opl3-fpga, usb-midi-opl3](https://github.com/ryujou/zybo-opl3-fpga/tree/usb-midi-opl3/software/usb_midi). The OPNA synthesis control uses [libOPNMIDI](https://github.com/Wohlstand/libOPNMIDI) pinned at `8e228213756f741533ef3f5d80cb7ec778479749`, under GPL-3.0-or-later with file-specific LGPL and MIT notices. Its sources and licenses are in the `third_party/libopnmidi` submodule. The build substitutes a hardware register backend; no software sound emulator is linked.

The embedded `fm_banks/xg.wopn` bank is Copyright 2018–2026 Vitaliy Novichkov, MIT; its complete notice is `third_party/libopnmidi/fm_banks/xg-readme.txt`. The MIDI application and its linked components are distributed under GPL-3.0-or-later, retaining these component notices.

The local hardware build contains the six fixed rhythm sounds described above. `firmware/usb_midi/BOOT.bin` includes that complete FPGA configuration; the MIDI application currently uses its six FM voices. Rhythm samples retain their original rights and are not relicensed as original project data.

Touhou test MIDI arrangements by Gyana Ren, based on music by ZUN, were obtained from [VGMusic's PC-98 directory](https://www.vgmusic.com/music/computer/nec/pc-98/). Test songs remain local and are not redistributed. The firmware contains the MIT instrument bank, not these songs.

## PMD desktop decoder

`third_party/98fmplayer` contains the PMD driver, OPNA timer/emulation sources and required headers from [myon98/98fmplayer](https://github.com/myon98/98fmplayer/tree/4fa914e4b2b994cb3ccf92d571a20a7cdf1fe36a), revision `4fa914e4b2b994cb3ccf92d571a20a7cdf1fe36a`, Copyright 2016 Takamichi Horikawa, BSD-2-Clause; the complete license is retained there. `tools/pmd_decode.c` records the driver register writes; the software audio output is discarded. Touhou PMD music remains local in ignored build directories and is not included in the public source.

## Browser player and software waveforms

`pc_player` adapts the project's Zybo OPL3 Vue/FastAPI player, retaining its source and runtime notices. The OPNA browser adapter uses the common PC98 parser and USB protocol. Bundled Windows x64 helpers in `pc_player/native/bin` are software display/PMD decoding components, not the board audio engine.

- `third_party/libvgm`: ValleyBell/libvgm, revision `c8b998b606895990c409a512b86c5509070f9f0d`. Core-specific licenses are retained in the submodule; the selected cores are MAME YM2608 and MAME AY8910. See its `README.md`, `emu/cores/fmopn.c` and `emu/cores/ay8910.c` for attribution and license terms.
- `third_party/zlib`: madler/zlib 1.2.11, revision `cacf7f1d4e3d44d871b605da3b647f07d718623f`, zlib license in `README` and `zlib.h`.
- `third_party/libadlmidi`: source snapshot of Wohlstand/libADLMIDI `84d27bc2bdbd6dd249537a7f7d2450cbd402482e`, with the existing OPL3 desktop observation hooks described in `LOCAL.txt`. GPL-3.0/LGPL-2.1 and core-specific notices are retained. Used only for OPL3/MIDI display support, not to render OPNA songs.
- `pc_player/libusb-1.0.dll`: libusb 1.0.24, LGPL-2.1-or-later. Source: https://github.com/libusb/libusb/tree/v1.0.24 ; full license is included in `pc_player/THIRD_PARTY.txt`.
- Vue, Python/FastAPI/Uvicorn and their dependencies retain their upstream licenses; versions are fixed in `pc_player/web/package-lock.json` and `pc_player/requirements.txt`. Qt and PyInstaller are not needed by the browser launcher.

Original VGM/VGZ/PMD music, ADPCM sample blocks, private reference renders and patched diagnostic songs are not distributed. The dual-mode FPGA image includes the fixed rhythm sounds under the same rights boundary described above.
