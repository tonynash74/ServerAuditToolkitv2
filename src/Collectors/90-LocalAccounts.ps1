function Get-SATLocalAccounts {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability,
    [int]$MaxMembersPerGroup = 500
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info "Local accounts on $c"

      if ($Capability.HasLocalAccounts) {
        $scr = {
          param($MaxMembersPerGroup)
          Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop
          $users  = Get-LocalUser | Select-Object Name, Enabled, LastLogon, PasswordExpires, PasswordRequired, SID
          $groups = Get-LocalGroup | Select-Object Name, SID
          $members = @()
          foreach ($g in $groups) {
            try {
              $m = Get-LocalGroupMember -Group $g.Name -ErrorAction SilentlyContinue |
                   Select-Object @{n='Group';e={$g.Name}}, Name, ObjectClass, SID | Select-Object -First $MaxMembersPerGroup
              $members += $m
            } catch {}
          }
          [pscustomobject]@{
            Users   = $users
            Groups  = $groups
            Members = $members
            Notes   = 'LocalAccounts module'
          }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $MaxMembersPerGroup
        $out[$c] = @{
          Users   = @($res.Users   | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Groups  = @($res.Groups  | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Members = @($res.Members | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Notes   = $res.Notes
        }

      } else {
        $scr = {
          param($MaxMembersPerGroup)
          $users = Get-WmiObject -Class Win32_UserAccount -ErrorAction SilentlyContinue |
                   Where-Object { $_.LocalAccount -eq $true } |
                   Select-Object Name, Disabled, SID, Lockout, PasswordChangeable, PasswordRequired
          $groups = Get-WmiObject -Class Win32_Group -ErrorAction SilentlyContinue |
                    Where-Object { $_.LocalAccount -eq $true } |
                    Select-Object Name, SID
          # 'net localgroup' for membership (text)
          $mrows = @()
          foreach ($g in $groups) {
            $raw = (& cmd /c ("net localgroup ""{0}""" -f $g.Name)) 2>$null
            # naive parse: members start after a dashed line, stop before 'The command completed successfully.'
            $capture = $false
            foreach ($line in $raw) {
              if ($line -match '^-+$') { $capture = -not $capture; continue }
              if ($line -match 'The command completed successfully') { break }
              if ($capture -and $line.Trim()) {
                $mrows += [pscustomobject]@{ Group=$g.Name; Name=$line.Trim(); ObjectClass=$null; SID=$null }
              }
            }
          }
          [pscustomobject]@{
            Users   = $users
            Groups  = $groups
            Members = ($mrows | Select-Object -First $MaxMembersPerGroup)
            Notes   = 'WMI + net localgroup fallback'
          }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $MaxMembersPerGroup
        $out[$c] = @{
          Users   = @($res.Users   | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Groups  = @($res.Groups  | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Members = @($res.Members | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Notes   = $res.Notes
        }
      }

    } catch {
      Write-Log Error "Local Accounts collector failed on $c : $($_.Exception.Message)"
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
