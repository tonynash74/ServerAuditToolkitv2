[CmdletBinding(SupportsShouldProcess=$false)]
param(
  [string[]]$ComputerName = $env:COMPUTERNAME,
  [string]  $OutDir,
  [switch]  $NoParallel
)

# Robust script root (works even if $PSScriptRoot is null)
$ScriptRoot = if ($PSVersionTable.PSVersion.Major -ge 3 -and $PSScriptRoot) {
  $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
  Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
  (Get-Location).Path
}

# Find the module manifest from common locations (root, src, parent\src) or by search
$manifestCandidates = @(
  (Join-Path $ScriptRoot 'ServerAuditToolkitV2.psd1'),
  (Join-Path $ScriptRoot 'src\ServerAuditToolkitV2.psd1'),
  (Join-Path (Split-Path -Parent $ScriptRoot) 'src\ServerAuditToolkitV2.psd1')
) + (Get-ChildItem -Path $ScriptRoot -Filter 'ServerAuditToolkitV2.psd1' -Recurse -ErrorAction SilentlyContinue |
     Select-Object -First 1 -ExpandProperty FullName)

$manifest = $manifestCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $manifest) {
  throw "Cannot find ServerAuditToolkitV2.psd1 relative to '$ScriptRoot'. Ensure the repo layout is intact."
}

# Compute repo root so OutDir defaults to ...\out regardless of where this wrapper lives
$repoRoot = Split-Path -Parent $manifest
if ($repoRoot -like '*\src') { $repoRoot = Split-Path -Parent $repoRoot }
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'out' }

Import-Module $manifest -Force

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Write-Verbose "[SAT] Starting audit for: $($ComputerName -join ', ')"

# Run the orchestrator in the module
$dataset = Invoke-ServerAudit -ComputerName $ComputerName -OutDir $OutDir -NoParallel:$NoParallel -Verbose

# Persist JSON if the module didn’t already
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$base = Join-Path $OutDir "data_$ts"
try {
  if (Get-Command Export-SATData -ErrorAction SilentlyContinue) {
    $null = Export-SATData -Object $dataset -PathBase $base -Depth 6
  } elseif (Get-Command ConvertTo-Json -ErrorAction SilentlyContinue) {
    $dataset | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path ($base + '.json')
  } else {
    $dataset | Export-Clixml -Path ($base + '.clixml')
  }
  Write-Verbose "[SAT] Data saved: $base.(json|clixml)"
} catch {
  Write-Warning "[SAT] Could not persist data: $($_.Exception.Message)"
}

Write-Verbose "[SAT] Done. See outputs in $OutDir"
return $dataset
