# ServerAuditToolkitV2.psm1  (PowerShell 2.0+ safe)

# ---- Dot-source private helpers (order matters) ----
. "$PSScriptRoot\Private\Compat.ps1"
. "$PSScriptRoot\Private\Logging.ps1"
. "$PSScriptRoot\Private\Capability.ps1"
. "$PSScriptRoot\Private\Parallel.ps1"
. "$PSScriptRoot\Private\Migration.ps1"
. "$PSScriptRoot\Private\Report.Data.ps1"
. "$PSScriptRoot\Private\Report.ps1"

# ---- Load all collectors ----
$collectorsPath = Join-Path $PSScriptRoot 'Collectors'
if (Test-Path $collectorsPath) {
  Get-ChildItem -Path $collectorsPath -Filter *.ps1 | ForEach-Object { . $_.FullName }
} else {
  Write-Log Warn ("Collectors path not found: {0}" -f $collectorsPath)
}

function Invoke-ServerAudit {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$OutDir,
    [switch]$NoParallel  # kept for CLI compatibility; collectors run sequentially on PS2
  )

  # ---- OutDir default + ensure exists ----
  if (-not $OutDir) {
    $root = Split-Path -Parent $PSScriptRoot
    if ($root -like '*\src') { $root = Split-Path -Parent $root }
    $OutDir = Join-Path $root 'out'
  }
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

  $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
  $global:SAT_LastTimestamp = $ts

  # ---- Initialize logging & transcript files ----
  $satLog = Join-Path $OutDir ("sat_{0}.log" -f $ts)
  Set-SATLogFile -Path $satLog

  $consoleLog = Join-Path $OutDir ("console_{0}.txt" -f $ts)
  Start-SATTranscript -Path $consoleLog

  Write-Log Info ("[SAT] Starting audit for: {0}" -f ($ComputerName -join ','))

  # ---- Remote capability probe (PS2-safe) ----
  $capPerServer = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Capability probe on {0}" -f $c)
      $cap = Invoke-Command -ComputerName $c -ScriptBlock {
        $o = @{}
        if ($PSVersionTable) { $o['PSVersion'] = $PSVersionTable.PSVersion.Major } else { $o['PSVersion'] = 2 }
        $o['HasServerMgr']      = [bool](Get-Module -ListAvailable -Name ServerManager -ErrorAction SilentlyContinue)
        $o['HasDnsModule']      = [bool](Get-Module -ListAvailable -Name DnsServer -ErrorAction SilentlyContinue) -or [bool](Get-Module -ListAvailable -Name DNS -ErrorAction SilentlyContinue)
        $o['HasDhcpModule']     = [bool](Get-Module -ListAvailable -Name DhcpServer -ErrorAction SilentlyContinue)
        $o['HasIISModule']      = [bool](Get-Module -ListAvailable -Name WebAdministration -ErrorAction SilentlyContinue)
        $o['HasHyperVModule']   = [bool](Get-Module -ListAvailable -Name Hyper-V -ErrorAction SilentlyContinue)
        $o['HasSmbModule']      = [bool](Get-Command Get-SmbShare -ErrorAction SilentlyContinue) -or [bool](Get-Module -ListAvailable -Name SmbShare -ErrorAction SilentlyContinue)
        $o['HasADModule']       = [bool](Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
        $o['HasNetTCPIP']       = [bool](Get-Module -ListAvailable -Name NetTCPIP -ErrorAction SilentlyContinue)
        $o['HasNetLbfo']        = [bool](Get-Module -ListAvailable -Name NetLbfo -ErrorAction SilentlyContinue)
        $o['HasStorage']        = [bool](Get-Module -ListAvailable -Name Storage -ErrorAction SilentlyContinue)
        $o['HasScheduledTasks'] = [bool](Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)
        $o['HasLocalAccounts']  = [bool](Get-Command Get-LocalUser -ErrorAction SilentlyContinue)
        $o['HasPrintModule']    = [bool](Get-Module -ListAvailable -Name PrintManagement -ErrorAction SilentlyContinue)
        return $o
      }
      $capPerServer[$c] = $cap
    } catch {
      Write-Log Warn ("Capability probe failed on {0}: {1}" -f $c, $_.Exception.Message)
      $capPerServer[$c] = @{ PSVersion=2 }
    }
  }

  # ---- Run collectors (sequential; PS2-stable) ----
  $collectorNames = @(
    'Get-SATSystem','Get-SATRolesFeatures','Get-SATNetwork','Get-SATStorage',
    'Get-SATADDS','Get-SATDNS','Get-SATDHCP','Get-SATSMB',
    'Get-SATIIS','Get-SATHyperV','Get-SATCertificates','Get-SATScheduledTasks',
    'Get-SATLocalAccounts','Get-SATPrinters','Get-SATDataDiscovery'
  )

  $results = @{}
  foreach ($fn in $collectorNames) {
    if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { continue }
    Write-Log Info ("Collector: {0}" -f $fn)
    $results[$fn] = @{}
    foreach ($c in $ComputerName) {
      try {
        $cap = $capPerServer[$c]
        $part = & $fn -ComputerName @($c) -Capability $cap
        if ($part -and ($part -is [hashtable]) -and $part.ContainsKey($c)) {
          $results[$fn][$c] = $part[$c]
        } else {
          $results[$fn][$c] = $part
        }
      } catch {
        Write-Log Error ("Collector {0} failed on {1}: {2}" -f $fn,$c,$_.Exception.Message)
        $results[$fn][$c] = @{ Error = $_.Exception.Message }
      }
    }
  }

  # ---- Persist dataset (JSON if available, else CLIXML) ----
  $base = Join-Path $OutDir ("data_{0}" -f $ts)
  try {
    $null = Export-SATData -Object $results -PathBase $base -Depth 6
    Write-Log Info ("[SAT] Data saved: {0}.(json|clixml)" -f ("$base"))
  } catch {
    Write-Log Warn ("[SAT] Could not persist data: {0}" -f $_.Exception.Message)
  }

  # ---- Migration units + findings ----
  $units    = $null
  $rules    = $null
  $findings = $null
  try { $units    = New-SATMigrationUnits -Data $results } catch { Write-Log Warn ("Migration units failed: {0}" -f $_.Exception.Message) }
  try { $rules    = Get-SATDefaultReadinessRules }         catch { $rules = @() }
  try { if ($units) { $findings = Evaluate-SATReadiness -Units $units -Rules $rules } } catch { Write-Log Warn ("Readiness evaluation failed: {0}" -f $_.Exception.Message) }

  # ---- Persist MU & Findings CSVs ----
  try {
    $muBase = Join-Path $OutDir ("migration_units_{0}" -f $ts)
    $null = Export-SATData -Object $units -PathBase $muBase -Depth 6
    $csvDir = Join-Path $OutDir 'csv'
    New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
    if ($units)    { $units    | Select Id,Kind,Server,Name,Summary,Confidence | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $csvDir 'migration_units.csv') }
    if ($findings) { $findings | Select Severity,RuleId,Server,Kind,Name,Message,UnitId     | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $csvDir 'readiness_findings.csv') }
  } catch {
    Write-Log Warn ("[SAT] Failed to export migration CSVs: {0}" -f $_.Exception.Message)
  }

  # ---- Linked Data Discovery report (before main, so link exists) ----
  try { $null = New-SATDataDiscoveryReport -Data $results -OutDir $OutDir -Timestamp $ts } catch { Write-Log Warn ("Data Discovery report failed: {0}" -f $_.Exception.Message) }

  # ---- HTML Report ----
  try { $null = New-SATReport -Data $results -Units $units -Findings $findings -OutDir $OutDir -Timestamp $ts } catch { Write-Log Warn ("Main report failed: {0}" -f $_.Exception.Message) }

  # ---- Close transcript (best-effort) ----
  Stop-SATTranscript

  Write-Log Info ("[SAT] Done. See outputs in {0}" -f $OutDir)
  return $results
}

# Explicit export (manifest also lists these)
Export-ModuleMember -Function `
  Invoke-ServerAudit, `
  Get-SATSystem,Get-SATRolesFeatures,Get-SATNetwork,Get-SATStorage, `
  Get-SATADDS,Get-SATDNS,Get-SATDHCP,Get-SATSMB, `
  Get-SATIIS,Get-SATHyperV,Get-SATCertificates,Get-SATScheduledTasks, `
  Get-SATLocalAccounts,Get-SATPrinters,Get-SATDataDiscovery, `
  Export-SATData,Write-SATCsv,New-SATReport,New-SATDataDiscoveryReport, `
  Get-SATDefaultReadinessRules,New-SATMigrationUnits,Evaluate-SATReadiness
# ---- EOF ----
