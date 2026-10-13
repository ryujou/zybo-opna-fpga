param(
    [ValidateRange(1,7)][int]$Phase = 1,
    [ValidateSet('A','B','C','D')][string]$Step = 'D',
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$gateArgs = @('--phase', $Phase, '--step', $Step)
if ($Offline) { $gateArgs += '--offline' }
& py -3 -X utf8 (Join-Path $projectRoot 'tools/opna_sim/gate.py') @gateArgs
exit $LASTEXITCODE
