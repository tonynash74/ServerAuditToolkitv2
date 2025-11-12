function Get-SATStorage {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Storage inventory on {0}" -f $c)

      $useModern = ($Capability.HasStorage -and ((Get-SATPSMajor) -ge 3))

      if ($useModern) {
        $scr = {
          $disks  = @(); $parts=@(); $vols=@(); $bl=@(); $dedup=@()

          try { $disks = Get-Disk -ErrorAction SilentlyContinue | Select-Object Number, FriendlyName, SerialNumber, BusType, PartitionStyle, HealthStatus, OperationalStatus, Size } catch {}
          try { $parts = Get-Partition -ErrorAction SilentlyContinue | Select-Object DiskNumber, PartitionNumber, DriveLetter, Type, Size } catch {}
          try { $vols  = Get-Volume -ErrorAction SilentlyContinue | Select-Object DriveLetter, FileSystem, FileSystemLabel, AllocationUnitSize, Size, SizeRemaining, Path, HealthStatus } catch {}

          try { $bl = Get-BitLockerVolume -ErrorAction SilentlyContinue | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionMethod, AutoUnlockEnabled } catch {}
          try { Import-Module Deduplication -ErrorAction Stop | Out-Null; $dedup = Get-DedupStatus -ErrorAction SilentlyContinue | Select-Object Volume, SavingsRate, OptimizedFilesCount, InPolicyFilesSize } catch {}

          $res = @{}
          $res["Disks"]      = $disks
          $res["Partitions"] = $parts
          $res["Volumes"]    = $vols
          $res["BitLocker"]  = $bl
          $res["Dedup"]      = $dedup
          $res["Notes"]      = 'Storage(+BitLocker/Dedup)'

          return $res
        }

        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res

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

          $res = @{}
          $res["Disks"]       = $disks
          $res["Partitions"]  = $parts
          $res["Volumes"]     = $vols
          $res["BitLockerRaw"]= "$blRaw"
          $res["Dedup"]       = @()
          $res["Notes"]       = 'WMI + manage-bde'

          return $res
        }

        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res
      }

    } catch {
      Write-Log Error ("Storage collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}


