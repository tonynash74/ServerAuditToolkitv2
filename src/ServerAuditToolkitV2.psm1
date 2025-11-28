# ServerAuditToolkitV2.psm1  (PS2-safe)

# ---------- Module Root ----------
$script:ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ModuleInstallRoot = Split-Path -Parent $script:ModuleRoot

# ---------- Health / Structure Check ----------
try {
  $manifestPath = Join-Path $script:ModuleInstallRoot 'ServerAuditToolkitV2.psd1'
  $expectedDirs = @('Collectors','Private') | ForEach-Object { Join-Path $script:ModuleRoot $_ }
  $issues = @()
  if (-not (Test-Path -LiteralPath $manifestPath)) { $issues += "Missing manifest at $manifestPath" }
  foreach ($d in $expectedDirs) { if (-not (Test-Path -LiteralPath $d)) { $issues += "Missing directory: $d" } }
  if ($issues.Count -gt 0) {
    $msg = "[ServerAuditToolkitV2] Structural issues detected:`n - " + ($issues -join "`n - ")
    Write-Warning $msg
    try {
      $logFile = Join-Path $script:ModuleInstallRoot 'module_health.log'
      Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
    } catch {}
  }
} catch {
  Write-Warning "[ServerAuditToolkitV2] Health check failed: $($_.Exception.Message)"
}

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

# ---------- Safe helpers (fallbacks if Private\Compat wasn't loaded) ----------
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

function ConvertTo-ScriptArgumentList {
  param(
    [hashtable]$Parameters
  )

  $list = @()
  if (-not $Parameters) { return $list }

  foreach ($key in $Parameters.Keys) {
    $value = $Parameters[$key]
    if ($value -is [System.Management.Automation.SwitchParameter]) {
      if ($value.IsPresent) { $list += ('-{0}' -f $key) }
      continue
    }

    if ($null -eq $value) { continue }

    if (($value -is [System.Array]) -and -not ($value -is [string])) {
      foreach ($item in $value) {
        $list += ('-{0}' -f $key)
        $list += $item
      }
      continue
    }

    $list += ('-{0}' -f $key)
    $list += $value
  }

  return $list
}

# ---------- Orchestrator ----------
function Invoke-ServerAudit {
  [CmdletBinding(DefaultParameterSetName='Default', SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory=$false, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
    [Alias('Name', 'Server')]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [Parameter(Mandatory=$false)]
    [string[]]$Collectors,

    [Parameter(Mandatory=$false)]
    [ValidateSet('2.0', '4.0', '5.1', '7.0')]
    [string]$CollectorPSVersion,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [ValidateRange(0, 16)]
    [int]$MaxParallelJobs = 0,

    [Parameter(Mandatory=$false)]
    [switch]$SkipPerformanceProfile,

    [Parameter(Mandatory=$false)]
    [switch]$UseCollectorCache = $true,

    [Parameter(Mandatory=$false)]
    [string]$CollectorPath,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = (Join-Path -Path $PWD -ChildPath 'audit_results'),

    [Parameter(Mandatory=$false)]
    [ValidateSet('Verbose', 'Information', 'Warning', 'Error')]
    [string]$LogLevel = 'Information',

    [Parameter(Mandatory=$false)]
    [switch]$UseBatchProcessing,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 100)]
    [int]$BatchSize = 10,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 5)]
    [int]$PipelineDepth = 2,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 50)]
    [int]$CheckpointInterval = 5,

    [Parameter(Mandatory=$false)]
    [string]$BatchOutputPath,

    [Parameter(Mandatory=$false)]
    [switch]$EnableStreaming,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 100)]
    [int]$StreamBufferSize = 10,

    [Parameter(Mandatory=$false)]
    [ValidateRange(5, 300)]
    [int]$StreamFlushIntervalSeconds = 30,

    [Parameter(Mandatory=$false)]
    [switch]$EnableStreamingMemoryMonitoring,

    [Parameter(Mandatory=$false)]
    [ValidateRange(50, 1000)]
    [int]$StreamingMemoryThresholdMB = 200,

    [Parameter(Mandatory=$false)]
    [string]$StreamOutputPath
  )

  $scriptCandidates = @(
    Join-Path $script:ModuleInstallRoot 'Invoke-ServerAudit.ps1'
    Join-Path $script:ModuleRoot 'Invoke-ServerAudit.ps1'
    Join-Path (Split-Path -Parent $script:ModuleInstallRoot) 'Invoke-ServerAudit.ps1'
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

  $scriptPath = $null
  if ($scriptCandidates -and $scriptCandidates.Count -gt 0) {
    $scriptPath = $scriptCandidates | Select-Object -First 1
  }

  if (-not $scriptPath) {
    throw "Invoke-ServerAudit.ps1 could not be located relative to module root ($script:ModuleInstallRoot)."
  }

  $argumentList = ConvertTo-ScriptArgumentList -Parameters $PSBoundParameters

  $previousSkip = $env:SAT_SKIP_SATV2_MODULE_IMPORT
  try {
    $env:SAT_SKIP_SATV2_MODULE_IMPORT = '1'
    return & $scriptPath @argumentList
  } finally {
    if ($null -eq $previousSkip) {
      Remove-Item Env:SAT_SKIP_SATV2_MODULE_IMPORT -ErrorAction SilentlyContinue
    } else {
      $env:SAT_SKIP_SATV2_MODULE_IMPORT = $previousSkip
    }
  }
}

# Note: collectors and private helpers are dot-sourced above from the 'Private' and 'Collectors' folders.
# The legacy 'core\' folder is not used in this layout; avoid sourcing non-existent files which
# break module import. If you have additional core scripts, place them under 'Private' or 'Collectors'.

# Ensure all functions are exported
Export-ModuleMember -Function @(
    # Public API
    'Invoke-ServerAudit'
    
    # T1: Collector Framework
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
)

# ---------- Export ----------
#$exports = @('Invoke-ServerAudit','Write-SATCsv','New-SATReport','Get-SATCapability')
#$exports += (Get-Command -CommandType Function | Where-Object { $_.Name -like 'Get-SAT*' } | Select-Object -ExpandProperty Name)
#$exports = $exports | Sort-Object -Unique
#Export-ModuleMember -Function $exports 
#