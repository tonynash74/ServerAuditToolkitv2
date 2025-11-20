# ServerAuditToolkitV2.psm1  (PS2-safe)

# ---------- Module Root ----------
$script:ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------- Dot-source Private helpers FIRST (PS2-safe: no -File) ----------
$privateDir = Join-Path $script:ModuleRoot 'Private'
if (Test-Path $privateDir) {
  Get-ChildItem -Path $privateDir -Filter *.ps1 | Where-Object { -not $_.PSIsContainer } | Sort-Object Name | ForEach-Object {
    . $_.FullName
  }
}

# ---------- Dot-source Collectors (PS2-safe: no -File) ----------
$collectDir = Join-Path $script:ModuleRoot 'Collectors'
$script:CollectorFiles = @()
if (Test-Path $collectDir) {
  $script:CollectorFiles = Get-ChildItem -Path $collectDir -Filter *.ps1 | Where-Object { -not $_.PSIsContainer } | Sort-Object Name
  foreach ($f in $script:CollectorFiles) { . $f.FullName }
}

# ---------- Safe helpers (fallbacks if Private\Compat wasn’t loaded) ----------
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
  function Write-Log {
    param([string]$Level,[string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    Write-Verbose ("[{0}][{1}] {2}" -f $ts,$Level,$Message)
  }
}

# ---------- Capability probe ----------
function Get-SATCapability {
  [CmdletBinding()]
  param([string[]]$ComputerName)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      $scr = {
        $cap = @{
          PSVersion   = $PSVersionTable.PSVersion.ToString()
          HasIISMod   = $false
          HasDhcpMod  = $false
          HasSmbCmd   = $false
          HasHyperV   = $false
          AppCmdPath  = $null
          WebAdmin    = $false
          Notes       = ''
        }
        try { if (Get-Module -ListAvailable WebAdministration){ $cap.WebAdmin=$true; $cap.HasIISMod=$true } } catch {}
        try { if (Get-Module -ListAvailable DhcpServer)      { $cap.HasDhcpMod=$true } } catch {}
        try { if (Get-Command Get-SmbShare -ErrorAction SilentlyContinue) { $cap.HasSmbCmd=$true } } catch {}
        try { if (Get-Command Get-VM      -ErrorAction SilentlyContinue) { $cap.HasHyperV=$true } } catch {}
        try {
          $sys = $env:SystemRoot
          $ap  = Join-Path $sys 'System32\inetsrv\appcmd.exe'
          if (Test-Path $ap) { $cap.AppCmdPath = $ap }
        } catch {}
        return $cap
      }
      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } catch {
      $out[$c] = @{ PSVersion=''; HasIISMod=$false; HasDhcpMod=$false; HasSmbCmd=$false; HasHyperV=$false; AppCmdPath=$null; WebAdmin=$false; Notes='capability error' }
    }
  }
  return $out
}

