import argparse
import csv
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from itertools import groupby
from control_cases import cases as control_cases
from fm_cases import cases as fm_cases
from ssg_cases import cases as ssg_cases
from adpcm_cases import cases as adpcm_cases
from acceptance_cases import cases as acceptance_cases
from parallel import run_xsim_cases

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools/opna_sim"
BUILD = ROOT / "build/opna_sim"
VIVADO_ROOT = Path(os.environ.get("OPNA_VIVADO_ROOT", "J:/FPGA/2025.2/Vivado"))
COMPILER = VIVADO_ROOT / "tps/mingw/10.0.0/win64.o/nt/bin"
VIVADO = VIVADO_ROOT / "bin"
FRESH_REPORTS = {}


def run(args, log, cwd=ROOT, expected_exit=0):
    command = [str(a) for a in args]
    if command[0].endswith(".bat"):
        # CMD otherwise splits the '=' in XSim plusargs passed through loader.bat.
        command = " ".join('"' + arg + '"' for arg in command)
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run(command, cwd=cwd, stdout=output,
                                stderr=subprocess.STDOUT)
    if result.returncode != expected_exit:
        raise RuntimeError(f"command failed ({result.returncode}): {log}")


def rows(path):
    with path.open(encoding="utf-8") as src:
        records = list(csv.DictReader(src))
    if not records:
        raise RuntimeError(f"empty observations: {path}")
    return [(int(r["tick"]), r["kind"], int(r["index"]), int(r["value"])) for r in records]


class Bus:
    def __init__(self):
        self.events = [(0, 1, 1, 1, 1, 0, 0), (1152, 0, 1, 1, 1, 0, 0),
                       (2304, 1, 1, 1, 1, 0, 0)]
        self.tick = 3456

    def write(self, address, data):
        self.events += [(self.tick, 1, 0, 0, 1, address, data),
                        (self.tick + 32, 1, 1, 1, 1, address, data)]
        self.tick += 64

    def reg(self, register, data, port=0):
        self.write(port * 2, register)
        self.write(port * 2 + 1, data)
        self.tick += 384

    def read(self, address):
        self.events += [(self.tick, 1, 0, 1, 0, address, 0),
                        (self.tick + 64, 1, 1, 1, 1, address, 0)]
        self.tick += 128

    def save(self, path, tail=1024):
        path.write_text(str(self.tick + tail) + "\n" +
                        "".join(" ".join(map(str, e)) + "\n" for e in self.events),
                        encoding="utf-8")


def compile_reference(out):
    vendor = TOOL / "vendor"
    lle = vendor / "ym2608_lle"
    ymfm = vendor / "ymfm/src"
    run([COMPILER / "gcc.exe", "-O2", "-c", lle / "fmopna_2608.c",
         "-o", out / "lle.o"], out / "compile-lle.log")
    manual_source = (lle / "fmopna_impl.c").read_text(encoding="utf-8")
    zero_lle = "chip->lfo_cnt_rst = chip->lfo_mode ? chip->ad_ad_quiet :"
    if manual_source.count(zero_lle) != 1:
        raise RuntimeError("ZERO manual reference patch does not match pinned LLE")
    manual_source = manual_source.replace(zero_lle,
        "chip->lfo_cnt_rst = chip->lfo_mode ? !chip->ad_ad_quiet :")
    (out / "lle-zero-manual.c").write_text(
        "#define FMOPNA_YM2608\n#define FMOPNA_Clock FMOPNA_ClockZeroManual\n" + manual_source,
        encoding="utf-8")
    run([COMPILER / "gcc.exe", "-O2", "-I", lle, "-c", out / "lle-zero-manual.c",
         "-o", out / "lle-zero-manual.o"], out / "compile-lle-zero-manual.log")
    sources = [ymfm / f"ymfm_{name}.cpp" for name in ("opn", "adpcm", "ssg")]
    run([COMPILER / "g++.exe", "-std=c++14", "-O2", "-static",
         "-I", ymfm, "-I", lle, TOOL / "reference.cpp", *sources,
         out / "lle.o", out / "lle-zero-manual.o", "-o", out / "reference.exe"], out / "compile-reference.log")


def phase1_a(out, checks):
    pins = json.loads((TOOL / "sources.json").read_text(encoding="utf-8"))
    for name, source in pins.items():
        path = ROOT / source["path"]
        revision = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"],
                                           text=True).strip()
        modified = subprocess.check_output(
            ["git", "-C", str(path), "status", "--porcelain", "--untracked-files=normal"], text=True)
        if revision != source["revision"] or modified.strip() or not (path / "LICENSE").is_file():
            raise RuntimeError(f"source version/license mismatch: {name}")
    checks.append("source_versions")
    compile_reference(out)
    memory = out / "samples.mem"
    memory.write_text("16 170\n17 85\n", encoding="utf-8")
    bus = Bus()
    bus.write(0, 8)
    bus.read(1)
    bus.reg(8, 15)
    bus.write(0, 8)
    bus.read(1)
    bus.save(out / "register.bus")
    for model in ("lle", "ymfm"):
        output = out / f"register-{model}.csv"
        run([out / "reference.exe", model, out / "register.bus", memory, output],
            out / f"register-{model}.log")
        reads = [r[3] for r in rows(output) if r[1] == "read"]
        if reads != [0, 15]:
            raise RuntimeError(f"{model}: SSG register read expected [0, 15], got {reads}")
        checks.append(f"{model}_reset_and_read")


def phase1_b(out, checks):
    bus = Bus()
    bus.reg(0x29, 0x9f)
    bus.reg(7, 0x3e)
    bus.reg(0, 32)
    bus.reg(1, 0)
    bus.reg(8, 15)
    for offset in (0, 8, 4, 12):
        for base, value in ((0x30, 1), (0x40, 0), (0x50, 31),
                            (0x60, 0), (0x70, 0), (0x80, 15)):
            bus.reg(base + offset, value)
    bus.reg(0xb0, 7)
    bus.reg(0xb4, 0xc0)
    bus.reg(0xa4, 0x22)
    bus.reg(0xa0, 0x69)
    bus.reg(0x28, 0xf0)
    bus.save(out / "tone.bus", tail=120000)
    for model in ("lle", "ymfm"):
        output = out / f"tone-{model}.csv"
        run([out / "reference.exe", model, out / "tone.bus", out / "samples.mem", output],
            out / f"tone-{model}.log")
        observations = rows(output)
        active = [r for r in observations if r[0] > bus.tick and r[1] == "pcm" and r[3] != 0]
        ssg_kind = "ssg" if model == "lle" else "ssg_pcm"
        ssg = {r[3] for r in observations if r[1] == ssg_kind}
        busy = {r[3] for r in observations if r[1] == "busy"}
        if len(active) < 100 or len({r[3] for r in active}) < 16 or len(ssg) < 2 or busy != {0, 1}:
            raise RuntimeError(f"{model}: inactive reference output")
        checks.append(f"{model}_active_fm_ssg_busy")
    for label, pan, active_channel in (("left", 0x80, 0), ("right", 0x40, 1)):
        panned = Bus()
        panned.events = []
        selected = None
        for event in bus.events:
            event = list(event)
            if event[2:5] == [0, 0, 1] and event[5] == 0:
                selected = event[6]
            if selected == 0xb4 and event[5] == 1:
                event[6] = pan
            panned.events.append(tuple(event))
        panned.tick = bus.tick
        stimulus = out / f"pan-{label}.bus"
        panned.save(stimulus, tail=12000)
        for model in ("lle", "ymfm"):
            output = out / f"pan-{label}-{model}.csv"
            run([out / "reference.exe", model, stimulus, out / "samples.mem", output],
                out / f"pan-{label}-{model}.log")
            active = {row[2] for row in rows(output) if row[0] > bus.tick and
                      row[1] == "pcm" and row[3] != 0}
            if active != {active_channel}:
                raise RuntimeError(f"native channel mapping: {label}/{model} has active channels {active}")
            checks.append(f"{model}_native_pan_{label}")
    jt = ROOT / "hardware/rtl/opna_core/jt12"
    sources = sorted((jt / "hdl").glob("*.v"))
    sources += sorted((jt / "hdl/adpcm").glob("*.v"))
    sources += sorted((jt / "jt49/hdl").glob("*.v"))
    sources += [ROOT / "hardware/sim/tb_opna_trace_replay.sv"]
    run([VIVADO / "xvlog.bat", "--sv", *sources], out / "xvlog-console.log", out)
    run([VIVADO / "xelab.bat", "tb_opna_trace_replay", "-s", "opna_replay",
         "--debug", "typical", "--timescale", "1ns/1ps"], out / "xelab-console.log", out)
    run([VIVADO / "xsim.bat", "opna_replay", "-runall",
         "-testplusarg", "TRACE=register.bus",
         "-testplusarg", "OUTPUT=."], out / "xsim-console.log", out)
    if "OPNA_REPLAY_PASS" not in (out / "xsim-console.log").read_text(encoding="utf-8"):
        raise RuntimeError("XSim did not reach replay completion")
    if (out / "register.bus").read_text() != (out / "replayed.bus").read_text():
        raise RuntimeError("XSim pin replay mismatch")
    expected_reads = [(r[0], r[2]) for r in rows(out / "register-lle.csv") if r[1] == "read"]
    actual_reads = [tuple(map(int, line.split(",")))
                    for line in (out / "read-ticks.csv").read_text().splitlines()]
    if expected_reads != actual_reads:
        raise RuntimeError("XSim read sampling edge mismatch")
    checks.append("xsim_vendor_elaboration_and_edge_replay")


