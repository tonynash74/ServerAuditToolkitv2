function Get-SATSMB {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability,[int]$MaxAclEntries = 25)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("SMB shares on {0}" -f $c)

      $useModule = ($Capability.HasSmbModule -and ((Get-SATPSMajor) -ge 3))

      if ($useModule) {
        $scr = {
          param($Max)
          $shares = Get-SmbShare -Special $false -ErrorAction SilentlyContinue |
                    Select-Object Name, Path, Description, ShareState, ConcurrentUserLimit, FolderEnumerationMode, EncryptData

          $perms = @()
          foreach ($s in $shares) {
            $acc = @(); try { $acc = Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue | Select-Object AccountName, AccessControlType, AccessRight } catch {}
            $ntfs = @()
            if ($s.Path -and (Test-Path $s.Path)) {
              try {
                $acl = Get-Acl -Path $s.Path
                $ntfs = $acl.Access | Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited | Select-Object -First $Max
              } catch {}
            }
            $perms += New-Object PSObject -Property @{ Share=$s.Name; Path=$s.Path; ShareAccess=$acc; NtfsTop=$ntfs }
          }

          $res = @{}
          $res["Shares"]      = $shares
          $res["Permissions"] = $perms
          $res["Notes"]       = 'SmbShare module'
          return $res
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $MaxAclEntries
        $out[$c] = $res

      } else {
        $scr = {
          param($Max)
          $wmi = Get-WmiObject -Class Win32_Share -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 0 } |
                 Select-Object Name, Path, Description
          $netshare = (& cmd.exe /c 'net share' 2>$null)

          $perms = @()
          foreach ($s in $wmi) {
            $ntfs = @()
            if ($s.Path -and (Test-Path $s.Path)) {
              try {
                $acl = Get-Acl -Path $s.Path
                $ntfs = $acl.Access | Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited | Select-Object -First $Max
              } catch {}
            }
            $perms += New-Object PSObject -Property @{ Share=$s.Name; Path=$s.Path; NtfsTop=$ntfs; ShareAccessRaw=$null }
          }

          $res = @{}
          $res["Shares"]      = $wmi
          $res["Permissions"] = $perms
          $res["NetShareRaw"] = "$netshare"
          $res["Notes"]       = 'Win32_Share + net share'
          return $res
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $MaxAclEntries
        $out[$c] = $res
      }

    } catch {
      Write-Log Error ("SMB collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
