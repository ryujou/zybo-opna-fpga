param(
    [string]$XsctPath = "",
    [string]$BitstreamDir = "",
    [string]$ElfPath = "",
    [string]$PreloadBin = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path "$scriptDir\..\.."

if ($XsctPath -eq "") {
    $candidates = @(
        "$env:XILINX_VITIS\bin\xsct.bat",
        "J:\FPGA\2025.2\Vitis\bin\xsct.bat",
        "C:\Xilinx\Vitis\2025.2\bin\xsct.bat"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $XsctPath = $c
            break
        }
    }
}

if ($XsctPath -eq "" -or !(Test-Path $XsctPath)) {
    Write-Host "ERROR: xsct.bat not found." -ForegroundColor Red
    exit 1
}

$env:BITSTREAM_DIR = if ($BitstreamDir) { $BitstreamDir } else { "$repoRoot\build\bitstreams" }
$env:ELF_PATH = if ($ElfPath) { $ElfPath } else { "$repoRoot\build\software\opna_bringup.elf" }
$preloadPath = if ($PreloadBin) { $PreloadBin } else { "$repoRoot\build\opna_test_tone.bin" }

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "OPNA NORMAL PRELOAD SMOKE TEST" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if (!(Test-Path "$env:BITSTREAM_DIR\opna_normal.bit")) {
    Write-Host "FAIL: $env:BITSTREAM_DIR\opna_normal.bit not found" -ForegroundColor Red
    exit 1
}
Write-Host "bitstream found"

if (!(Test-Path $env:ELF_PATH)) {
    Write-Host "FAIL: $env:ELF_PATH not found" -ForegroundColor Red
    exit 1
}
Write-Host "opna_bringup.elf found"

if (!(Test-Path $preloadPath)) {
    Write-Host "FAIL: preload not found: $preloadPath" -ForegroundColor Red
    exit 1
}
Write-Host "preload found"

Write-Host "Programming FPGA and running PS via XSCT..."
& cmd /c "$XsctPath $scriptDir\program_opna_normal.tcl"
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: XSCT returned $LASTEXITCODE" -ForegroundColor Red
    exit $LASTEXITCODE
}