# ---------- Orchestrator ----------
function Invoke-ServerAudit {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string[]]$ComputerName,
    [string]$OutDir,
    [switch]$NoParallel,
    [int]$Throttle = 4,
    [string[]]$Include,
    [string[]]$Exclude
  )

  if (-not $OutDir -or $OutDir.Trim().Length -eq 0) {
    $OutDir = Join-Path (Split-Path -Parent $script:ModuleRoot) 'out'
  }
  if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

  $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
  $global:SAT_LastTimestamp = $ts

  Write-Log Info ("[SAT] Starting audit for: {0}" -f ((@($ComputerName) -join ', ')))

  # Transcript (best-effort)
  try {
    $transPath = Join-Path $OutDir ("console_{0}.txt" -f $ts)
    Start-Transcript -Path $transPath -Force | Out-Null
  } catch {}

  # Capability
  Write-Log Info ("[{0}][Info] Capability probe on {1}" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss.fff'), (@($ComputerName) -join ', '))
  $cap = Get-SATCapability -ComputerName $ComputerName

  # Discover collectors (all Get-SAT* except capability)
  $allCollectors = @()
  $loaded = Get-Command -CommandType Function | Where-Object { $_.Name -like 'Get-SAT*' } | Select-Object -ExpandProperty Name
  foreach ($n in $loaded) { if ($n -ne 'Get-SATCapability') { $allCollectors += $n } }
  $allCollectors = $allCollectors | Sort-Object

  # Include/Exclude
  $collectorNames = @()
  if ($Include -and $Include.Count -gt 0) {
    foreach ($i in $Include) { if ($allCollectors -contains $i) { $collectorNames += $i } }
  } else {
    $collectorNames = $allCollectors
  }
  if ($Exclude -and $Exclude.Count -gt 0) {
    $tmp = @()
    foreach ($n in $collectorNames) { if ($Exclude -notcontains $n) { $tmp += $n } }
    $collectorNames = $tmp
  }

  # Build run list
  $results = @{}
  $runItems = @()
  foreach ($cn in $collectorNames) {
    $runItems += @{
      Name   = $cn
      Script = {
        param($fn,$targets,$capRef)
        try {
          Write-Log Info ("Collector: {0}" -f $fn)
          $res = & $fn -ComputerName $targets -Capability $capRef
          return @{ Name=$fn; Data=$res; Error=$null }
        } catch {
          return @{ Name=$fn; Data=$null; Error=$_.Exception.Message }
        }
      }
      Args   = @($cn,$ComputerName,$cap)
    }
  }

  if ($NoParallel) {
    foreach ($it in $runItems) {
      # PS2-safe: NO splatting. Pass positionally.
      $arg0 = $it.Args[0]; $arg1 = $it.Args[1]; $arg2 = $it.Args[2]
      $r = & $it.Script $arg0 $arg1 $arg2
      if ($r.Error) { Write-Log Error ("{0} failed: {1}" -f $r.Name,$r.Error) }
      $results[$r.Name] = $r.Data
    }
  } else {
    if (Get-Command Invoke-RunspaceTasks -ErrorAction SilentlyContinue) {
      $jobs = @()
      foreach ($it in $runItems) {
        $jobs += @{ ScriptBlock = $it.Script; Arguments = $it.Args }
      }
      $out = Invoke-RunspaceTasks -Tasks $jobs -Throttle $Throttle
      foreach ($r in $out) {
        if ($r -and $r.Name) {
          if ($r.Error) { Write-Log Error ("{0} failed: {1}" -f $r.Name,$r.Error) }
          $results[$r.Name] = $r.Data
        }
      }
    } else {
      # Fallback sequential (PS2-safe)
      foreach ($it in $runItems) {
        $arg0 = $it.Args[0]; $arg1 = $it.Args[1]; $arg2 = $it.Args[2]
        $r = & $it.Script $arg0 $arg1 $arg2
        if ($r.Error) { Write-Log Error ("{0} failed: {1}" -f $r.Name,$r.Error) }
        $results[$r.Name] = $r.Data
      }
    }
  }

  # Persist raw dataset
  try {
    $base = Join-Path $OutDir ("data_{0}" -f $ts)
    if (Get-Command Export-SATData -ErrorAction SilentlyContinue) {
      $null = Export-SATData -Object $results -PathBase $base -Depth 6
    } else {
      $results | Export-Clixml -Path ($base + '.clixml')
    }
  } catch {
    Write-Log Warn ("[SAT] Could not persist data: {0}" -f $_.Exception.Message)
  }

  # Migration units & readiness
  $units=@(); $rules=@(); $findings=@()
  if (Get-Command New-SATMigrationUnits -ErrorAction SilentlyContinue) {
    try { $units = New-SATMigrationUnits -Data $results } catch { Write-Log Warn ("Units failed: {0}" -f $_.Exception.Message) }
  }
  if (Get-Command Get-SATDefaultReadinessRules -ErrorAction SilentlyContinue) { try { $rules = Get-SATDefaultReadinessRules } catch {} }
  if ($units -and $rules -and (Get-Command Evaluate-SATReadiness -ErrorAction SilentlyContinue)) {
    try { $findings = Evaluate-SATReadiness -Units $units -Rules $rules } catch { Write-Log Warn ("Readiness failed: {0}" -f $_.Exception.Message) }
  }

  # Save MU/Findings CSVs
  try {
    $csvDir = Join-Path $OutDir 'csv'
    if (-not (Test-Path $csvDir)) { New-Item -ItemType Directory -Force -Path $csvDir | Out-Null }
    if ($units -and (Get-Command Write-SATCsv -ErrorAction SilentlyContinue)) {
      Write-SATCsv -OutDir $csvDir -Name 'migration_units' -Rows ($units | Select Id,Kind,Server,Name,Summary,Confidence)
    }
    if ($findings -and (Get-Command Write-SATCsv -ErrorAction SilentlyContinue)) {
      Write-SATCsv -OutDir $csvDir -Name 'readiness_findings' -Rows ($findings | Select Severity,RuleId,Server,Kind,Name,Message,UnitId)
    }
  } catch {}

  # Report
  if (Get-Command New-SATReport -ErrorAction SilentlyContinue) {
    try { $null = New-SATReport -Data $results -Units $units -Findings $findings -OutDir $OutDir -Timestamp $ts } catch { Write-Log Error ("Report failed: {0}" -f $_.Exception.Message) }
  }

  # Stop transcript
  try { Stop-Transcript | Out-Null } catch {}

  Write-Log Info ("[SAT] Done. See outputs in {0}" -f $OutDir)
  return $results
}

# filepath: c:\.GitLocal\ServerAuditToolkitv2\src\ServerAuditToolkitV2.psm1
# Import core functions
. $PSScriptRoot\core\Get-CollectorMetadata.ps1
. $PSScriptRoot\core\Get-ServerCapabilities.ps1
. $PSScriptRoot\core\Invoke-ServerAudit.ps1
# ... existing imports ...

# Ensure all functions are exported
Export-ModuleMember -Function @(
    # T1: Collector Framework
    'Invoke-ServerAudit'
    'Get-CollectorMetadata'
    'Get-CompatibleCollectors'
    'Get-CompatibleCollectorsByOS'
    'Get-CollectorVariant'
    'Test-CollectorDependencies'
    'Get-WindowsVersionFromBuild'
    'Get-CollectorSummary'
    
    # T2: Performance Profiler
    'Get-ServerCapabilities'
    'Get-ProcessorInfo'
    'Get-RAMInfo'
    'Get-DiskPerformance'
    'Test-NetworkConnectivity'
    'Get-SystemLoad'
    'Calculate-ParallelismBudget'
    
    # ... existing exports ...
)

# ---------- Export ----------
#$exports = @('Invoke-ServerAudit','Write-SATCsv','New-SATReport','Get-SATCapability')
#$exports += (Get-Command -CommandType Function | Where-Object { $_.Name -like 'Get-SAT*' } | Select-Object -ExpandProperty Name)
#$exports = $exports | Sort-Object -Unique
#Export-ModuleMember -Function $exports 
#