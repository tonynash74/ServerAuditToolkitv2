# Load private helpers
. $PSScriptRoot\Private\Compat.ps1
. $PSScriptRoot\Private\Logging.ps1
. $PSScriptRoot\Private\Parallel.ps1
. $PSScriptRoot\Private\Capability.ps1
. $PSScriptRoot\Private\Report.ps1
. $PSScriptRoot\Private\Migration.ps1


# Dot-source collectors
Get-ChildItem "$PSScriptRoot\Collectors\*.ps1" | ForEach-Object { . $_.FullName }

function Invoke-ServerAudit {
  [CmdletBinding()]
  param([string[]]$ComputerName, [switch]$NoParallel)

  $results = @{}
  $collectors = @(
  'Get-SATSystem',
  'Get-SATRolesFeatures',
  'Get-SATNetwork',
  'Get-SATStorage',
  'Get-SATADDS',
  'Get-SATDNS',
  'Get-SATDHCP',
  'Get-SATIIS',
  'Get-SATHyperV',
  'Get-SATSMB',
  'Get-SATCertificates',
  'Get-SATScheduledTasks',
  'Get-SATLocalAccounts'
)

  Write-Log -Level Info "Planning run. Parallel=$($NoParallel.IsPresent -eq $false)"
  $cap = Get-SATCapability

  $jobs = @()
  foreach ($name in $collectors) {
    $jobs += @{
      Name = $name
      ScriptBlock = {
        param($fn,$targets,$cap)
        & $fn -ComputerName $targets -Capability $cap -Verbose:$VerbosePreference
      }
      Args = @($name,$ComputerName,$cap)
    }
  }

  $collectorOutput = if ($NoParallel) {
    Invoke-Serial -Tasks $jobs
  } else {
    Invoke-RunspaceTasks -Tasks $jobs -Throttle ([Math]::Max(2,[Environment]::ProcessorCount))
  }

  foreach ($entry in $collectorOutput) {
    $results[$entry.Name] = $entry.Data
  }
  $results['Meta'] = @{
    Timestamp = (Get-Date).ToString('o')
    Toolkit   = 'ServerAuditToolkitV2'
    Host      = $env:COMPUTERNAME
    PSVersion = $PSVersionTable.PSVersion.ToString()
  }
  return $results
}
# Ensure $OutDir exists (and has a default)
if (-not $OutDir) {
  $root = Split-Path -Parent $PSScriptRoot
  if ($root -like '*\src') { $root = Split-Path -Parent $root }
  $OutDir = Join-Path $root 'out'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Save the main dataset
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$base = Join-Path $OutDir ("data_{0}" -f $ts)
$null = Export-SATData -Object $results -PathBase $base -Depth 6

# Build Migration Units + Findings
$units    = New-SATMigrationUnits -Data $results
$rules    = Get-SATDefaultReadinessRules
$findings = Evaluate-SATReadiness -Units $units -Rules $rules

# Persist MUs (JSON if available, else CLIXML)
$muBase = Join-Path $OutDir ("migration_units_{0}" -f $ts)
$null = Export-SATData -Object $units -PathBase $muBase -Depth 6

# Ensure CSV dir, then CSVs
$csvDir = Join-Path $OutDir 'csv'
New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
$units    | Select Id,Kind,Server,Name,Summary,Confidence | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $csvDir 'migration_units.csv')
$findings | Select Severity,RuleId,Server,Kind,Name,Message,UnitId | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $csvDir 'readiness_findings.csv')

# Render the report
$null = New-SATReport -Data $results -Units $units -Findings $findings -OutDir $OutDir -Timestamp $ts -Verbose:$VerbosePreference