def comparison(out, name, expected, actual, stimulus, equal):
    log = out / f"{name}.json"
    run([sys.executable, "-X", "utf8", TOOL / "compare.py", expected, actual,
         "--stimulus", stimulus], log, expected_exit=0 if equal else 1)
    result = json.loads(log.read_text(encoding="utf-8"))
    if result["equal"] != equal or (not equal and not result["input_context"]):
        raise RuntimeError(f"comparator did not produce expected evidence: {name}")


def phase1_c(out, checks):
    for case in ("register", "tone"):
        for model in ("lle", "ymfm"):
            repeat = out / f"{case}-{model}-repeat.csv"
            run([out / "reference.exe", model, out / f"{case}.bus", out / "samples.mem", repeat],
                out / f"{case}-{model}-repeat.log")
            comparison(out, f"repeat-{case}-{model}", out / f"{case}-{model}.csv",
                       repeat, out / f"{case}.bus", True)
            checks.append(f"repeat_{case}_{model}")

    original = (out / "register.bus").read_text(encoding="utf-8").splitlines()
    events = [list(map(int, line.split())) for line in original[1:]]
    dropped = [event[:] for event in events]
    write = next(event for event in dropped if event[2:5] == [0, 0, 1] and
                 event[5:] == [1, 15])
    write[2] = write[3] = 1
    shifted = [event[:] for event in events]
    read_start = max(i for i, event in enumerate(shifted) if event[2:5] == [0, 1, 0])
    shifted[read_start][0] += 2
    shifted[read_start + 1][0] += 2
    for name, altered in (("dropped-write", dropped), ("shifted-clock", shifted)):
        path = out / f"{name}.bus"
        path.write_text(original[0] + "\n" +
                        "".join(" ".join(map(str, event)) + "\n" for event in altered),
                        encoding="utf-8")
        for model in ("lle", "ymfm"):
            actual = out / f"{name}-{model}.csv"
            run([out / "reference.exe", model, path, out / "samples.mem", actual],
                out / f"{name}-{model}.log")
            comparison(out, f"reject-{name}-{model}", out / f"register-{model}.csv",
                       actual, path, False)
            checks.append(f"reject_{name}_{model}")
    for model in ("lle", "ymfm"):
        samples = rows(out / f"tone-{model}.csv")
        index = next(i for i, row in enumerate(samples)
                     if row[0] > 30000 and row[1] == "pcm" and row[3] != 0)
        tick, kind, channel, value = samples[index]
        samples[index] = (tick, kind, channel, value + 1)
        actual = out / f"altered-sample-{model}.csv"
        with actual.open("w", newline="", encoding="utf-8") as dst:
            writer = csv.writer(dst)
            writer.writerow(("tick", "kind", "index", "value"))
            writer.writerows(samples)
        comparison(out, f"reject-altered-sample-{model}", out / f"tone-{model}.csv",
                   actual, out / "tone.bus", False)
        checks.append(f"reject_altered_sample_{model}")


def set_step(phase, step, status, evidence):
    doc = ROOT / f"docs/phases/phase-{phase:02}.md"
    text = doc.read_text(encoding="utf-8")
    replacement = f"| {step} | {status} | {evidence} |"
    text, count = re.subn(rf"^\| {step} \|.*$", lambda _: replacement, text, flags=re.M)
    if count != 1:
        raise RuntimeError(f"missing step {step} in {doc}")
    doc.write_text(text, encoding="utf-8")


def require_pass(phase, step):
    report_path = BUILD / f"phase-{phase:02}/gate-{step}.json"
    document = ROOT / f"docs/phases/phase-{phase:02}.md"
    if not report_path.exists() or not document.exists():
        raise RuntimeError(f"Phase {phase} {step} prerequisite has not passed")
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if report.get("status") != "通过" or not re.search(
            rf"^\| {step} \| 通过 \|", document.read_text(encoding="utf-8"), re.M):
        raise RuntimeError(f"Phase {phase} {step} prerequisite has not passed")


def phase1_d(out, checks):
    phase_doc = (ROOT / "docs/phases/phase-01.md").read_text(encoding="utf-8")
    for section in ("## 输入与时间", "## 输出约定", "## 必需检查", "## 实现与证据", "## 限制"):
        if section not in phase_doc:
            raise RuntimeError(f"missing Phase 1 documentation: {section}")
    roadmap = (ROOT / "docs/todo.md").read_text(encoding="utf-8")
    for feature in ("BUS", "CLK", "TIM", "FM", "EG", "MOD", "SCH", "SSG", "RHY", "ADP", "STA", "MIX", "RUN", "BOARD"):
        if f"| {feature} |" not in roadmap:
            raise RuntimeError(f"missing feature checklist entry: {feature}")
    required = {"source_versions", "xsim_vendor_elaboration_and_edge_replay"}
    for model in ("lle", "ymfm"):
        required.update({f"{model}_reset_and_read", f"{model}_active_fm_ssg_busy",
                         f"{model}_native_pan_left", f"{model}_native_pan_right",
                         f"repeat_register_{model}", f"repeat_tone_{model}",
                         f"reject_dropped-write_{model}", f"reject_shifted-clock_{model}",
                         f"reject_altered_sample_{model}"})
    if set(checks) != required:
        raise RuntimeError("Phase 1 required checks missing")
    checks.append("documentation_and_feature_checklist")


class GateFailure(RuntimeError):
    def __init__(self, phase, step, error):
        super().__init__(str(error))
        self.phase, self.step = phase, step


