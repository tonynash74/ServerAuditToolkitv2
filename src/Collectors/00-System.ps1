function Get-SATSystem {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("System inventory on {0}" -f $c)
      $scr = {
        $os  = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cs  = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
        $bios= Get-WmiObject -Class Win32_BIOS -ErrorAction SilentlyContinue
        $cpu = Get-WmiObject -Class Win32_Processor -ErrorAction SilentlyContinue

        $boot = $null; if ($os) { $boot = [Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime) }
        $up   = $null; if ($boot) { $up = (Get-Date) - $boot }

        New-Object PSObject -Property @{
          ComputerName   = $env:COMPUTERNAME
          OSName         = $os.Caption
          OSEdition      = $os.OperatingSystemSKU
          OSVersion      = $os.Version
          BuildNumber    = $os.BuildNumber
          InstallDate    = (if ($os) { [Management.ManagementDateTimeConverter]::ToDateTime($os.InstallDate) } else { $null })
          LastBoot       = $boot
          Uptime         = $up
          Domain         = $cs.Domain
          PartOfDomain   = $cs.PartOfDomain
          Manufacturer   = $cs.Manufacturer
          Model          = $cs.Model
          TotalMemoryMB  = (if ($cs) { [math]::Round($cs.TotalPhysicalMemory/1MB) } else { $null })
          LogicalProcs   = $cs.NumberOfLogicalProcessors
          Sockets        = ($cpu | Measure-Object).Count
          CoresTotal     = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
          BIOSSerial     = $bios.SerialNumber
          IsVirtual      = (if ($cs) { ($cs.Model -match 'Virtual|VMware|Hyper-V|KVM|Xen') } else { $false })
        }
      }
      $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
      $out[$c] = $res
    } catch {
      Write-Log Error ("System collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}

