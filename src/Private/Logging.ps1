# Private/Logging.ps1  (PowerShell 2.0+ safe)
# Centralized logging used by all collectors/orchestrator.

# Globals (runtime-initialized)
$global:SAT_LogFile = $null
$global:SAT_TranscriptActive = $false

function Set-SATLogFile {
  param([Parameter(Mandatory=$true)][string]$Path)
  try {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $global:SAT_LogFile = $Path
    $hdr = ("==== ServerAuditToolkitV2 Log - {0} ====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $hdr | Out-File -FilePath $global:SAT_LogFile -Encoding Unicode
  } catch {
    Write-Host ("[WARN] Unable to initialize log file: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    $global:SAT_LogFile = $null
  }
}

function Start-SATTranscript {
  param([Parameter(Mandatory=$true)][string]$Path)
  try {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $hasCmd = (Get-Command Start-Transcript -ErrorAction SilentlyContinue) -ne $null
    if ($hasCmd) {
      Start-Transcript -Path $Path | Out-Null
      $global:SAT_TranscriptActive = $true
    }
  } catch {
    # Silent; transcript is best-effort
    $global:SAT_TranscriptActive = $false
  }
}

function Stop-SATTranscript {
  try {
    if ($global:SAT_TranscriptActive) {
      Stop-Transcript | Out-Null
    }
  } catch {}
  $global:SAT_TranscriptActive = $false
}

function Write-Log {
  param(
    [Parameter(Mandatory=$true)][ValidateSet('Info','Warn','Error')] [string]$Level,
    [Parameter(Mandatory=$true)] [string]$Message
  )
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
  $line = "[{0}][{1}] {2}" -f $ts, $Level, $Message

  # Console with color
  switch ($Level) {
    'Info'  { Write-Host $line -ForegroundColor Gray }
    'Warn'  { Write-Host $line -ForegroundColor Yellow }
    'Error' { Write-Host $line -ForegroundColor Red }
  }

  # File
  if ($global:SAT_LogFile) {
    try { Add-Content -Path $global:SAT_LogFile -Value $line } catch {}
  }
}
