function Get-SATHyperV {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info "Hyper-V inventory on $c"

      if ($Capability.HasHyperVModule) {
        $scr = {
          Import-Module Hyper-V -ErrorAction Stop
          $vms = Get-VM | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime, Generation, Path, AutomaticStartAction, AutomaticStopAction
          $nets = Get-VMNetworkAdapter -VMName * 2>$null | Select VMName, SwitchName, MacAddress, IPAddresses
          $disks = Get-VMHardDiskDrive -VMName * 2>$null | Select VMName, Path, ControllerType, ControllerNumber, ControllerLocation
          $switches = Get-VMSwitch | Select Name, SwitchType, AllowManagementOS
          [pscustomobject]@{
            VMs      = $vms
            NICs     = $nets
            Disks    = $disks
            Switches = $switches
            Notes    = 'Hyper-V module'
          }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = @{
          VMs      = @($res.VMs | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          NICs     = @($res.NICs | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Disks    = @($res.Disks | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Switches = @($res.Switches | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Notes    = $res.Notes
        }

      } else {
        # WMI fallback (works on 2012 R2, namespace v2)
        $scr = {
          $ns = 'root\virtualization\v2'
          try { Get-WmiObject -Namespace $ns -Class Msvm_ComputerSystem -ErrorAction Stop } catch {
            $ns = 'root\virtualization'
          }
          $vms = Get-WmiObject -Namespace $ns -Class Msvm_ComputerSystem |
                  Where-Object { $_.Caption -eq 'Virtual Machine' } |
                  Select-Object ElementName, EnabledState, OnTimeInMilliseconds, Path
          $maps = @{ 2='Running'; 3='Stopped'; 32768='Paused' }
          $vmsOut = foreach ($v in $vms) {
            [pscustomobject]@{
              Name   = $v.ElementName
              State  = ($maps[[int]$v.EnabledState] | ForEach-Object{$_})  # null-safe
              Uptime = [TimeSpan]::FromMilliseconds([double]($v.OnTimeInMilliseconds))
              Path   = $v.Path
            }
          }
          [pscustomobject]@{
            VMs      = $vmsOut
            NICs     = @()
            Disks    = @()
            Switches = @()
            Notes    = "WMI fallback ($ns)"
          }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = @{
          VMs      = @($res.VMs)
          NICs     = @()
          Disks    = @()
          Switches = @()
          Notes    = $res.Notes
        }
      }

    } catch {
      Write-Log Error "Hyper-V collector failed on $c : $($_.Exception.Message)"
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
