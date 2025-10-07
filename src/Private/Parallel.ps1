function Invoke-RunspaceTasks {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [array]$Tasks,  # @{Name; ScriptBlock; Args}
    [int]$Throttle = [Environment]::ProcessorCount
  )
  Add-Type -AssemblyName System.Management.Automation
  $pool = [runspacefactory]::CreateRunspacePool(1,$Throttle)
  $pool.Open()
  $handles = @()
  foreach ($t in $Tasks) {
    $ps = [powershell]::Create().AddScript($t.ScriptBlock).AddArgument($t.Name)
    $t.Args | ForEach-Object { $ps.AddArgument($_) | Out-Null }
    $ps.RunspacePool = $pool
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

function Invoke-Serial {
  param([array]$Tasks)
  $out=@()
  foreach ($t in $Tasks) {
    $data = & $t.ScriptBlock @($t.Name + $t.Args)
    $out += [pscustomobject]@{ Name=$t.Name; Data=$data }
  }
  return $out
}
