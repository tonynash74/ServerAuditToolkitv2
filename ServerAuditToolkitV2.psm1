# Load private helpers
. $PSScriptRoot\Private\Logging.ps1
. $PSScriptRoot\Private\Parallel.ps1
. $PSScriptRoot\Private\Capability.ps1
. $PSScriptRoot\Private\Report.ps1

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
Export-ModuleMember -Function Invoke-ServerAudit,Get-SAT*
