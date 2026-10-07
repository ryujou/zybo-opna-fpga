param(
    [ValidateRange(1,7)][int]$Phase = 1,
    [ValidateSet('A','B','C','D')][string]$Step = 'D'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
& py -3 -X utf8 (Join-Path $projectRoot 'tools/opna_sim/gate.py') --phase $Phase --step $Step
exit $LASTEXITCODE
