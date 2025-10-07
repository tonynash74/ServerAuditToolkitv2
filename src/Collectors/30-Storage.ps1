function Get-SATStorage {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info "Storage inventory on $c"

      if ($Capability.HasStorage) {
        $scr = {
          $disks  = Get-Disk -ErrorAction SilentlyContinue | Select-Object Number, FriendlyName, SerialNumber, BusType, PartitionStyle, HealthStatus, OperationalStatus, Size
          $parts  = Get-Partition -ErrorAction SilentlyContinue | Select-Object DiskNumber, PartitionNumber, DriveLetter, Type, Size
          $vols   = Get-Volume -ErrorAction SilentlyContinue | Select-Object DriveLetter, FileSystem, FileSystemLabel, AllocationUnitSize, Size, SizeRemaining, Path, HealthStatus
          $bl     = @()
          try { $bl = Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionMethod, AutoUnlockEnabled } catch {}

          # Data dedup status if installed
          $dedup = @()
          try { Import-Module Deduplication -ErrorAction Stop; $dedup = Get-DedupStatus | Select-Object Volume, SavingsRate, OptimizedFilesCount, InPolicyFilesSize } catch {}

          [pscustomobject]@{
            Disks   = $disks
            Partitions = $parts
            Volumes = $vols
            BitLocker = $bl
            Dedup     = $dedup
            Notes  = 'Storage module (+optional BitLocker/Dedup)'
          }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = @{
          Disks     = @($res.Disks     | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Partitions= @($res.Partitions| ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Volumes   = @($res.Volumes   | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          BitLocker = @($res.BitLocker | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Dedup     = @($res.Dedup     | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Notes     = $res.Notes
        }

      } else {
        $scr = {
          $disks = Get-WmiObject -Class Win32_DiskDrive -ErrorAction SilentlyContinue |
                   Select-Object Index, Model, SerialNumber, InterfaceType, Size
          $parts = Get-WmiObject -Class Win32_DiskPartition -ErrorAction SilentlyContinue |
                   Select-Object DiskIndex, Index, Type, Size, Bootable, BootPartition
          $vols  = Get-WmiObject -Class Win32_LogicalDisk -ErrorAction SilentlyContinue |
                   Where-Object { $_.DriveType -in 2,3 } |
                   Select-Object DeviceID, FileSystem, VolumeName,
                                 @{n='Size';e={$_.Size}}, @{n='FreeSpace';e={$_.FreeSpace}}
          $blRaw = (& manage-bde -status 2>$null)
          [pscustomobject]@{
            Disks     = $disks
            Partitions= $parts
            Volumes   = $vols
            BitLockerRaw = "$blRaw"
            Notes     = 'WMI + manage-bde fallback'
          }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = @{
          Disks       = @($res.Disks     | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Partitions  = @($res.Partitions| ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Volumes     = @($res.Volumes   | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          BitLockerRaw= $res.BitLockerRaw
          Dedup       = @()
          Notes       = $res.Notes
        }
      }

    } catch {
      Write-Log Error "Storage collector failed on $c : $($_.Exception.Message)"
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
