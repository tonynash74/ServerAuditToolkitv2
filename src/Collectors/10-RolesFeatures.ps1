# src/Collectors/10-RolesFeatures.ps1
function Get-SATRolesFeatures {
  [CmdletBinding()] param([string[]]$ComputerName,[hashtable]$Capability)

  $out=@{}
  foreach($c in $ComputerName){
    Write-Log Info "Roles/Features on $c"
    if($Capability.HasServerMgr){
      $data = Invoke-Command -ComputerName $c -ScriptBlock { Get-WindowsFeature | Select Name,DisplayName,Installed } -ErrorAction Stop
      $out[$c] = @{ Installed = @($data | Where Installed).Name; Available = @($data | Where {!$_.Installed}).Name }
    } else {
      # WMI fallback: only installed features exposed
      $data = Get-WmiObject -Class Win32_ServerFeature -ComputerName $c -ErrorAction SilentlyContinue
      $out[$c] = @{ Installed = @($data.Name); Available = @() ; Notes='Used Win32_ServerFeature (installed only)' }
    }
  }
  return $out
}
