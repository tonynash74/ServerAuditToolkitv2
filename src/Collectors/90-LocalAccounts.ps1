function Get-SATLocalAccounts {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Local accounts on {0}" -f $c)
      $scr = {
        $users  = @()
        $groups = @()
        $members= @()

        try {
          $users = Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True" -ErrorAction SilentlyContinue |
                   Select-Object Name, SID, Disabled, LocalAccount |
                   ForEach-Object {
                     New-Object PSObject -Property @{
                       Name=$_.Name; SID=$_.SID; Enabled=(-not $_.Disabled)
                       PasswordExpires=$null; PasswordRequired=$null; LastLogon=$null
                     }
                   }
        } catch {}

        try {
          $groups = Get-WmiObject Win32_Group -Filter "LocalAccount=True" -ErrorAction SilentlyContinue |
                    Select-Object Name, SID
        } catch {}

        try {
          foreach ($g in $groups) {
            $grp = $null
            try { $grp = [ADSI]("WinNT://$env:COMPUTERNAME/$($g.Name),group") } catch {}
            if ($grp) {
              $col = $grp.psbase.Invoke('Members')
              foreach ($m in $col) {
                $mName  = $m.GetType().InvokeMember('Name','GetProperty',$null,$m,$null)
                $mClass = $m.GetType().InvokeMember('Class','GetProperty',$null,$m,$null)
                $sidVal = $null
                try {
                  $acct = $mName
                  if ($acct -and ($acct -notmatch '\\')) { $acct = "$env:COMPUTERNAME\$acct" }
                  $sidVal = (New-Object System.Security.Principal.NTAccount($acct)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                } catch {}
                $members += New-Object PSObject -Property @{
                  Group=$g.Name; Name=$mName; ObjectClass=$mClass; SID=$sidVal
                }
              }
            }
          }
        } catch {}

        return @{ Users=$users; Groups=$groups; Members=$members; Notes='WMI + ADSI' }
      }

      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } catch {
      Write-Log Error ("Local Accounts collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
