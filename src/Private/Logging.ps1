# Private/Logging.ps1  (PowerShell 2.0+ safe)
# Centralized logging used by all collectors/orchestrator.
# Supports: Console output, file-based logging, JSON structured logging

# Globals (runtime-initialized)
$global:SAT_LogFile = $null
$global:SAT_LogFormat = 'text'  # 'text' or 'json'
$global:SAT_LogLevel = 'Information'  # 'Verbose', 'Information', 'Warning', 'Error'
$global:SAT_LogSessionId = $null
$global:SAT_TranscriptActive = $false
$global:SAT_LogRotationConfig = @{
  MaxFileSizeMB = 10
  MaxFileCount = 5
}

function Set-SATLogFile {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$false)][string]$Format = 'text',
    [Parameter(Mandatory=$false)][string]$SessionId = [guid]::NewGuid().ToString()
  )
  try {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $global:SAT_LogFile = $Path
    $global:SAT_LogFormat = $Format
    $global:SAT_LogSessionId = $SessionId
    
    # Initialize log file
    $hdr = ("==== ServerAuditToolkitV2 Log - {0} ====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    if ($Format -eq 'json') {
      $logHeader = @{
        timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ'
        sessionId = $SessionId
        level = 'Info'
        message = 'Log session started'
      } | ConvertTo-Json -Compress
      $logHeader | Out-File -FilePath $global:SAT_LogFile -Encoding UTF8 -Force
    } else {
      $hdr | Out-File -FilePath $global:SAT_LogFile -Encoding UTF8 -Force
    }
  } catch {
    Write-Host ("[WARN] Unable to initialize log file: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    $global:SAT_LogFile = $null
  }
}

function Invoke-LogRotation {
  if (-not $global:SAT_LogFile) { return }
  try {
    $file = Get-Item -LiteralPath $global:SAT_LogFile -ErrorAction SilentlyContinue
    if (-not $file) { return }
    
    $maxSizeMB = $global:SAT_LogRotationConfig.MaxFileSizeMB
    if ($file.Length -gt ($maxSizeMB * 1MB)) {
      $dir = Split-Path -Parent $global:SAT_LogFile
      $baseName = [System.IO.Path]::GetFileNameWithoutExtension($global:SAT_LogFile)
      $ext = [System.IO.Path]::GetExtension($global:SAT_LogFile)
      
      # Rotate existing files
      for ($i = $global:SAT_LogRotationConfig.MaxFileCount; $i -gt 0; $i--) {
        $oldFile = Join-Path -Path $dir -ChildPath "$baseName.$i$ext"
        $newFile = Join-Path -Path $dir -ChildPath "$baseName.$($i+1)$ext"
        if (Test-Path -LiteralPath $oldFile) {
          if ($i -ge $global:SAT_LogRotationConfig.MaxFileCount) {
            Remove-Item -LiteralPath $oldFile -Force
          } else {
            Move-Item -LiteralPath $oldFile -Destination $newFile -Force
          }
        }
      }
      
      # Move current to .1
      $newName = Join-Path -Path $dir -ChildPath "$baseName.1$ext"
      Move-Item -LiteralPath $global:SAT_LogFile -Destination $newName -Force
      
      # Create new log file
      $hdr = ("==== ServerAuditToolkitV2 Log (Rotated) - {0} ====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
      $hdr | Out-File -FilePath $global:SAT_LogFile -Encoding UTF8 -Force
    }
  } catch {
    # Silently ignore rotation errors
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
    [Parameter(Mandatory=$true)][ValidateSet('Info','Warn','Error','Verbose')] [string]$Level,
    [Parameter(Mandatory=$true)] [string]$Message,
    [Parameter(Mandatory=$false)] [hashtable]$Metadata
  )
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
  $line = "[{0}][{1}] {2}" -f $ts, $Level, $Message

  # Map level for filtering
  $levelInt = 0
  switch ($global:SAT_LogLevel) {
    'Verbose'     { $levelInt = 0 }
    'Information' { $levelInt = 1 }
    'Warning'     { $levelInt = 2 }
    'Error'       { $levelInt = 3 }
    default       { $levelInt = 1 }
  }
  
  $msgLevelInt = 0
  switch ($Level) {
    'Verbose'     { $msgLevelInt = 0 }
    'Info'        { $msgLevelInt = 1 }
    'Warn'        { $msgLevelInt = 2 }
    'Error'       { $msgLevelInt = 3 }
  }
  
  # Only log if level is enabled
  if ($msgLevelInt -lt $levelInt) { return }

  # Console with color
  switch ($Level) {
    'Info'    { Write-Host $line -ForegroundColor Gray }
    'Verbose' { Write-Host $line -ForegroundColor DarkGray }
    'Warn'    { Write-Host $line -ForegroundColor Yellow }
    'Error'   { Write-Host $line -ForegroundColor Red }
  }

  # File
  if ($global:SAT_LogFile) {
    try {
      if ($global:SAT_LogFormat -eq 'json') {
        # JSON structured log entry
        $entry = @{
          timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ'
          sessionId = $global:SAT_LogSessionId
          level = $Level
          message = $Message
        }
        if ($Metadata) { $entry['metadata'] = $Metadata }
        
        $jsonEntry = $entry | ConvertTo-Json -Compress
        Add-Content -Path $global:SAT_LogFile -Value $jsonEntry
      } else {
        # Text format
        Add-Content -Path $global:SAT_LogFile -Value $line
      }
      
      Invoke-LogRotation
    } catch {}
  }
}

function Write-StructuredLog {
  <#
  .SYNOPSIS
    Write a structured log entry with optional metadata to JSON log file.
  .PARAMETER Message
    Log message text.
  .PARAMETER Level
    Severity level: 'Info', 'Warn', 'Error', 'Verbose'.
  .PARAMETER Category
    Audit stage: 'DISCOVER', 'PROFILE', 'EXECUTE', 'FINALIZE', 'COLLECTOR'.
  .PARAMETER Metadata
    Optional hashtable with additional context (error details, timings, etc).
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Message,
    [Parameter(Mandatory=$false)][ValidateSet('Info','Warn','Error','Verbose')][string]$Level = 'Info',
    [Parameter(Mandatory=$false)][string]$Category,
    [Parameter(Mandatory=$false)][hashtable]$Metadata
  )
  
  $logEntry = @{
    timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ'
    sessionId = $global:SAT_LogSessionId
    level = $Level
    message = $Message
  }
  
  if ($Category) { $logEntry['category'] = $Category }
  if ($Metadata) { $logEntry['metadata'] = $Metadata }
  
  Write-Log -Level $Level -Message $Message -Metadata $logEntry
}

function Get-StructuredLogPath {
  <#
  .SYNOPSIS
    Get the path to the structured log file in audit_results.
  .PARAMETER SessionId
    Audit session ID.
  .PARAMETER OutputPath
    Base output directory.
  #>
  param(
    [Parameter(Mandatory=$true)][string]$SessionId,
    [Parameter(Mandatory=$true)][string]$OutputPath
  )
  
  $logDir = Join-Path -Path $OutputPath -ChildPath 'logs'
  if (-not (Test-Path -LiteralPath $logDir)) {
    [void](New-Item -ItemType Directory -Path $logDir -Force)
  }
  
  $logPath = Join-Path -Path $logDir -ChildPath "audit_$($SessionId).log.json"
  return $logPath
}
