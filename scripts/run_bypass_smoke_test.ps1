param([switch]$SkipJtag)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path "$scriptDir\.."
$bitFile = "$repoRoot\build\bitstreams\opna_bypass_on.bit"
$elfFile = "$repoRoot\build\software\opna_bringup.elf"
$ps7Candidates = @(
    "$repoRoot\build\vivado_zybo_opna\zybo_opna.gen\sources_1\bd\opna_cpu\ip\opna_cpu_processing_system7_0_0\ps7_init.tcl",
    "$repoRoot\build\xsa\ps7_init.tcl",
    "$repoRoot\build\vitis_ws\opna_plat\hw\ps7_init.tcl"
)
$ps7Init = $ps7Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$marker = "$repoRoot\build\bypass_smoke.ok"
$uartDeviceId = 'VID_0403+PID_6010+210279540276B'

function Get-ZyboComPort {
    $port = Get-CimInstance Win32_PnPEntity | Where-Object {
        $_.PNPDeviceID -match [regex]::Escape($uartDeviceId)
    } | Select-Object -First 1
    if (-not $port) { return $null }
    if ($port.Name -match '\(COM\d+\)') {
        return $matches[0].Trim('()')
    }
    return $null
}

function Invoke-JtagWithSerialCapture {
    param([int]$TimeoutMs = 2500)

    $comPort = Get-ZyboComPort
    $exitCode = 0
    if (-not $comPort) {
        Write-Host "WARN: Zybo UART COM port not found." -ForegroundColor Yellow
        & "$scriptDir\jtag\run_jtag_bypass_on.ps1"
        return $LASTEXITCODE
    }

    $port = $null
    try {
        $port = [System.IO.Ports.SerialPort]::new($comPort, 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
        $port.ReadTimeout = 250
        $port.Open()
        Start-Sleep -Milliseconds 150
        $port.DiscardInBuffer()

        & "$scriptDir\jtag\run_jtag_bypass_on.ps1"
        $exitCode = $LASTEXITCODE

        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        $log = New-Object System.Text.StringBuilder
        while ([DateTime]::UtcNow -lt $deadline) {
            $chunk = $port.ReadExisting()
            if ($chunk) {
                [void]$log.Append($chunk)
            }
            Start-Sleep -Milliseconds 50
        }

        $text = $log.ToString()
        if ($text.Length -gt 0) {
            Write-Host "UART log:" -ForegroundColor Cyan
            Write-Host $text
        } else {
            Write-Host "WARN: no UART output captured from $comPort." -ForegroundColor Yellow
        }
    } finally {
        if ($port) {
            if ($port.IsOpen) { $port.Close() }
            $port.Dispose()
        }
    }

    return $exitCode
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "BYPASS TONE SMOKE CHECK" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$allOk = $true

if (Test-Path $bitFile) {
    Write-Host "opna_bypass_on.bit found: $bitFile" -ForegroundColor Green
} else {
    Write-Host "FAIL: bitstream missing: $bitFile" -ForegroundColor Red
    $allOk = $false
}

if (Test-Path $elfFile) {
    Write-Host "opna_bringup.elf found: $elfFile" -ForegroundColor Green
} else {
    Write-Host "FAIL: ELF missing: $elfFile" -ForegroundColor Red
    $allOk = $false
}

if ($ps7Init) {
    Write-Host "ps7_init.tcl found: $ps7Init" -ForegroundColor Green
} else {
    Write-Host "FAIL: ps7_init.tcl missing" -ForegroundColor Red
    $allOk = $false
}

if (-not $allOk) {
    Write-Host "Smoke test stopped because required files are missing." -ForegroundColor Red
    exit 1
}

if (-not $SkipJtag) {
    Write-Host "Programming FPGA and running PS software..."
    $jtagExit = Invoke-JtagWithSerialCapture
    if ($jtagExit -ne 0) {
        Write-Host "FAIL: JTAG run failed." -ForegroundColor Red
        exit $jtagExit
    }
} else {
    Write-Host "JTAG step skipped."
}

Write-Host ""
Write-Host "Check XSCT/UART output for:"
Write-Host "  BOOT"
Write-Host "  codec init begin"
Write-Host "  codec init ok"
Write-Host "  usb/session begin"
Write-Host ""
Write-Host "LED expectation:"
Write-Host "  led[0] blink, led[1] off, led[2] on, led[3] optional"

$answer = Read-Host "Did you hear bypass tone? [Y/N]"
if ($answer -match '^[Yy]') {
    Set-Content -Path $marker -Value "bypass_ok"
    Write-Host "Recorded bypass success: $marker" -ForegroundColor Green
} else {
    if (Test-Path $marker) {
        Remove-Item $marker -Force
    }
    Write-Host "Bypass not confirmed. Normal preload test must not run." -ForegroundColor Yellow
}
