function Get-SATSystem {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("System inventory on {0}" -f $c)
      $scr = {
        $os   = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cs   = Get-WmiObject -Class Win32_ComputerSystem   -ErrorAction SilentlyContinue
        $bios = Get-WmiObject -Class Win32_BIOS             -ErrorAction SilentlyContinue
        $cpu  = Get-WmiObject -Class Win32_Processor        -ErrorAction SilentlyContinue

        $install = $null
        if ($os -and $os.InstallDate) { $install = [Management.ManagementDateTimeConverter]::ToDateTime($os.InstallDate) }

        $boot = $null
        if ($os -and $os.LastBootUpTime) { $boot = [Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime) }

        $up = $null
        if ($boot) { $up = (Get-Date) - $boot }

        $totMemMB = $null
        if ($cs -and $cs.TotalPhysicalMemory) { $totMemMB = [math]::Round($cs.TotalPhysicalMemory/1MB) }

        $sockets = 0; $coresTot = $null
        if ($cpu) {
          $sockets = ($cpu | Measure-Object).Count
          $sumCores = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
          if ($sumCores) { $coresTot = $sumCores }
        }

        $osName       = $null; if ($os) { $osName = $os.Caption }
        $osEdition    = $null; if ($os) { $osEdition = $os.OperatingSystemSKU }
        $osVersion    = $null; if ($os) { $osVersion = $os.Version }
        $buildNumber  = $null; if ($os) { $buildNumber = $os.BuildNumber }
        $domain       = $null; if ($cs) { $domain = $cs.Domain }
        $partOfDomain = $null; if ($cs) { $partOfDomain = $cs.PartOfDomain }
        $mfr          = $null; if ($cs) { $mfr = $cs.Manufacturer }
        $model        = $null; if ($cs) { $model = $cs.Model }
        $logProcs     = $null; if ($cs) { $logProcs = $cs.NumberOfLogicalProcessors }
        $biosSerial   = $null; if ($bios){ $biosSerial = $bios.SerialNumber }
        $isVirtual    = $false; if ($cs -and $cs.Model) { $isVirtual = ($cs.Model -match 'Virtual|VMware|Hyper-V|KVM|Xen') }

        New-Object PSObject -Property @{
          ComputerName   = $env:COMPUTERNAME
          OSName         = $osName
          OSEdition      = $osEdition
          OSVersion      = $osVersion
          BuildNumber    = $buildNumber
          InstallDate    = $install
          LastBoot       = $boot
          Uptime         = $up
          Domain         = $domain
          PartOfDomain   = $partOfDomain
          Manufacturer   = $mfr
          Model          = $model
          TotalMemoryMB  = $totMemMB
          LogicalProcs   = $logProcs
          Sockets        = $sockets
          CoresTotal     = $coresTot
          BIOSSerial     = $biosSerial
          IsVirtual      = $isVirtual
        }
      }
      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } catch {
      Write-Log Error ("System collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