def checked_step(phase, step, function, out, checks):
    try:
        function(out, checks)
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        report = {"phase": phase, "step": step, "status": "未通过",
                  "checks": list(checks), "error": str(error)}
        (out / f"gate-{step}.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        set_step(phase, step, "未通过", f"[失败结果](../../build/opna_sim/phase-{phase:02}/gate-{step}.json)")
        invalidate_later(phase, step)
        raise GateFailure(phase, step, error) from error
    report = {"phase": phase, "step": step, "status": "通过", "checks": list(checks)}
    FRESH_REPORTS[phase, step] = report
    (out / f"gate-{step}.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    set_step(phase, step, "通过", f"[检查结果](../../build/opna_sim/phase-{phase:02}/gate-{step}.json)")


def execute_phase1(step, out, checks):
    for current, function in zip("ABCD", (phase1_a, phase1_b, phase1_c, phase1_d)):
        if current <= step:
            checked_step(1, current, function, out, checks)


def phase2_a(out, checks):
    executable = BUILD / "phase-01/reference.exe"
    memory = BUILD / "phase-01/samples.mem"
    for name, (bus, expected) in control_cases(Bus).items():
        stimulus = out / f"{name}.bus"
        bus.save(stimulus, tail=2048)
        models = ("lle-control",) if name in ("prescaler", "channel_mode", "bank_isolation") else ("lle-control", "ymfm")
        for model in models:
            output = out / f"{name}-{model}.csv"
            run([executable, model, stimulus, memory, output], out / f"{name}-{model}.log")
            observed = rows(output)
            reads = [r[3] for r in observed if r[1] == "read"]
            # ymfm stores raw SSG bytes; this documented model limitation is not
            # the hardware readback contract (which still uses the LLE masks).
            model_expected = expected
            if model == "ymfm":
                if name == "ssg_masks":
                    model_expected = [255] * len(expected)
                elif name == "flag_control":
                    model_expected = [1, 1, 0]  # Low status read omits flag mask in ymfm.
                elif name == "status_read_hold":
                    model_expected = [1, 1]  # Software read API has no held RD pin.
            if reads != model_expected:
                raise RuntimeError(f"{name}/{model}: expected reads {model_expected}, got {reads}")
            if model == "lle-control":
                control = [row for row in observed if row[0] >= 3456 and
                           row[1] in ("read", "irq", "busy", "mode", "timer")]
                with (out / f"{name}-expected.csv").open("w", newline="", encoding="utf-8") as dst:
                    writer = csv.writer(dst)
                    writer.writerow(("tick", "kind", "index", "value"))
                    writer.writerows(control)
                if name == "prescaler":
                    values = [row[3] for row in observed if row[0] > 3456 and row[1:3] == ("mode", 0)]
                    if values != [0, 2, 3, 0, 2]:
                        raise RuntimeError(f"prescaler address-only side effect: {values}")
                if name == "channel_mode":
                    values = [row[3] for row in observed if row[0] > 3456 and row[1:3] == ("mode", 1)]
                    if values != [1, 0]:
                        raise RuntimeError(f"SCH transition mismatch: {values}")
                if name == "bank_isolation" and any(
                        row[0] > 3456 and row[1] == "mode" for row in observed):
                    raise RuntimeError("high bank modified low-bank control")
            if name in ("timer_a", "timer_b", "irq_mask") and not any(
                    row[1] == "irq" and row[3] == 1 for row in observed):
                raise RuntimeError(f"{name}/{model}: IRQ did not assert")
        checks.append(f"reference_{name}")
    for timer, period in ((0, 288), (1, 4608)):
        name = "timer_a" if timer == 0 else "timer_b"
        edges = [r[0] for r in rows(out / f"{name}-lle-control.csv")
                 if r[1:] == ("timer", timer, 1)]
        if len(edges) < 2 or any(b - a != period for a, b in zip(edges, edges[1:])):
            raise RuntimeError(f"{name}: default prescaler overflow period differs from {period} half-clocks")
    checks.append("default_timer_periods")


def phase2_b(out, checks):
    sources = [ROOT / f"hardware/rtl/opna_core/{name}.sv"
               for name in ("jt49_opna", "jt10_opna_rom", "jt10_opna_rhythm", "jt10_opna_adpcm", "ym2608_control", "ym2608")]
    sources.append(ROOT / "hardware/sim/tb_ym2608_control.sv")
    run([VIVADO / "xvlog.bat", "--sv", *sources], out / "xvlog-console.log", out)
    run([VIVADO / "xelab.bat", "tb_ym2608_control", "-s", "opna_control",
         "--debug", "typical", "--timescale", "1ns/1ps"], out / "xelab-console.log", out)
    checks.append("control_rtl_elaboration")
    failures = []
    for name in control_cases(Bus):
        run([VIVADO / "xsim.bat", "opna_control", "-runall",
             "-testplusarg", f"TRACE={name}.bus", "-testplusarg", f"OUTPUT={name}-rtl.csv"],
            out / f"{name}-xsim.log", out)
        if "YM2608_CONTROL_PASS" not in (out / f"{name}-xsim.log").read_text(encoding="utf-8"):
            raise RuntimeError(f"XSim did not complete {name}")
        try:
            comparison(out, f"compare-{name}", out / f"{name}-expected.csv",
                       out / f"{name}-rtl.csv", out / f"{name}.bus", True)
            checks.append(f"rtl_{name}")
        except RuntimeError:
            failures.append(name)
    if failures:
        raise RuntimeError(f"RTL control differences: {', '.join(failures)}; see compare-*.json")


def phase2_c(out, checks):
    for name in ("bus_phase_sweep", "timers_prescaler"):
        run([VIVADO / "xsim.bat", "opna_control", "-runall",
             "-testplusarg", f"TRACE={name}.bus", "-testplusarg", "IDLE=3",
             "-testplusarg", f"OUTPUT={name}-paused-rtl.csv"], out / f"{name}-paused-xsim.log", out)
        if "YM2608_CONTROL_PASS" not in (out / f"{name}-paused-xsim.log").read_text(encoding="utf-8"):
            raise RuntimeError(f"XSim did not complete paused {name}")
        comparison(out, f"compare-paused-{name}", out / f"{name}-expected.csv",
                   out / f"{name}-paused-rtl.csv", out / f"{name}.bus", True)
        checks.append(f"clock_enable_{name}")


def phase2_d(out, checks):
    required = {"phase1_cumulative_regression", "default_timer_periods", "control_rtl_elaboration",
                "clock_enable_bus_phase_sweep", "clock_enable_timers_prescaler"}
    for name in control_cases(Bus):
        required.update((f"reference_{name}", f"rtl_{name}"))
    if set(checks) != required:
        raise RuntimeError("Phase 2 required checks missing")
    document = (ROOT / "docs/phases/phase-02.md").read_text(encoding="utf-8")
    for section in ("参考模型差异的裁决", "必需用例", "实现与证据", "当前结论"):
        if section not in document:
            raise RuntimeError(f"missing Phase 2 documentation: {section}")
    checks.append("phase2_documentation_and_evidence")


def execute_phase2(step, out, checks):
    for current, function in zip("ABCD", (phase2_a, phase2_b, phase2_c, phase2_d)):
        if current <= step:
            checked_step(2, current, function, out, checks)


def phase3_a(out, checks):
    executable = BUILD / "phase-01/reference.exe"
    memory = BUILD / "phase-01/samples.mem"
    sch_report = {"reference": "lle", "decision": "SCH-LLE-2026-10-07",
                  "chip_verified": False, "cases": {}}
    for name, (bus, active_channels) in fm_cases(Bus).items():
        stimulus = out / f"{name}.bus"
        bus.save(stimulus, tail=4096)
        observations = {}
        for model in ("lle", "ymfm"):
            output = out / f"{name}-{model}.csv"
            reference_model = "lle-control" if model == "lle" else model
            run([executable, reference_model, stimulus, memory, output], out / f"{name}-{model}.log")
            pcm = [row for row in rows(output) if row[0] >= 3456 and row[1] == "pcm"]
            if not pcm or any(not -32768 <= row[3] <= 32767 for row in pcm):
                raise RuntimeError(f"invalid FM reference samples: {name}/{model}")
            windows = getattr(bus, "fm_windows", {
                "whole": (3455, bus.tick + 4096, {"lle": active_channels, "ymfm": active_channels})})
            observations[model] = {}
            for window, (start, end, expected) in windows.items():
                channels = {}
                for channel in (0, 1):
                    values = [row[3] for row in pcm if start < row[0] < end and row[2] == channel]
                    if not values or any(value != 0 for value in values) != bool(expected[model] & (1 << channel)):
                        raise RuntimeError(f"FM activity/pan mismatch: {name}/{model}/{window}/channel{channel}")
                    channels[channel] = {"samples": len(values), "nonzero": sum(value != 0 for value in values)}
                observations[model][window] = {"expected_mask": expected[model], "channels": channels}
            if model == "lle":
                with (out / f"{name}-expected.csv").open("w", newline="", encoding="utf-8") as dst:
                    writer = csv.writer(dst)
                    writer.writerow(("tick", "kind", "index", "value"))
                    writer.writerows(row for row in rows(output) if row[0] >= 3456 and
                                     row[1] in ("pcm", "read", "irq", "busy", "mode", "timer"))
            checks.append(f"fm_reference_{name}_{model}")
        if hasattr(bus, "fm_windows"):
            sch_report["cases"][name] = {"windows": bus.fm_windows, "observations": observations}
            checks.append(f"sch_contract_{name}")
    (out / "sch-contract.json").write_text(json.dumps(sch_report, indent=2) + "\n", encoding="utf-8")


def require_sim_completion(log, case):
    output = log.read_text(encoding="utf-8")
    if "YM2608_CONTROL_PASS" not in output:
        reason = next((line for line in output.splitlines() if line.startswith("Fatal:")),
                      "completion marker missing")
        raise RuntimeError(f"{case}: {reason}; {log}")


def compile_audio(out, snapshot, ssg=False, rhythm=False, adpcm=False):
    jt = ROOT / "hardware/rtl/opna_core/jt12"
    sources = sorted((jt / "hdl").glob("*.v")) + sorted((jt / "hdl/adpcm").glob("*.v"))
    adapted = ("jt12_reg", "jt12_top", "jt12_kon", "jt12_mmr", "jt12_mod", "jt12_csr", "jt12_pg", "jt12_eg",
               "jt12_eg_ctrl", "jt12_eg_pure", "jt12_eg_comb", "jt12_eg_step", "jt12_eg_final",
               "jt12_op", "jt12_logsin")
    sources = [source for source in sources if source.stem not in adapted]
    sources += [ROOT / f"hardware/rtl/opna_core/jt12_opna/{name}.v" for name in adapted]
    sources += sorted((jt / "jt49/hdl").glob("*.v"))
    run([VIVADO / "xvlog.bat", *sources], out / "xvlog-jt12-console.log", out)
    sources = [ROOT / f"hardware/rtl/opna_core/{name}.sv" for name in
               ("jt49_opna", "jt10_opna_rom", "jt10_opna_rhythm", "jt10_opna_adpcm", "ym2608_control", "ym2608")]
    sources.append(ROOT / "hardware/sim/tb_ym2608_control.sv")
    run([VIVADO / "xvlog.bat", "--sv", *sources], out / "xvlog-console.log", out)
    generics = ["-generic_top", "FM=1"]
    if ssg:
        generics += ["-generic_top", "SSG=1"]
    if rhythm:
        generics += ["-generic_top", "RHYTHM=1"]
    if adpcm:
        generics += ["-generic_top", "ADPCM=1"]
    run([VIVADO / "xelab.bat", "tb_ym2608_control", *generics,
         "-s", snapshot, "--debug", "typical", "--timescale", "1ns/1ps"], out / "xelab-console.log", out)


def phase3_b(out, checks):
    compile_audio(out, "opna_fm")
    checks.append("fm_rtl_elaboration")
    names = tuple(fm_cases(Bus))
    run_xsim_cases(out, [([VIVADO / "xsim.bat", "opna_fm", "-runall", "-testplusarg", f"TRACE={name}.bus",
                          "-testplusarg", f"OUTPUT={name}-rtl.csv"], out / f"{name}-xsim.log")
                         for name in names])
    failures = []
    for name in names:
        require_sim_completion(out / f"{name}-xsim.log", name)
        try:
            comparison(out, f"compare-{name}", out / f"{name}-expected.csv",
                       out / f"{name}-rtl.csv", out / f"{name}.bus", True)
            checks.append(f"fm_rtl_{name}")
        except RuntimeError:
            failures.append(name)
    if failures:
        raise RuntimeError(f"FM RTL differences: {', '.join(failures)}; see compare-*.json")


FM_PAUSED_CASES = ("six_channels_slots", "lfo_am_pm", "dynamic_writes_keys", "fm_reset_phase_011")


def phase3_c(out, checks):
    run_xsim_cases(out, [([VIVADO / "xsim.bat", "opna_fm", "-runall",
                          "-testplusarg", f"TRACE={name}.bus", "-testplusarg", "IDLE=3",
                          "-testplusarg", f"OUTPUT={name}-paused-rtl.csv"], out / f"{name}-paused-xsim.log")
                         for name in FM_PAUSED_CASES])
    for name in FM_PAUSED_CASES:
        require_sim_completion(out / f"{name}-paused-xsim.log", f"paused {name}")
        comparison(out, f"compare-paused-{name}", out / f"{name}-expected.csv",
                   out / f"{name}-paused-rtl.csv", out / f"{name}.bus", True)
        checks.append(f"fm_clock_enable_{name}")


def phase3_d(out, checks):
    required = {"phase1_cumulative_regression", "phase2_cumulative_regression", "fm_rtl_elaboration"}
    for name, (bus, _) in fm_cases(Bus).items():
        required.update((f"fm_reference_{name}_lle", f"fm_reference_{name}_ymfm", f"fm_rtl_{name}"))
        if hasattr(bus, "fm_windows"):
            required.add(f"sch_contract_{name}")
        evidence = json.loads((out / f"compare-{name}.json").read_text(encoding="utf-8"))
        if not evidence.get("equal") or evidence.get("observations") != len(rows(out / f"{name}-rtl.csv")):
            raise RuntimeError(f"missing complete FM comparison evidence: {name}")
        require_sim_completion(out / f"{name}-xsim.log", name)
    required.update(f"fm_clock_enable_{name}" for name in FM_PAUSED_CASES)
    if set(checks) != required:
        raise RuntimeError("Phase 3 required checks missing")
    require_pass(3, "B")
    require_pass(3, "C")
    document = (ROOT / "docs/phases/phase-03.md").read_text(encoding="utf-8")
    for section in ("步骤门控", "必需用例", "实现与证据", "SCH工程契约", "当前结论"):
        if section not in document:
            raise RuntimeError(f"missing Phase 3 documentation: {section}")
    checks.append("phase3_documentation_and_evidence")


def execute_phase3(step, out, checks):
    for current, function in zip("ABCD", (phase3_a, phase3_b, phase3_c, phase3_d)):
        if current <= step:
            checked_step(3, current, function, out, checks)


def ssg_window_values(observations, start, end):
    state = [None] * 3
    for tick, kind, channel, value in observations:
        if kind == "ssg" and tick < start:
            state[channel] = value
    values = [[value] if value is not None else [] for value in state]
    for tick, kind, channel, value in observations:
        if kind == "ssg" and start <= tick < end:
            values[channel].append(value)
    return values


def phase4_a(out, checks):
    executable = BUILD / "phase-01/reference.exe"
    memory = BUILD / "phase-01/samples.mem"
    for name, bus in ssg_cases(Bus).items():
        stimulus = out / f"{name}.bus"
        bus.save(stimulus, tail=4096)
        for model in ("lle", "ymfm"):
            output = out / f"{name}-{model}.csv"
            run([executable, "lle-control" if model == "lle" else model,
                 stimulus, memory, output], out / f"{name}-{model}.log")
            observed = rows(output)
            reads = [r[3] for r in observed if r[1] == "read"]
            expected = bus.ssg_reads if model == "lle" else bus.ymfm_reads
            if reads != expected:
                raise RuntimeError(f"SSG readback mismatch: {name}/{model}: {reads} != {expected}")
            if name.startswith("fm_ssg_"):
                for start, end, _, _ in bus.ssg_windows:
                    for channel in (0, 1):
                        pcm = [r[3] for r in observed if start <= r[0] < end and
                               r[1] == "pcm" and r[2] == channel]
                        if not pcm or not any(pcm) or len(set(pcm)) < 2:
                            raise RuntimeError(f"inactive parallel FM: {name}/{model}/{start}/{channel}")
            if model == "lle":
                levels = [r for r in observed if r[0] >= 3456 and r[1] == "ssg"]
                if {r[2] for r in levels} != {0, 1, 2} or any(not 0 <= r[3] <= 31 for r in levels):
                    raise RuntimeError(f"invalid native SSG outputs: {name}")
                for start, end, kind, expectation in bus.ssg_windows:
                    values = ssg_window_values(observed, start, end)
                    if kind == "constant" and any(set(v) != {e} for v, e in zip(values, expectation)):
                        raise RuntimeError(f"SSG fixed level mismatch: {name}/{start}: {values}")
                    if kind == "reset_codes" and any(set(v) != {0, 1} for v in values):
                        raise RuntimeError(f"SSG reset codes mismatch: {name}/{start}")
                    if kind in ("tones", "noise", "envelope", "dynamic") and not any(len(v) > 1 for v in values):
                        raise RuntimeError(f"SSG reference did not advance: {name}/{start}")
                    if kind == "mixer":
                        for channel in range(3):
                            disabled = expectation & (1 << channel) and expectation & (8 << channel)
                            if (disabled and set(values[channel]) != {31}) or (
                                    not disabled and set(values[channel]) != {0, 31}):
                                raise RuntimeError(f"SSG mixer mismatch: {name}/{expectation}/{channel}")
                    if kind == "shape":
                        shape = expectation
                        if any(set(v) != set(range(32)) for v in values):
                            raise RuntimeError(f"SSG envelope did not traverse 32 levels: {shape}")
                        direction = 1 if shape & 4 else -1
                        sweep = list(range(32)) if direction == 1 else list(range(31, -1, -1))
                        if any(not any(v[i:i + 32] == sweep for i in range(len(v) - 31)) for v in values):
                            raise RuntimeError(f"SSG envelope attack sweep: {shape}")
                        holds = not shape & 8 or shape & 1
                        terminal = 0 if not shape & 8 else (
                            31 if bool(shape & 4) != bool(shape & 2) else 0)
                        if holds and values[0][-1] != terminal:
                            raise RuntimeError(f"SSG envelope terminal level: {shape}")
                        if not holds and len(values[0]) < 64:
                            raise RuntimeError(f"SSG envelope repeat missing: {shape}")
                with (out / f"{name}-expected.csv").open("w", newline="", encoding="utf-8") as dst:
                    writer = csv.writer(dst)
                    writer.writerow(("tick", "kind", "index", "value"))
                    writer.writerows(row for row in observed if row[0] >= 3456)
            elif name in ("ssg_tones_abc", "ssg_noise_periods", "fm_ssg_parallel"):
                amplitudes = [r[3] for r in observed if r[1] == "ssg_pcm"]
                if len(set(amplitudes)) < 2 or not any(amplitudes):
                    raise RuntimeError(f"inactive ymfm SSG: {name}")
            checks.append(f"ssg_reference_{name}_{model}")


def phase4_b(out, checks):
    compile_audio(out, "opna_ssg", ssg=True)
    run([VIVADO / "xelab.bat", "tb_ym2608_control", "-generic_top", "FM=0",
         "-generic_top", "SSG=1", "-s", "opna_ssg_quiet", "--debug", "typical",
         "--timescale", "1ns/1ps"], out / "xelab-quiet-console.log", out)
    checks.append("ssg_rtl_elaboration")
    names = tuple(ssg_cases(Bus))
    jobs = []
    for name in names:
        snapshot = "opna_ssg" if name.startswith("fm_ssg_") else "opna_ssg_quiet"
        jobs.append(([VIVADO / "xsim.bat", snapshot, "-runall", "-testplusarg", f"TRACE={name}.bus",
                      "-testplusarg", f"OUTPUT={name}-rtl.csv"], out / f"{name}-xsim.log"))
    run_xsim_cases(out, jobs)
    failures = []
    for name in names:
        require_sim_completion(out / f"{name}-xsim.log", name)
        try:
            comparison(out, f"compare-{name}", out / f"{name}-expected.csv",
                       out / f"{name}-rtl.csv", out / f"{name}.bus", True)
            checks.append(f"ssg_rtl_{name}")
        except RuntimeError:
            failures.append(name)
    if failures:
        raise RuntimeError(f"SSG RTL differences: {', '.join(failures)}; see compare-*.json")


SSG_PAUSED_CASES = ("ssg_mixer_modes", "ssg_retrigger_phases", "fm_ssg_prescaler", "ssg_reset_active")


def phase4_c(out, checks):
    jobs = []
    for name in SSG_PAUSED_CASES:
        snapshot = "opna_ssg" if name.startswith("fm_ssg_") else "opna_ssg_quiet"
        jobs.append(([VIVADO / "xsim.bat", snapshot, "-runall", "-testplusarg", f"TRACE={name}.bus",
                      "-testplusarg", "IDLE=3", "-testplusarg", f"OUTPUT={name}-paused-rtl.csv"],
                     out / f"{name}-paused-xsim.log"))
    run_xsim_cases(out, jobs)
    for name in SSG_PAUSED_CASES:
        require_sim_completion(out / f"{name}-paused-xsim.log", f"paused {name}")
        comparison(out, f"compare-paused-{name}", out / f"{name}-expected.csv",
                   out / f"{name}-paused-rtl.csv", out / f"{name}.bus", True)
        checks.append(f"ssg_clock_enable_{name}")


def phase4_d(out, checks):
    required = {"phase1_cumulative_regression", "phase2_cumulative_regression",
                "phase3_cumulative_regression", "ssg_rtl_elaboration"}
    for name in ssg_cases(Bus):
        required.update((f"ssg_reference_{name}_lle", f"ssg_reference_{name}_ymfm", f"ssg_rtl_{name}"))
        evidence = json.loads((out / f"compare-{name}.json").read_text(encoding="utf-8"))
        if not evidence.get("equal") or evidence.get("observations") != len(rows(out / f"{name}-rtl.csv")):
            raise RuntimeError(f"missing complete SSG comparison evidence: {name}")
        require_sim_completion(out / f"{name}-xsim.log", name)
    for name in SSG_PAUSED_CASES:
        required.add(f"ssg_clock_enable_{name}")
        evidence = json.loads((out / f"compare-paused-{name}.json").read_text(encoding="utf-8"))
        if not evidence.get("equal") or evidence.get("observations") != len(rows(out / f"{name}-paused-rtl.csv")):
            raise RuntimeError(f"missing complete paused SSG comparison evidence: {name}")
        require_sim_completion(out / f"{name}-paused-xsim.log", f"paused {name}")
    if set(checks) != required:
        raise RuntimeError("Phase 4 required checks missing")
    require_pass(4, "B")
    require_pass(4, "C")
    document = (ROOT / "docs/phases/phase-04.md").read_text(encoding="utf-8")
    for section in ("步骤门控", "行为与依据", "必需用例", "参考模型差异的裁决", "实现与证据", "当前结论"):
        if section not in document:
            raise RuntimeError(f"missing Phase 4 documentation: {section}")
    checks.append("phase4_documentation_and_evidence")


def execute_phase4(step, out, checks):
    for current, function in zip("ABCD", (phase4_a, phase4_b, phase4_c, phase4_d)):
        if current <= step:
            checked_step(4, current, function, out, checks)


def adpcm_arguments(name, bus, paused=False):
    arguments = ["-testplusarg", f"TRACE={name}.bus", "-testplusarg", f"MEMORY={name}.mem",
                 "-testplusarg", f"MEMTYPE={bus.memory_type}", "-testplusarg", "ADC=0",
                 "-testplusarg", f"FEEDBACK={bus.adc_feedback}"]
    if bus.adc_events:
        arguments += ["-testplusarg", f"ADC_TRACE={name}.adc"]
    if paused:
        arguments += ["-testplusarg", "IDLE=3"]
    return arguments


def assert_adpcm_irq(name, bus, observed):
    intervals = []
    for event, following in zip(bus.events, bus.events[1:] + [(bus.tick + 4096,)]):
        if event[1] and not event[2] and not event[4] and not event[5] & 1:
            intervals.append((event[0], following[0]))
    flags = status = irq = 0
    enable = 31
    for tick, records in groupby(observed, key=lambda r: r[0]):
        for _, kind, index, value in records:
            if kind == "adpcm" and index == 0:
                flags = value
            elif kind == "mode" and index == 2:
                enable = value
            elif kind == "irq":
                irq = value
        if not any(start <= tick < end for start, end in intervals):
            status = flags
        if irq != int(bool((status << 2) & enable)):
            raise RuntimeError(f"ADPCM IRQ/status latch mismatch: {name}/{tick}")


def assert_zero(name, bus, contract, observed, model):
    flags = [r for r in observed if r[1:3] == ("adpcm", 0)]
    reads = [r[3] for r in observed if r[1:3] == ("read", 2)]
    if model == "ymfm":
        if not reads or any(value & 16 for value in reads):
            raise RuntimeError(f"ymfm ZERO unsupported-path expectation: {name}")
        return
    positive = [r[0] for r in flags if r[3] & 4]
    variant = contract["zero"]
    if variant in ("nonquiet", "reset"):
        if positive or not reads or reads[0] & 16:
            raise RuntimeError(f"unexpected ZERO: {name}")
    else:
        delay = positive[0] - contract["quiet_start"] if positive else 0
        if not 4640000 <= delay <= 4800000 or not reads[0] & 16:
            raise RuntimeError(f"ZERO continuous-quiet interval: {name}/{delay}")
    adc = [r[3] for r in observed if r[1:3] == ("adpcm", 2)]
    if variant == "nonquiet" and (not adc or any((value & 248) in (0, 248) for value in adc)):
        raise RuntimeError(f"ZERO nonquiet digital stimulus missing: {name}")
    if variant in ("silence", "flags"):
        stable = [r[3] for r in observed if r[1:3] == ("adpcm", 2) and r[0] >= bus.tick - 5000000]
        if not adc and not stable:
            raise RuntimeError(f"ZERO ADC observations missing: {name}")
        last_adc = [r[3] for r in observed if r[1:3] == ("adpcm", 2)][-1]
        if (last_adc & 248) not in (0, 248):
            raise RuntimeError(f"ZERO quiet digital stimulus missing: {name}")
    if variant == "flags" and reads != [28, 28, 28, 12, 12, 28, 8, 12]:
        raise RuntimeError(f"ZERO mask/IRQ/reset readback mismatch: {reads}")
    if variant == "reset" and reads != [0]:
        raise RuntimeError(f"ZERO reset sampling state mismatch: {reads}")


def phase5_a(out, checks):
    rom_source = (TOOL / "vendor/ym2608_lle/fmopna_rom.h").read_text(encoding="utf-8")
    reference_rom = bytes(int(value, 16) for value in re.findall(r"0x([0-9a-fA-F]{2})", rom_source))
    rtl_rom = (ROOT / "hardware/rtl/opna_core/jt10_opna_rom.sv").read_text(encoding="utf-8")
    chunks = re.findall(r"128'h([0-9a-fA-F]{32})", rtl_rom)
    actual_rom = b"".join(int(chunk, 16).to_bytes(16, "little") for chunk in reversed(chunks))
    if len(reference_rom) != 8192 or actual_rom != reference_rom:
        raise RuntimeError("rhythm ROM bytes differ from pinned reference")
    checks.append("rhythm_rom_bytes")
    compile_reference(out)
    checks.append("adpcm_reference_compilation")
    contract_report = {}
    for name, (bus, contract) in adpcm_cases(Bus).items():
        stimulus, memory = out / f"{name}.bus", out / f"{name}.mem"
        bus.save(stimulus, tail=4096)
        memory.write_text("".join(f"{address} {value}\n" for address, value in sorted(bus.memory.items())),
                          encoding="utf-8")
        adc_arguments = []
        if bus.adc_events:
            adc_path = out / f"{name}.adc"
            adc_path.write_text("".join(f"{tick} {value}\n" for tick, value in bus.adc_events), encoding="utf-8")
            adc_arguments = ["@" + str(adc_path), str(bus.adc_feedback)]
        contract_report[name] = {}
        for model in ("lle", "ymfm"):
            output = out / f"{name}-{model}.csv"
            run([out / "reference.exe", "lle-adpcm-" + bus.memory_type if model == "lle" else model,
                 stimulus, memory, output, *adc_arguments], out / f"{name}-{model}.log")
            observed = [r for r in rows(output) if r[0] >= 3456]
            reads = [r[3] for r in observed if r[1:3] == ("read", 3)]
            status_reads = [r[3] for r in observed if r[1:3] == ("read", 2)]
            payload = bus.ymfm_payload if model == "ymfm" and bus.ymfm_payload is not None else bus.payload
            if payload is not None and reads[2:] != payload:
                raise RuntimeError(f"ADPCM CPU payload mismatch: {name}/{model}: {reads}")
            if contract.get("eos") and (not status_reads or not any(value & 4 for value in status_reads)):
                raise RuntimeError(f"ADPCM EOS not set: {name}/{model}")
            if name == "adpcm_repeat" and model == "ymfm" and status_reads != [40]:
                raise RuntimeError("ymfm repeat EOS/busy contract changed")
            if name.startswith("adpcm_cpu_end_"):
                expected = [8,12] if model == "lle" else [12,8]
                if status_reads != expected:
                    raise RuntimeError(f"CPU end EOS latch contract: {name}/{model}: {status_reads}")
            if name == "adpcm_status_masks":
                expected = [44,32,32,32,32,32,32] if model == "lle" else [12,0,12,4,8,8,12]
                if status_reads != expected:
                    raise RuntimeError(f"ADPCM status masks: {model}: {status_reads}")
            for start, end, activity, pan in bus.audio_windows:
                for channel in (0, 1):
                    values = [r[3] for r in observed if r[1:3] == ("pcm", channel) and start <= r[0] < end]
                    active = activity == "active" and pan & (128 if channel == 0 else 64)
                    if not values or bool(any(values)) != bool(active):
                        raise RuntimeError(f"ADPCM/rhythm audio window: {name}/{model}/{start}/{channel}")
            if "zero" in contract:
                assert_zero(name, bus, contract, observed, model)
            elif model == "lle" and any(r[3] & 4 for r in observed if r[1:3] == ("adpcm",0)):
                raise RuntimeError(f"ZERO falsely asserted during playback: {name}")
            if model == "lle":
                assert_adpcm_irq(name, bus, observed)
                addresses = [r[2] for r in observed if r[1] == "mem_read"]
                if any(not 0 <= address < 262144 for address in addresses):
                    raise RuntimeError(f"external memory address range: {name}")
                writes = [r for r in observed if r[1] == "mem_write"]
                if bool(writes) != bool(contract.get("write")):
                    raise RuntimeError(f"external memory writes: {name}")
                if contract.get("write") and len(writes) != len(bus.payload) * (8 if bus.memory_type == "ram1" else 1):
                    raise RuntimeError(f"CPU write count: {name}")
                if contract.get("limit"):
                    matches = [r[0] for r in observed if r[1:3] == ("limit",0) and r[3] == 1]
                    zeros = [r[0] for r in observed if r[1:3] == ("limit",1) and r[3] == 0]
                    if not matches or not any(0 <= zero - match <= 16 for match in matches for zero in zeros):
                        raise RuntimeError("limit address did not clear the address ring")
                    if not addresses or min(addresses) != 32 or max(addresses) != 63:
                        raise RuntimeError("limit/stop/repeat external address range")
                with (out / f"{name}-expected.csv").open("w", newline="", encoding="utf-8") as dst:
                    writer = csv.writer(dst)
                    writer.writerow(("tick", "kind", "index", "value"))
                    writer.writerows(observed)
            contract_report[name][model] = {"observations": len(observed), "dummy_reads": reads[:2],
                                            "payload_bytes": len(reads[2:]), "status_reads": status_reads}
            checks.append(f"adpcm_reference_{name}_{model}")
    (out / "reference-contract.json").write_text(json.dumps(contract_report, indent=2) + "\n", encoding="utf-8")
    checks.append("zero_manual_contract")


def phase5_b(out, checks):
    compile_audio(out, "opna_all", ssg=True, rhythm=True, adpcm=True)
    run([VIVADO / "xelab.bat", "tb_ym2608_control", "-generic_top", "FM=0",
         "-generic_top", "SSG=1", "-generic_top", "RHYTHM=1", "-generic_top", "ADPCM=1",
         "-s", "opna_adpcm", "--debug", "typical", "--timescale", "1ns/1ps"],
        out / "xelab-adpcm-console.log", out)
    checks.append("adpcm_rtl_elaboration")
    cases = adpcm_cases(Bus)
    jobs = []
    for name, (bus, _) in cases.items():
        snapshot = "opna_all" if name.startswith("fm_ssg_") else "opna_adpcm"
        jobs.append(([VIVADO / "xsim.bat", snapshot, "-runall", *adpcm_arguments(name, bus),
                      "-testplusarg", f"OUTPUT={name}-rtl.csv"], out / f"{name}-xsim.log"))
    run_xsim_cases(out, jobs)
    for name in cases:
        require_sim_completion(out / f"{name}-xsim.log", name)
        comparison(out, f"compare-{name}", out / f"{name}-expected.csv",
                   out / f"{name}-rtl.csv", out / f"{name}.bus", True)
        checks.append(f"adpcm_rtl_{name}")


ADPCM_PAUSED_CASES = ("rhythm_stop_restart", "adpcm_cpu_write_read_ram1",
                      "fm_ssg_rhythm_adpcm_parallel", "adpcm_reset_15", "adpcm_zero_silence")


def phase5_c(out, checks):
    cases = adpcm_cases(Bus)
    jobs = []
    for name in ADPCM_PAUSED_CASES:
        bus, _ = cases[name]
        snapshot = "opna_all" if name.startswith("fm_ssg_") else "opna_adpcm"
        jobs.append(([VIVADO / "xsim.bat", snapshot, "-runall", *adpcm_arguments(name, bus, paused=True),
                      "-testplusarg", f"OUTPUT={name}-paused-rtl.csv"], out / f"{name}-paused-xsim.log"))
    run_xsim_cases(out, jobs)
    for name in ADPCM_PAUSED_CASES:
        require_sim_completion(out / f"{name}-paused-xsim.log", f"paused {name}")
        comparison(out, f"compare-paused-{name}", out / f"{name}-expected.csv",
                   out / f"{name}-paused-rtl.csv", out / f"{name}.bus", True)
        checks.append(f"adpcm_clock_enable_{name}")


def phase5_d(out, checks):
    required = {f"phase{phase}_cumulative_regression" for phase in range(1,5)}
    required.update(("rhythm_rom_bytes", "adpcm_reference_compilation", "zero_manual_contract", "adpcm_rtl_elaboration"))
    for name in adpcm_cases(Bus):
        required.update((f"adpcm_reference_{name}_lle", f"adpcm_reference_{name}_ymfm", f"adpcm_rtl_{name}"))
        evidence = json.loads((out / f"compare-{name}.json").read_text(encoding="utf-8"))
        if not evidence.get("equal") or evidence.get("observations") != len(rows(out / f"{name}-rtl.csv")):
            raise RuntimeError(f"missing complete ADPCM comparison: {name}")
        require_sim_completion(out / f"{name}-xsim.log", name)
    for name in ADPCM_PAUSED_CASES:
        required.add(f"adpcm_clock_enable_{name}")
        evidence = json.loads((out / f"compare-paused-{name}.json").read_text(encoding="utf-8"))
        if not evidence.get("equal") or evidence.get("observations") != len(rows(out / f"{name}-paused-rtl.csv")):
            raise RuntimeError(f"missing complete paused ADPCM comparison: {name}")
        require_sim_completion(out / f"{name}-paused-xsim.log", f"paused {name}")
    if set(checks) != required:
        raise RuntimeError("Phase 5 required checks missing")
    require_pass(5, "B")
    require_pass(5, "C")
    document = (ROOT / "docs/phases/phase-05.md").read_text(encoding="utf-8")
    for section in ("步骤门控", "行为与依据", "必需用例", "参考模型差异的裁决", "实现与证据", "当前结论"):
        if section not in document:
            raise RuntimeError(f"missing Phase 5 documentation: {section}")
    checks.append("phase5_documentation_and_evidence")


def execute_phase5(step, out, checks):
    for current, function in zip("ABCD", (phase5_a, phase5_b, phase5_c, phase5_d)):
        if current <= step:
            checked_step(5, current, function, out, checks)


def assert_acceptance(name, bus, contract, observed, model):
    pcm = [row for row in observed if row[1] == "pcm"]
    if not pcm or {row[2] for row in pcm} != {0, 1} or any(not -32768 <= row[3] <= 32767 for row in pcm):
        raise RuntimeError(f"invalid acceptance PCM: {name}/{model}")
    readback = {}
    for port in range(4):
        values = [row[3] for row in observed if row[1:3] == ("read", port)]
        expected = contract.get("expected_reads", {}).get(model, {}).get(port, [])
        if port == 3 and bus.payload is not None:
            payload = bus.ymfm_payload if model == "ymfm" and bus.ymfm_payload is not None else bus.payload
            expected = contract["dummy_reads"][model] + payload
        if values != expected:
            raise RuntimeError(f"acceptance readback: {name}/{model}/{port}: {values} != {expected}")
        if values:
            readback[port] = values
    for start, end, activity, pan in bus.audio_windows:
        for channel in (0, 1):
            values = [row[3] for row in pcm if row[2] == channel and start <= row[0] < end]
            active = activity == "active" and bool(pan & (128 if channel == 0 else 64))
            if not values or bool(any(values)) != active:
                raise RuntimeError(f"acceptance audio/pan: {name}/{model}/{start}/{channel}")
    for start, end, pan in contract.get("signed_windows", []):
        for channel in (0, 1):
            if pan & (128 if channel == 0 else 64):
                values = [row[3] for row in pcm if row[2] == channel and start <= row[0] < end]
                if not any(value > 0 for value in values) or not any(value < 0 for value in values):
                    raise RuntimeError(f"acceptance signed output: {name}/{model}/{start}/{channel}")
    report = {"observations": len(observed), "status_reads": readback,
              "pcm_samples": len(pcm), "pcm_min": min(row[3] for row in pcm),
              "pcm_max": max(row[3] for row in pcm)}
    if model == "ymfm":
        if contract.get("ssg_windows"):
            values = [row[3] for row in observed if row[1] == "ssg_pcm"]
            active = contract.get("ymfm_ssg_activity", True)
            if not values or bool(any(values)) != active:
                raise RuntimeError(f"acceptance ymfm SSG activity: {name}")
        return report
    levels = [row for row in observed if row[1] == "ssg"]
    if {row[2] for row in levels} != {0, 1, 2} or any(not 0 <= row[3] <= 31 for row in levels):
        raise RuntimeError(f"invalid acceptance native SSG: {name}")
    for start, end, kind, expectation in contract.get("ssg_windows", []):
        values = ssg_window_values(observed, start, end)
        if kind == "constant" and any(set(value) != {expected} for value, expected in zip(values, expectation)):
            raise RuntimeError(f"acceptance SSG constant: {name}/{start}")
        if kind == "dynamic" and not all(len(set(value)) > 1 for value in values):
            raise RuntimeError(f"acceptance SSG dynamic: {name}/{start}")
        if kind == "reset_codes" and any(set(value) != {0, 1} for value in values):
            raise RuntimeError(f"acceptance SSG reset codes: {name}/{start}")
        if kind == "mixer":
            for channel in range(3):
                disabled = expectation & (1 << channel) and expectation & (8 << channel)
                if set(values[channel]) != ({31} if disabled else {0, 31}):
                    raise RuntimeError(f"acceptance SSG mixer: {name}/{start}/{channel}")
    for start, end, sources in contract.get("source_windows", []):
        for source in sources:
            values = [row[3] for row in observed if row[1:3] == ("mix_source", source) and start <= row[0] < end]
            before = [row[3] for row in observed if row[1:3] == ("mix_source", source) and row[0] < start]
            if before:
                values.insert(0, before[-1])
            if not any(values) or len(set(values)) < 2:
                raise RuntimeError(f"acceptance mix source inactive: {name}/{start}/{source}")
    for start, end, sources in contract.get("source_zero_windows", []):
        for source in sources:
            values = [row[3] for row in observed if row[1:3] == ("mix_source", source) and start <= row[0] < end]
            before = [row[3] for row in observed if row[1:3] == ("mix_source", source) and row[0] < start]
            if before:
                values.insert(0, before[-1])
            if not values or any(values):
                raise RuntimeError(f"acceptance zero mix source: {name}/{start}/{source}")
    for _, kind, source, value in observed:
        if kind == "mix_source" and (not (-32768 <= value <= 32767 if source in (1, 2) else -131072 <= value <= 131071)
                                     or source == 3 and value & 3):
            raise RuntimeError(f"acceptance mix sign-extension/alignment: {name}/{source}/{value}")
    cadence_report = []
    for start, end, period in contract.get("cadence_windows", []):
        for channel in (0, 1):
            ticks = [row[0] for row in pcm if row[2] == channel and start <= row[0] < end]
            if len(ticks) < 3 or any(b - a != period for a, b in zip(ticks, ticks[1:])) or \
                    ticks[0] - start >= period or end - ticks[-1] > period:
                raise RuntimeError(f"acceptance PCM cadence/drift: {name}/{start}/{channel}")
            cadence_report.append({"channel": channel, "first_tick": ticks[0], "last_tick": ticks[-1],
                                   "period": period, "samples": len(ticks)})
    if "clipping_window" in contract:
        start, end = contract["clipping_window"]
        samples = {(row[0], row[2]): row[3] for row in pcm}
        loads = [row for row in observed if row[1] == "mix_acc" and start <= row[0] < end]
        if not loads or any(samples.get((tick + 110, channel)) != max(-32768, min(32767, value))
                            for tick, _, channel, value in loads):
            raise RuntimeError(f"acceptance native signed clipping/serial delay: {name}")
        for channel in (0, 1):
            values = [row[3] for row in loads if row[2] == channel]
            if not any(value > 32767 for value in values) or not any(value < -32768 for value in values):
                raise RuntimeError(f"acceptance clipping boundaries not exercised: {name}/{channel}")
        report["clipping"] = {"loads": len(loads), "serial_delay": 110,
                              "min_accumulator": min(row[3] for row in loads),
                              "max_accumulator": max(row[3] for row in loads)}
    if any(row[3] & 4 for row in observed if row[1:3] == ("adpcm", 0)):
        raise RuntimeError(f"ZERO falsely asserted in acceptance playback: {name}")
    addresses = [row[2] for row in observed if row[1] == "mem_read"]
    if any(not 0 <= address < 262144 for address in addresses):
        raise RuntimeError(f"acceptance external memory address range: {name}")
    report["memory_reads"] = len(addresses)
    report["cadence"] = cadence_report
    return report


def assert_acceptance_stimulus(name, bus, contract):
    selected = [0, 0]
    attack_rates = {}
    ssg_modes = {}
    decoded = []
    ready = 0
    for index, event in enumerate(bus.events):
        tick, ic, cs, wr, rd, address, data = event
        if (index and tick <= bus.events[index - 1][0]) or not 0 <= tick < bus.tick + 4096 or \
                any(pin not in (0, 1) for pin in (ic, cs, wr, rd)) or not 0 <= address <= 3 or \
                not 0 <= data <= 255 or (not cs and not wr and not rd):
            raise RuntimeError(f"illegal acceptance pin event: {name}/{event}")
        if not ic:
            selected = [0, 0]
            attack_rates.clear()
            ssg_modes.clear()
            ready = 0
        if ic and not cs and not wr:
            following = bus.events[index + 1] if index + 1 < len(bus.events) else None
            if not following or not (following[2] or following[3]) or following[0] - tick < 32 or tick < ready:
                raise RuntimeError(f"illegal acceptance write window/wait: {name}/{tick}")
            port = address >> 1
            if address & 1:
                register = selected[port]
                decoded.append((tick, port, register, data))
                operator = (port, register & 15)
                if 0x50 <= register <= 0x5e and register & 3 != 3:
                    if ssg_modes.get(operator, 0) & 8 and data & 31 != 31:
                        raise RuntimeError(f"SSG-EG requires AR=0x1F: {name}/{tick}/port{port}/reg{register:02X}")
                    attack_rates[operator] = data & 31
                elif 0x90 <= register <= 0x9e and register & 3 != 3:
                    if data & 8 and attack_rates.get(operator, 0) != 31:
                        raise RuntimeError(f"SSG-EG enabled with AR!=0x1F: {name}/{tick}/port{port}/reg{register:02X}")
                    ssg_modes[operator] = data
                ready = following[0] + (1152 if port == 0 and register == 0x10 else 166)
            else:
                selected[port] = data
    if "seed" in contract:
        actions = contract["random_actions"]
        if len(actions) != 192 or set(actions) != set(range(8)) or \
                len(bus.random_events) != contract["random_events"] or not set(bus.random_events) <= set(decoded):
            raise RuntimeError(f"fixed-seed legal-action coverage missing: {name}")
    if "reset_tick" in contract:
        tick = contract["reset_tick"]
        if (tick, 0, 1, 1, 1, 0, 0) not in bus.events or (tick + 1152, 1, 1, 1, 1, 0, 0) not in bus.events:
            raise RuntimeError(f"running reset pulse missing: {name}")
    if "music" in contract:
        music = contract["music"]
        if len(bus.music_writes) != music["register_writes"] or bus.music_writes != decoded or \
                len(bus.music_samples) != music["sample_bytes"] or \
                bus.music_samples != bytes(bus.memory[address] for address in sorted(bus.memory)):
            raise RuntimeError(f"real music register/sample input mismatch: {name}")
        cursor = 3456
        for raw, expanded in zip(bus.music_raw_writes, bus.music_writes):
            sample, port, register, data = raw
            start = max(cursor, 3456 + sample * 16_000_000 // 44100)
            if expanded != (start + 64, port, register, data):
                raise RuntimeError(f"real music absolute-tick serialization mismatch: {name}")
            cursor = start + (1248 if port == 0 and register == 0x10 else 512)


def phase6_a(out, checks):
    cases = acceptance_cases(Bus)
    repeated = acceptance_cases(Bus)
    if not cases or list(cases) != list(repeated):
        raise RuntimeError("acceptance case generation is not deterministic")
    scenarios = set()
    for name, (bus, contract) in cases.items():
        other, other_contract = repeated[name]
        if (bus.events, bus.tick, bus.memory, contract) != (other.events, other.tick, other.memory, other_contract):
            raise RuntimeError(f"acceptance stimulus is not reproducible: {name}")
        assert_acceptance_stimulus(name, bus, contract)
        scenarios.update(contract["scenario"])
        if not set(contract["coverage"]) <= {"BUS", "CLK", "TIM", "FM", "EG", "MOD", "SCH", "SSG", "RHY", "ADP", "STA", "MIX", "RUN"}:
            raise RuntimeError(f"invalid acceptance feature declaration: {name}")
    if not {"mixed", "random", "reset", "music", "long"} <= scenarios:
        raise RuntimeError("acceptance RUN/MIX scenarios missing")
    checks.append("acceptance_deterministic_legal_stimuli")
    compile_reference(out)
    checks.append("acceptance_reference_compilation")
    report = {}
    for name, (bus, contract) in cases.items():
        stimulus, memory = out / f"{name}.bus", out / f"{name}.mem"
        bus.save(stimulus, tail=4096)
        memory.write_text("".join(f"{address} {value}\n" for address, value in sorted(bus.memory.items())), encoding="utf-8")
        adc = "0"
        if bus.adc_events:
            adc_path = out / f"{name}.adc"
            adc_path.write_text("".join(f"{tick} {value}\n" for tick, value in bus.adc_events), encoding="utf-8")
            adc = "@" + str(adc_path)
        report[name] = {"contract": contract, "models": {}}
        for model in ("lle", "ymfm"):
            output = out / f"{name}-{model}.csv"
            arguments = [adc, str(bus.adc_feedback), "1"] if model == "lle" else []
            run([out / "reference.exe", "lle-adpcm-" + bus.memory_type if model == "lle" else model,
                 stimulus, memory, output, *arguments], out / f"{name}-{model}.log")
            observed = [row for row in rows(output) if row[0] >= 3456]
            report[name]["models"][model] = assert_acceptance(name, bus, contract, observed, model)
            if model == "lle":
                with (out / f"{name}-expected.csv").open("w", newline="", encoding="utf-8") as dst:
                    writer = csv.writer(dst)
                    writer.writerow(("tick", "kind", "index", "value"))
                    writer.writerows(observed)
            checks.append(f"acceptance_reference_{name}_{model}")
    (out / "reference-contract.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def phase6_simulate(out, checks, paused):
    cases = acceptance_cases(Bus)
    suffix = "-paused" if paused else ""
    jobs = [([VIVADO / "xsim.bat", "opna_all", "-runall", *adpcm_arguments(name, bus, paused),
              "-testplusarg", "MIX_TRACE=1", "-testplusarg", f"OUTPUT={name}{suffix}-rtl.csv"],
             out / f"{name}{suffix}-xsim.log") for name, (bus, _) in cases.items()]
    run_xsim_cases(out, jobs)
    for name in cases:
        require_sim_completion(out / f"{name}{suffix}-xsim.log", name + suffix)
        comparison(out, f"compare{suffix}-{name}", out / f"{name}-expected.csv",
                   out / f"{name}{suffix}-rtl.csv", out / f"{name}.bus", True)
        checks.append(f"acceptance_{'clock_enable' if paused else 'rtl'}_{name}")


def phase6_b(out, checks):
    compile_audio(out, "opna_all", ssg=True, rhythm=True, adpcm=True)
    checks.append("acceptance_rtl_elaboration")
    phase6_simulate(out, checks, False)


def phase6_c(out, checks):
    phase6_simulate(out, checks, True)


def phase6_d(out, checks):
    cases = acceptance_cases(Bus)
    required = {f"phase{phase}_cumulative_regression" for phase in range(1, 6)}
    required.update(("acceptance_deterministic_legal_stimuli", "acceptance_reference_compilation", "acceptance_rtl_elaboration"))
    for phase in range(1, 6):
        for step in "ABCD":
            if (phase, step) not in FRESH_REPORTS or FRESH_REPORTS[phase, step]["status"] != "通过":
                raise RuntimeError(f"Phase {phase} {step} did not freshly execute in this invocation")
    for step in "ABC":
        if (6, step) not in FRESH_REPORTS:
            raise RuntimeError(f"Phase 6 {step} did not freshly execute in this invocation")
    for name in cases:
        required.update((f"acceptance_reference_{name}_lle", f"acceptance_reference_{name}_ymfm",
                         f"acceptance_rtl_{name}", f"acceptance_clock_enable_{name}"))
        for suffix in ("", "-paused"):
            evidence = json.loads((out / f"compare{suffix}-{name}.json").read_text(encoding="utf-8"))
            if not evidence.get("equal") or evidence.get("observations") != len(rows(out / f"{name}{suffix}-rtl.csv")):
                raise RuntimeError(f"missing complete acceptance comparison: {name}{suffix}")
            require_sim_completion(out / f"{name}{suffix}-xsim.log", name + suffix)
    if set(checks) != required or len(checks) != len(required):
        raise RuntimeError("Phase 6 required checks missing or duplicated")
    feature_checks = {
        "BUS": (2, ("rtl_bus_phase_sweep", "rtl_bank_isolation", "rtl_reset_active", "rtl_ssg_masks")),
        "CLK": (2, ("rtl_prescaler", "rtl_channel_mode", "rtl_timers_prescaler")),
        "TIM": (2, ("rtl_timer_a", "rtl_timer_b", "rtl_timer_a_minimum", "rtl_timer_b_minimum", "rtl_timer_enable_stop", "rtl_irq_mask", "rtl_status_read_hold")),
        "FM": (3, ("fm_rtl_six_channels_slots", "fm_rtl_algorithms_feedback", "fm_rtl_frequency_latch", "fm_rtl_frequency_detune_multiplier")),
        "EG": (3, ("fm_rtl_envelope_boundaries", "fm_rtl_ssg_eg_shapes", "fm_rtl_attack_rounding", "fm_rtl_decay_granularity")),
        "MOD": (3, ("fm_rtl_lfo_am_pm", "fm_rtl_channel3_special", "fm_rtl_csm_timer_a")),
        "SCH": (3, tuple(f"sch_contract_{case}" for case in ("sch_high_channel", "sch_key_alias", "sch_enable_after_key", "sch_enable_after_other_key"))),
        "SSG": (4, tuple(f"ssg_rtl_{case}" for case in ssg_cases(Bus))),
        "RHY": (5, tuple(f"adpcm_rtl_{case}" for case in adpcm_cases(Bus) if case.startswith("rhythm_"))),
        "ADP": (5, tuple(f"adpcm_rtl_{case}" for case in adpcm_cases(Bus) if case.startswith("adpcm_"))),
        "STA": (5, ("adpcm_rtl_adpcm_status_masks", "adpcm_rtl_adpcm_zero_silence", "adpcm_rtl_adpcm_zero_nonquiet", "adpcm_rtl_adpcm_zero_interrupted", "adpcm_rtl_adpcm_zero_flags", "adpcm_rtl_adpcm_zero_reset")),
    }
    coverage = {}
    for feature, (phase, names) in feature_checks.items():
        if not names or not set(names) <= set(FRESH_REPORTS[phase, "D"]["checks"]):
            raise RuntimeError(f"fresh cumulative feature evidence missing: {feature}")
        coverage[feature] = {"phase": phase, "report": f"../phase-{phase:02}/gate-D.json", "checks": names}
    for feature in ("MIX", "RUN"):
        names = [name for name, (_, contract) in cases.items() if feature in contract["coverage"]]
        if not names:
            raise RuntimeError(f"acceptance feature evidence missing: {feature}")
        coverage[feature] = {"phase": 6, "cases": names,
                             "comparisons": [f"compare{suffix}-{name}.json" for name in names for suffix in ("", "-paused")]}
    document = (ROOT / "docs/phases/phase-06.md").read_text(encoding="utf-8")
    for section in ("步骤门控", "行为与依据", "必需用例", "参考模型差异的裁决", "实现与证据", "当前结论"):
        if section not in document:
            raise RuntimeError(f"missing Phase 6 documentation: {section}")
    sch = json.loads((BUILD / "phase-03/sch-contract.json").read_text(encoding="utf-8"))
    if sch.get("decision") != "SCH-LLE-2026-10-07" or sch.get("chip_verified") is not False:
        raise RuntimeError("SCH engineering contract or chip-verification limitation changed")
    (out / "feature-coverage.json").write_text(json.dumps({"features": coverage,
        "fresh_cumulative_phases": list(range(1, 6)), "sch_decision": sch["decision"],
        "sch_chip_verified": False, "board_verified": False}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    checks.append("acceptance_all_features_fresh_evidence")
    checks.append("phase6_documentation_and_evidence")


def execute_phase6(step, out, checks):
    for current, function in zip("ABCD", (phase6_a, phase6_b, phase6_c, phase6_d)):
        if current <= step:
            checked_step(6, current, function, out, checks)


def invalidate_later(phase, step):
    for number in range(phase, 8):
        document = ROOT / f"docs/phases/phase-{number:02}.md"
        if not document.exists():
            continue
        for later in "ABCD":
            if number == phase and later <= step:
                continue
            report_path = BUILD / f"phase-{number:02}/gate-{later}.json"
            if report_path.exists():
                previous = json.loads(report_path.read_text(encoding="utf-8"))
                previous["status"] = "未通过"
                previous["error"] = f"invalidated by Phase {phase} {step} failure"
                report_path.write_text(json.dumps(previous, ensure_ascii=False, indent=2) + "\n",
                                       encoding="utf-8")
                set_step(number, later, "未通过", f"Phase {phase} {step}未通过，需重跑")


def update_progress(phase, step, report):
    status = report["status"]
    if status == "通过":
        next_item = f"Phase {phase} 步骤 {'ABCD'['ABCD'.index(step) + 1]}" if step != "D" else f"Phase {phase + 1} 步骤 A"
    elif status == "进行中":
        next_item = "等待当前门控结果，不进入后续步骤"
    else:
        next_item = f"修复 Phase {phase} 步骤 {step} 并重跑门控"
    detail = report.get("error", "本次必需检查全部通过。")
    (ROOT / "docs/progress.md").write_text(
        f"# 当前进度\n\n- 当前Phase：{phase}。\n- 当前步骤：{step}。\n"
        f"- 门控：{status}。\n- 检查结果：{detail}\n"
        f"- 证据：[gate-{step}.json](../build/opna_sim/phase-{phase:02}/gate-{step}.json)。\n"
        f"- 下一项允许工作：{next_item}。\n"
        "- 只有Phase 6门控通过才能声明数字逻辑仿真验收完成；板测属于Phase 7。\n",
        encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", type=int, choices=range(1, 8), required=True)
    parser.add_argument("--step", choices=list("ABCD"), required=True)
    args = parser.parse_args()
    out = BUILD / f"phase-{args.phase:02}"
    out.mkdir(parents=True, exist_ok=True)
    checks = []
    report = {"phase": args.phase, "step": args.step, "status": "未通过", "checks": checks}
    started = False
    FRESH_REPORTS.clear()
    try:
        # The current phase always executes A through the requested step in
        # order. Fresh success advances the step; a failed check stops here.
        if args.phase not in (1, 2, 3, 4, 5, 6):
            raise RuntimeError("requested gate is not implemented; phase advancement denied")
        set_step(args.phase, args.step, "进行中", "运行中")
        started = True
        update_progress(args.phase, args.step, {"status": "进行中", "error": "正在执行当前与累计必需检查。"})
        executors = (execute_phase1, execute_phase2, execute_phase3,
                     execute_phase4, execute_phase5, execute_phase6)
        for previous in range(1, args.phase):
            prerequisite_checks = [f"phase{phase}_cumulative_regression" for phase in range(1, previous)]
            executors[previous - 1]("D", BUILD / f"phase-{previous:02}", prerequisite_checks)
            require_pass(previous, "D")
            checks.append(f"phase{previous}_cumulative_regression")
        executors[args.phase - 1](args.step, out, checks)
        report["status"] = "通过"
        set_step(args.phase, args.step, "通过",
                 f"[检查结果](../../build/opna_sim/phase-{args.phase:02}/gate-{args.step}.json)")
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        if isinstance(error, GateFailure):
            report["failed_phase"], report["failed_step"] = error.phase, error.step
        doc = ROOT / f"docs/phases/phase-{args.phase:02}.md"
        if doc.exists():
            set_step(args.phase, args.step, "未通过",
                     f"[失败结果](../../build/opna_sim/phase-{args.phase:02}/gate-{args.step}.json)")
            invalidate_later(args.phase, args.step)
        print(f"FAIL: {error}", file=sys.stderr)
    (out / f"gate-{args.step}.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if started:
        update_progress(report.get("failed_phase", args.phase), report.get("failed_step", args.step), report)
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report["status"] == "通过" else 1


if __name__ == "__main__":
    sys.exit(main())
