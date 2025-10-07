function Get-SATSystem {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info "System inventory on $c"
      $scr = {
        $os  = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
        $cs  = Get-WmiObject -Class Win32_ComputerSystem     -ErrorAction Stop
        $bios= Get-WmiObject -Class Win32_BIOS                -ErrorAction SilentlyContinue
        $cpu = Get-WmiObject -Class Win32_Processor           -ErrorAction SilentlyContinue
        $up  = (Get-Date) - ([Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime))

        [pscustomobject]@{
          ComputerName   = $env:COMPUTERNAME
          OSName         = $os.Caption
          OSEdition      = $os.OperatingSystemSKU
          OSVersion      = $os.Version
          BuildNumber    = $os.BuildNumber
          InstallDate    = [Management.ManagementDateTimeConverter]::ToDateTime($os.InstallDate)
          LastBoot       = [Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime)
          Uptime         = $up
          Domain         = $cs.Domain
          PartOfDomain   = $cs.PartOfDomain
          Manufacturer   = $cs.Manufacturer
          Model          = $cs.Model
          TotalMemoryMB  = [math]::Round($cs.TotalPhysicalMemory/1MB)
          LogicalProcs   = $cs.NumberOfLogicalProcessors
          Sockets        = ($cpu | Measure-Object).Count
          CoresTotal     = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
          BIOSSerial     = $bios.SerialNumber
          IsVirtual      = ($cs.Model -match 'Virtual|VMware|Hyper-V|KVM|Xen')
        }
      }

      $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
      $out[$c] = $res | ConvertTo-Json -Depth 4 | ConvertFrom-Json

    } catch {
      Write-Log Error "System collector failed on $c : $($_.Exception.Message)"
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
