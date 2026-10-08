# diagnose_no_sound.ps1
# Quick diagnosis for "LED blinks but no sound" on Zybo OPNA.
#
# Usage: powershell -ExecutionPolicy Bypass -File scripts/diagnose_no_sound.ps1

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path "$scriptDir\.."

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " NO-SOUND DIAGNOSIS" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

Write-Host ""
Write-Host "CHECKLIST (answer each):" -ForegroundColor Yellow
Write-Host ""

Write-Host "1. Was the PS ELF downloaded and run?"
Write-Host "   The XSCT script should show:"
Write-Host "     'Downloading ELF...'"
Write-Host "     'Starting Cortex-A9 #0...'"
Write-Host "   If you only ran 'Program Device' in Vivado Hardware Manager,"
Write-Host "   the ELF was NOT loaded and the codec is NOT initialized."
Write-Host ""

Write-Host "2. Is there UART output?"
Write-Host "   Connect a serial terminal (115200 baud) to the Zybo USB-UART."
Write-Host "   After PS boot, you should see:"
Write-Host "     'Welcome to the OPL3 FPGA'"
Write-Host "   If nothing appears, the PS is not running."
Write-Host "   If you see 'IIC send failed', the I2C bus to the codec failed."
Write-Host ""

Write-Host "3. Check LED[2] on bypass test:"
Write-Host "   bypass_on: led[2] should be ON  (bypass mode)"
Write-Host "   normal:    led[2] should be OFF (OPNA mode)"
Write-Host "   If led[2] is wrong, the wrong bitstream was loaded."
Write-Host ""

Write-Host "4. Hardware signal check (if you have a scope/multimeter):"
Write-Host "   - ac_mclk at T19: should be ~12.727 MHz square wave"
Write-Host "   - i2s_sclk at K18: should be ~3.18 MHz"
Write-Host "   - i2s_ws at L17: should be ~49.7 kHz"
Write-Host "   - ac_mute_n at P18: should be HIGH (~3.3V)"
Write-Host "     If ac_mute_n is LOW, the codec output is muted."
Write-Host ""

Write-Host "5. Audio connection:"
Write-Host "   - Zybo has a 3.5mm LINE OUT (blue) and HEADPHONE OUT (black)"
Write-Host "   - Try HEADPHONE OUT (black) first"
Write-Host "   - Make sure volume on connected speakers/headphones is up"
Write-Host ""

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " MOST LIKELY FIX" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "If you used Vivado Hardware Manager to program the bitstream"
Write-Host "but did NOT run the PS ELF, the codec stays uninitialized."
Write-Host ""
Write-Host "Do this instead:"
Write-Host ""
Write-Host "  1. Close Vivado Hardware Manager"
Write-Host "  2. Open a command prompt"
Write-Host "  3. Run:"
Write-Host "     J:\FPGA\2025.2\Vitis\bin\xsct.bat scripts\jtag\program_bypass_on.tcl"
Write-Host ""
Write-Host "  This will:"
Write-Host "    - Program the bypass bitstream"
Write-Host "    - Initialize the PS7 (DDR, clocks, MIO)"
Write-Host "    - Download and run the PS ELF"
Write-Host "    - The ELF calls ssm2603_init() to configure the codec"
Write-Host ""
Write-Host "  Watch the UART output for codec init status."
Write-Host "============================================"
