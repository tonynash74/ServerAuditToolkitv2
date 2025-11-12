# --- PS version helpers ---
function Get-SATPSMajor {
  if ($PSVersionTable) { return $PSVersionTable.PSVersion.Major } else { return 2 }
}

# --- [pscustomobject] shim for PS2 ---
function New-SATObject {
  param([hashtable]$Properties)
  if ((Get-SATPSMajor) -ge 3) { return [pscustomobject]$Properties }
  $o = New-Object PSObject
  foreach ($k in $Properties.Keys) {
    Add-Member -InputObject $o -NotePropertyName $k -NotePropertyValue $Properties[$k]
  }
  return $o
}

# --- safe module presence check ---
function Test-SATModule { param([string]$Name)
  return [bool](Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)
}

# --- safe service status ---
function Get-SATServiceStatus { param([string]$Name)
  $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
  if ($svc) { $svc.Status } else { $null }
}

# --- JSON/CLIXML exporter (PS3+ JSON, else CLIXML) ---
function Export-SATData {
  param(
    [Parameter(Mandatory=$true)]$Object,
    [Parameter(Mandatory=$true)][string]$PathBase,
    [int]$Depth = 6
  )
  $jsonCmd = Get-Command ConvertTo-Json -ErrorAction SilentlyContinue
  if ($jsonCmd) {
    $jsonPath = "$PathBase.json"
    $Object | ConvertTo-Json -Depth $Depth | Set-Content -Encoding UTF8 -Path $jsonPath
    return $jsonPath
  } else {
    $xmlPath = "$PathBase.clixml"
    $Object | Export-Clixml -Path $xmlPath
    return $xmlPath
  }
}
