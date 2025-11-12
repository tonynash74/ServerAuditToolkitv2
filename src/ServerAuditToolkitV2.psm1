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
# Persist dataset using compat exporter (JSON if possible, else CLIXML)
$global:SAT_LastTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$base = Join-Path $OutDir ("data_{0}" -f $global:SAT_LastTimestamp)
$null = Export-SATData -Object $results -PathBase $base -Depth 6

# Build Migration Units
$units = New-SATMigrationUnits -Data $results

# Load rules (use default for now; later add -RulesPath param to Invoke-ServerAudit)
$rules = Get-SATDefaultReadinessRules
$findings = Evaluate-SATReadiness -Units $units -Rules $rules

# Persist MU + findings (JSON + CSV)
$muJson = Join-Path $OutDir "migration_units_$ts.json"
$units | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $muJson

$csvDir = Join-Path $OutDir 'csv'; New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
$units | Select Id,Kind,Server,Name,Summary,Confidence | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $csvDir 'migration_units.csv')
$findings | Select Severity,RuleId,Server,Kind,Name,Message,UnitId | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $csvDir 'readiness_findings.csv')

# Render report (pass Units & Findings along)
$report = New-SATReport -Data $results -Units $units -Findings $findings -OutDir $OutDir -Timestamp $ts -Verbose:$VerbosePreference

Export-ModuleMember -Function Invoke-ServerAudit,Get-SAT*
