param([switch]$SkipJtag)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path "$scriptDir\.."
$bitFile = "$repoRoot\build\bitstreams\opna_normal.bit"
$elfFile = "$repoRoot\build\software\opna_bringup.elf"
$preload = "$repoRoot\build\opna_test_tone.bin"
$marker = "$repoRoot\build\bypass_smoke.ok"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "OPNA PRELOAD TONE SMOKE CHECK" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if (-not (Test-Path $marker)) {
    Write-Host "FAIL: bypass success not recorded." -ForegroundColor Red
    Write-Host "Run scripts\run_bypass_smoke_test.ps1 first and confirm bypass tone." -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $bitFile)) {
    Write-Host "FAIL: bitstream missing: $bitFile" -ForegroundColor Red
    exit 1
}
Write-Host "opna_normal.bit found: $bitFile" -ForegroundColor Green

if (-not (Test-Path $elfFile)) {
    Write-Host "FAIL: ELF missing: $elfFile" -ForegroundColor Red
    exit 1
}
Write-Host "opna_bringup.elf found: $elfFile" -ForegroundColor Green

Write-Host "Generating preload binary..."
python "$repoRoot\scripts\build_opna_test_tone.py"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $preload)) {
    Write-Host "FAIL: preload generation failed." -ForegroundColor Red
    exit 1
}
Write-Host "preload found: $preload" -ForegroundColor Green

if ($SkipJtag) {
    Write-Host "Normal preload test stopped because JTAG was skipped." -ForegroundColor Yellow
    exit 0
}

Write-Host "Programming FPGA and running PS software..."
& "$scriptDir\jtag\run_jtag_opna_normal.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: JTAG run failed." -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "Waiting for USB enumeration..."
Start-Sleep -Seconds 3

Write-Host "Checking pyusb visibility..."
$usbCheck = @'
from pathlib import Path
import sys
root = Path(r"J:\lumia\PC98")
pc = root / "opl3_fpga" / "pc_player"
sys.path.insert(0, str(pc))
from protocol import list_usb_devices
devices = list_usb_devices()
print(len(devices))
for dev in devices:
    print(dev.key)
'@
$usbCheckOut = $usbCheck | python -
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: pyusb visibility check failed." -ForegroundColor Red
    exit $LASTEXITCODE
}

$usbLines = @($usbCheckOut | Where-Object { $_ -ne "" })
if ($usbLines.Count -eq 0 -or $usbLines[0] -eq "0") {
    Write-Host "FAIL: VID=0xCAFE PID=0x4012 is present in PnP but not visible to pyusb/libusb." -ForegroundColor Red
    Write-Host "Likely cause: the device is not bound to WinUSB/libusb on Windows." -ForegroundColor Yellow
    Write-Host "Check Device Manager/Zadig for the Zybo OPL3 USB Interface (VID_CAFE PID_4012)." -ForegroundColor Yellow
    Get-PnpDevice | Where-Object { $_.InstanceId -match 'VID_CAFE' -or $_.FriendlyName -match 'Zybo OPL3' } | Select-Object Status,Class,FriendlyName,InstanceId
    exit 1
}

Write-Host "pyusb sees device(s):"
for ($i = 1; $i -lt $usbLines.Count; $i++) {
    Write-Host "  $($usbLines[$i])"
}

Write-Host "Uploading preload..."
python "$repoRoot\scripts\upload_raw_preload.py" --input $preload --play
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: upload/play failed." -ForegroundColor Red
    exit $LASTEXITCODE
}
