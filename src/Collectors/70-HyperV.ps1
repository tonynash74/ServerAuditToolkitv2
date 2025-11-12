function Get-SATHyperV {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Hyper-V inventory on {0}" -f $c)

      $useModule = ($Capability.HasHyperVModule -and ((Get-SATPSMajor) -ge 3))

      if ($useModule) {
        $scr = {
          Import-Module Hyper-V -ErrorAction SilentlyContinue | Out-Null
          $vms = @(); $nics=@(); $disks=@(); $switches=@()

          try { $vms = Get-VM -ErrorAction SilentlyContinue | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime, Generation, Path, AutomaticStartAction, AutomaticStopAction } catch {}
          try { $nics = Get-VMNetworkAdapter -VMName * -ErrorAction SilentlyContinue | Select-Object VMName, SwitchName, MacAddress, IPAddresses } catch {}
          try { $disks = Get-VMHardDiskDrive -VMName * -ErrorAction SilentlyContinue | Select-Object VMName, Path, ControllerType, ControllerNumber, ControllerLocation } catch {}
          try { $switches = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object Name, SwitchType, AllowManagementOS } catch {}

          $res = @{}
          $res["VMs"]      = $vms
          $res["NICs"]     = $nics
          $res["Disks"]    = $disks
          $res["Switches"] = $switches
          $res["Notes"]    = 'Hyper-V module'
          return $res
        }

        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res

      } else {
        # WMI (v2 preferred; fallback to v1)
        $scr = {
          $ns = 'root\virtualization\v2'
          $ok = $true
          try { Get-WmiObject -Namespace $ns -Class Msvm_ComputerSystem -ErrorAction Stop | Out-Null } catch { $ok = $false }
          if (-not $ok) { $ns = 'root\virtualization' }

          $vmsOut = @()
          try {
            $vms = Get-WmiObject -Namespace $ns -Class Msvm_ComputerSystem -ErrorAction SilentlyContinue |
                   Where-Object { $_.Caption -eq 'Virtual Machine' }
            foreach ($v in $vms) {
              $stateMap = @{ 2='Running'; 3='Stopped'; 32768='Paused'; 32769='Suspended' }
              $st = $null; if ($v.EnabledState -ne $null) { $st = $stateMap[[int]$v.EnabledState] }
              $upt = $null; if ($v.OnTimeInMilliseconds) { $upt = [TimeSpan]::FromMilliseconds([double]$v.OnTimeInMilliseconds) }
              $vmsOut += New-Object PSObject -Property @{
                Name   = $v.ElementName
                State  = $st
                Uptime = $upt
                Path   = $v.Path
              }
            }
          } catch {}

          $res = @{}
          $res["VMs"]      = $vmsOut
          $res["NICs"]     = @()
          $res["Disks"]    = @()
          $res["Switches"] = @()
          $res["Notes"]    = ("WMI fallback ({0})" -f $ns)
          return $res
        }

        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res
      }

    } catch {
      Write-Log Error ("Hyper-V collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
