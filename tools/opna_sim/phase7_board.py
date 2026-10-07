"""Fresh offline board RTL checks; physical hardware is not verified."""
import json
from pathlib import Path
import sys

import gate

ROOT = gate.ROOT
OUT = ROOT / "build/opna_phase7/board-tests"
REQUIRED_CHECKS = {
    "host_independent_aw_w_ar_four_byte_banks_busy_backpressure_ic_fault",
    "audio_external_i2s16_stereo_pair_zoh_ssg_saturation_async_reset",
    "native_core_hp0_rom_ram8_ram1_data_ticks_zero_stalls",
    "native_memory_cross_line_loop_tail_cpu_read_write",
    "system_half_ce_4_of_25_continuous_clock",
    "ddr_underrun_stops_mutes_and_axi_errors_recover",
}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    result = {"status": "未通过", "checks": [], "board_verified": False}
    (OUT / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    sources = sorted((ROOT / "hardware/rtl/board").glob("*.sv"))
    sources += sorted((ROOT / "hardware/rtl/board").glob("*.v"))
    sources.append(Path(__file__).with_name("phase7_board_tb.sv"))
    gate.run([gate.VIVADO / "xvlog.bat", "--sv", *sources], OUT / "compile-board.log", OUT)
    gate.run([gate.VIVADO / "xelab.bat", "phase7_board_tb", "-s", "board_subsystems",
              "--debug", "typical", "--timescale", "1ns/1ps"], OUT / "elaborate-board.log", OUT)
    log = OUT / "simulate-board.log"
    gate.run([gate.VIVADO / "xsim.bat", "board_subsystems", "-runall"], log, OUT)
    content = log.read_text(encoding="utf-8")
    if "BOARD_SUBSYSTEM_PASS" not in content or "Fatal" in content:
        raise RuntimeError(f"board subsystem simulation failed: {log}")
    result["checks"] += [line[6:] for line in content.splitlines() if line.startswith("CHECK ")]
    gate.compile_audio(OUT, "board_native_reference", ssg=True, rhythm=True, adpcm=True)
    gate.run([gate.VIVADO / "xvlog.bat", "--sv",
              Path(__file__).with_name("phase7_board_ddr_model.sv"),
              Path(__file__).with_name("phase7_board_native_tb.sv")], OUT / "compile-native-board.log", OUT)
    gate.run([gate.VIVADO / "xelab.bat", "phase7_native_tb", "-s", "board_native",
              "--debug", "typical", "--timescale", "1ns/1ps"], OUT / "elaborate-native-board.log", OUT)
    native_log = OUT / "simulate-native-board.log"
    gate.run([gate.VIVADO / "xsim.bat", "board_native", "-runall"], native_log, OUT)
    content = native_log.read_text(encoding="utf-8")
    if "BOARD_NATIVE_PASS" not in content or "Fatal" in content:
        raise RuntimeError(f"native board simulation failed: {native_log}")
    result["checks"] += [line[6:] for line in content.splitlines() if line.startswith("CHECK ")]
    result["metrics"] = [line for line in content.splitlines() if line.startswith(("NATIVE_CASE ", "START_SWITCH ", "PAUSE_PHASE ", "METRICS "))]
    if set(result["checks"]) != REQUIRED_CHECKS:
        result["status"] = "进行中"
        (OUT / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        raise RuntimeError("required board checks are incomplete")
    result["status"] = "通过"
    (OUT / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
