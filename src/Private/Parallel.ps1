function Invoke-RunspaceTasks {
  [CmdletBinding()]
  param([Parameter(Mandatory)] [array]$Tasks, [int]$Throttle = [Environment]::ProcessorCount)

  Add-Type -AssemblyName System.Management.Automation
  $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  $mod = Join-Path $PSScriptRoot '..\ServerAuditToolkitV2.psd1'
  $iss.ImportPSModule($mod)
  $pool = [runspacefactory]::CreateRunspacePool(1,$Throttle,$iss,$host)
  $pool.ApartmentState = 'MTA'
  $pool.Open()

  $worker = {
    param($fn,$targets,$cap,$verbosePref)
    & $fn -ComputerName $targets -Capability $cap -Verbose:$verbosePref
  }.ToString()

  $handles = @()
  foreach ($t in $Tasks) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    $null = $ps.AddScript($worker).AddArgument($t.Name)
    foreach ($a in $t.Args) { $null = $ps.AddArgument($a) }
    $null = $ps.AddArgument($VerbosePreference)
    $handles += [pscustomobject]@{ Name=$t.Name; PS=$ps; Handle=$ps.BeginInvoke() }
  }

  $out = @()
  foreach ($h in $handles) {
    $data = $h.PS.EndInvoke($h.Handle)
    $out += [pscustomobject]@{ Name=$h.Name; Data=$data }
    $h.PS.Dispose()
  }
  $pool.Close(); $pool.Dispose()
  return $out
}