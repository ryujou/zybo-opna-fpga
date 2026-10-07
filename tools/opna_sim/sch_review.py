"""Reproduce SCH software differences; this does not pass or change a phase gate."""
import csv
import json
import subprocess
from urllib.request import urlopen

from gate import BUILD, COMPILER, ROOT, TOOL, Bus
from fm_cases import sch_cases

OUT = BUILD / "phase-03/software-review"
SOURCES = {
    "libvgm": ("ValleyBell/libvgm", "c8b998b606895990c409a512b86c5509070f9f0d", [
        "stdtype.h", "common_def.h", "_stdbool.h", "emu/snddef.h", "emu/EmuHelper.h", "emu/EmuStructs.h",
        "emu/logging.h", "emu/logging.c", "emu/cores/fmopn.c", "emu/cores/fmopn.h",
        "emu/cores/fmopn_2608rom.h", "emu/cores/ymdeltat.c", "emu/cores/ymdeltat.h"]),
    "pmdwin": ("pbarfuss/PMDWinS036", "fadd5a0e8482e277adbc9645411c97f8b8759b76", [
        "fmgen/opna.c", "fmgen/opna.h", "fmgen/op.h", "fmgen/psg.c", "fmgen/psg.h",
        "fmgen/e_expf.c", "fmgen/rhythmdata.c", "fmgen/rhythmdata.h"]),
    "libopna": ("myon98/98fmplayer", "4fa914e4b2b994cb3ccf92d571a20a7cdf1fe36a", [
        "libopna/opnafm.c", "libopna/opnafm.h", "libopna/opnatables.h", "libopna/opna.c"]),
    "np2kai": ("AZO234/NP2kai", "5939e0c6d5985c4c08fc70f289a83290e5d3e6f7", [
        "sound/opna.c", "sound/opngenc.c", "sound/opngeng.c", "cbus/board86.c",
        "sound/fmgen/fmgen_opna.cpp"]),
    "dosbox-x": ("joncampbell123/dosbox-x", "478c860050b20afdb58bce28f1b43163952fc541", [
        "src/hardware/snd_pc98/cbus/board86.c", "src/hardware/snd_pc98/sound/fmtimer.c",
        "src/hardware/snd_pc98/sound/opngenc.c", "src/hardware/snd_pc98/sound/opngeng.c"]),
    "libopnmidi": ("Wohlstand/libOPNMIDI", "8e228213756f741533ef3f5d80cb7ec778479749", [
        "src/chips/mame_opna.cpp", "src/chips/mamefm/fm.cpp"]),
}


def run(args, log):
    with log.open("w", encoding="utf-8") as output:
        subprocess.run([str(a) for a in args], check=True, cwd=ROOT,
                       stdout=output, stderr=subprocess.STDOUT)


def observations(path, start, end):
    with path.open(encoding="utf-8") as source:
        values = [int(r["value"]) for r in csv.DictReader(source)
                  if r["kind"] == "pcm" and start < int(r["tick"]) < end]
    if not values:
        raise RuntimeError(f"No observations: {path}, {start}..{end}")
    return {"samples": len(values), "nonzero": sum(v != 0 for v in values),
            "minimum": min(values), "maximum": max(values)}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    metadata = []
    for name, (repo, revision, files) in SOURCES.items():
        for file in files:
            target = OUT / name / file
            target.parent.mkdir(parents=True, exist_ok=True)
            with urlopen(f"https://raw.githubusercontent.com/{repo}/{revision}/{file}") as response:
                target.write_bytes(response.read())
        metadata.append(dict(name=name, repo=repo, revision=revision, files=files))
    (OUT / "sources.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    builds = {
        "libvgm": ("emu/cores", ["emu/cores/fmopn.c", "emu/cores/ymdeltat.c", "emu/logging.c"],
                   ["-DSNDDEV_SELECT", "-DSNDDEV_YM2608"]),
        "pmdwin": ("fmgen", [f"fmgen/{n}.c" for n in ("opna", "psg", "e_expf", "rhythmdata")], ["-fwrapv"]),
        "libopna": ("libopna", ["libopna/opnafm.c"], []),
    }
    for name, (include, files, flags) in builds.items():
        run([COMPILER / "gcc.exe", "-std=gnu99", "-O2", "-static", f"-DPROBE_{name.upper()}",
             *flags, "-I", OUT / name / include, TOOL / "sch_software_probe.c",
             *(OUT / name / f for f in files), "-lm", "-o", OUT / f"{name}.exe"],
            OUT / f"{name}-build.log")

    probes = {}
    for name, (bus, _) in sch_cases(Bus).items():
        label = "running_clear" if name == "sch_high_channel" else name.removeprefix("sch_")
        probes[label] = (bus, {window: bounds[:2] for window, bounds in bus.fm_windows.items()})

    report = {"scope": "SCH functional activity only; not cycle/sample equivalence or chip verification",
              "phase_gate_changed": False, "cases": {}}
    for case, (bus, windows) in probes.items():
        stimulus = OUT / f"{case}.bus"
        bus.save(stimulus, tail=4096)
        result = {"windows": windows, "models": {}}
        for model in (*builds, "lle", "ymfm"):
            output = OUT / f"{case}-{model}.csv"
            if model in builds:
                command = [OUT / f"{model}.exe", stimulus, output]
            else:
                command = [BUILD / "phase-01/reference.exe", model, stimulus,
                           BUILD / "phase-01/samples.mem", output]
            run(command, OUT / f"{case}-{model}.log")
            result["models"][model] = {name: observations(output, *bounds)
                                        for name, bounds in windows.items()}
        report["cases"][case] = result
    (OUT / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for case, result in report["cases"].items():
        print(case, {model: {w: bool(stats["nonzero"]) for w, stats in windows.items()}
                     for model, windows in result["models"].items()})


if __name__ == "__main__":
    main()
