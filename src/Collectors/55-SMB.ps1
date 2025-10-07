function Get-SATSMB {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability,
    [int]$MaxAclEntries = 25  # cap ACL entries per share for speed
  )

  $out = @{}

  foreach ($c in $ComputerName) {
    try {
      Write-Log Info "SMB shares on $c"

      if ($Capability.HasSmbModule) {
        $scr = {
          param($MaxAclEntries)
          $shares = Get-SmbShare -Special $false -ErrorAction SilentlyContinue |
            Select-Object Name, Path, Description, ShareState, ConcurrentUserLimit, FolderEnumerationMode, EncryptData

          $perms = foreach ($s in $shares) {
            $acc = Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue |
                   Select-Object AccountName, AccessControlType, AccessRight
            # Top-level NTFS ACL (no recursion)
            $ntfs = @()
            if ($s.Path -and (Test-Path $s.Path)) {
              try {
                $acl = Get-Acl -Path $s.Path
                $ntfs = $acl.Access | Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited | Select-Object -First $MaxAclEntries
              } catch { }
            }

            [pscustomobject]@{
              Share = $s.Name; Path=$s.Path; ShareAccess=$acc; NtfsTop=$ntfs
            }
          }

          [pscustomobject]@{
            Shares = $shares
            Permissions = $perms
            Notes = 'SmbShare module'
          }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $MaxAclEntries
        $out[$c] = @{
          Shares      = @($res.Shares | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Permissions = @($res.Permissions | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
          Notes       = $res.Notes
        }

      } else {
        # Fallback: Win32_Share + 'net share' text; NTFS ACL at top-level via Get-Acl if path reachable
        $scr = {
          param($MaxAclEntries)
          $wmi = Get-WmiObject -Class Win32_Share -ErrorAction SilentlyContinue |
                 Where-Object { $_.Type -eq 0 } |  # disk shares
                 Select-Object Name, Path, Description

          $net = & cmd.exe /c 'net share' 2>$null
          $perms = foreach ($s in $wmi) {
            $ntfs = @()
            if ($s.Path -and (Test-Path $s.Path)) {
              try {
                $acl = Get-Acl -Path $s.Path
                $ntfs = $acl.Access | Select IdentityReference, FileSystemRights, AccessControlType, IsInherited | Select -First $MaxAclEntries
              } catch { }
            }
            [pscustomobject]@{ Share=$s.Name; Path=$s.Path; ShareAccessRaw=$null; NtfsTop=$ntfs }
          }

          [pscustomobject]@{ Shares=$wmi; Permissions=$perms; NetShareRaw=$net; Notes='Win32_Share + net share fallback' }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $MaxAclEntries
        $out[$c] = @{
          Shares      = @($res.Shares | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Permissions = @($res.Permissions | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          NetShareRaw = "$($res.NetShareRaw)"
          Notes       = $res.Notes
        }
      }

    } catch {
      Write-Log Error "SMB collector failed on $c : $($_.Exception.Message)"
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
