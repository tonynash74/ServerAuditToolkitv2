[CmdletBinding(SupportsShouldProcess=$false)]
param(
  [string[]]$ComputerName = $env:COMPUTERNAME,
  [string]  $OutDir = (Join-Path $PSScriptRoot '..\out'),
  [switch]  $NoParallel
)
Import-Module (Join-Path $PSScriptRoot 'ServerAuditToolkitV2.psd1') -Force

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Verbose "[SAT] Starting audit for: $($ComputerName -join ', ')"
$dataset = Invoke-ServerAudit -ComputerName $ComputerName -NoParallel:$NoParallel -Verbose

# Persist
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$dataPath = Join-Path $OutDir "data_$ts.json"
$dataset | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $dataPath
Write-Verbose "[SAT] JSON saved: $dataPath"

# Render report
$report = New-SATReport -Data $dataset -OutDir $OutDir -Timestamp $ts -Verbose:$VerbosePreference
Write-Verbose "[SAT] Done. Reports in $OutDir"
return $dataset
