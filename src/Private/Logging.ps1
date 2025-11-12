function Write-Log {
  param(
    [ValidateSet('Debug','Info','Warn','Error')] [string]$Level = 'Info',
    [string]$Message
  )
  $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
  $line = "[$stamp][$Level] $Message"
  switch ($Level) {
    'Debug' { Write-Verbose $line }
    'Info'  { Write-Verbose $line }
    'Warn'  { Write-Warning $line }
    'Error' { Write-Error $line }
  }
}

