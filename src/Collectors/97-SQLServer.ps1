function Get-SATSQLServer {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("SQL Server inventory on {0}" -f $c)

      $scr = {
        $res = @{
          Instances = @()  # per-instance summary
          Services  = @()  # SQL services (Database Engine/Agent/Browser)
          Notes     = ''
          Error     = $null
        }

        function Add-Instance([string]$name,[string]$idKey) {
          $h = @{ Instance=$name; Edition=$null; Version=$null; PatchLevel=$null; Build=$null; Clustered=$null; DataRoot=$null; LogRoot=$null; SqlServiceState=$null; AgentServiceState=$null; VersionString=$null }
          # CurrentVersion block
          $cv = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$idKey\MSSQLServer\CurrentVersion"
          try {
            $p = Get-ItemProperty $cv -ErrorAction SilentlyContinue
            if ($p) {
              if ($p.PSObject.Properties['CurrentVersion']) { $h.Version     = "$($p.CurrentVersion)" }
              if ($p.PSObject.Properties['PatchLevel'])     { $h.PatchLevel  = "$($p.PatchLevel)" }
              if ($p.PSObject.Properties['CSDVersion'])     { $h.Build       = "$($p.CSDVersion)" }
              if ($p.PSObject.Properties['Edition'])        { $h.Edition     = "$($p.Edition)" }
            }
          } catch {}
          # Setup block (PatchLevel/Edition sometimes here)
          $setup = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$idKey\Setup"
          try {
            $sp = Get-ItemProperty $setup -ErrorAction SilentlyContinue
            if ($sp) {
              if (-not $h.Edition -and $sp.PSObject.Properties['Edition']) { $h.Edition = "$($sp.Edition)" }
              if (-not $h.PatchLevel -and $sp.PSObject.Properties['PatchLevel']) { $h.PatchLevel = "$($sp.PatchLevel)" }
              if ($sp.PSObject.Properties['SQLDataRoot']) { $h.DataRoot = "$($sp.SQLDataRoot)" }
              if ($sp.PSObject.Properties['SQLBinRoot'])  { $h.LogRoot  = "$($sp.SQLBinRoot)" }
              if ($sp.PSObject.Properties['Cluster'])     { $h.Clustered = [bool]$sp.Cluster }
            }
          } catch {}

          # Service states
          $svcName = 'MSSQLSERVER'; if ($name -and $name -ne 'MSSQLSERVER') { $svcName = "MSSQL`$$name" }
          $agtName = 'SQLSERVERAGENT'; if ($name -and $name -ne 'MSSQLSERVER') { $agtName = "SQLAGENT`$$name" }
          try { $svc = Get-WmiObject -Class Win32_Service -Filter ("Name='{0}'" -f $svcName) -ErrorAction SilentlyContinue; if ($svc){ $h.SqlServiceState = $svc.State } } catch {}
          try { $agt = Get-WmiObject -Class Win32_Service -Filter ("Name='{0}'" -f $agtName) -ErrorAction SilentlyContinue; if ($agt){ $h.AgentServiceState = $agt.State } } catch {}

          # Best-effort sqlcmd @@VERSION (only if tool available)
          $hasSqlcmd = $false
          try { $hasSqlcmd = [bool](Get-Command sqlcmd.exe -ErrorAction SilentlyContinue) } catch { $hasSqlcmd = $false }
          if ($hasSqlcmd) {
            $svr = '.'; if ($name -and $name -ne 'MSSQLSERVER') { $svr = ".\$name" }
            try {
              $pinfo = New-Object System.Diagnostics.ProcessStartInfo
              $pinfo.FileName = "sqlcmd.exe"
              $pinfo.Arguments = "-S `"$svr`" -E -l 3 -Q `"SET NOCOUNT ON; SELECT @@VERSION;`""
              $pinfo.RedirectStandardOutput = $true
              $pinfo.RedirectStandardError  = $true
              $pinfo.UseShellExecute = $false
              $p = [System.Diagnostics.Process]::Start($pinfo)
              $outp = $p.StandardOutput.ReadToEnd()
              $errp = $p.StandardError.ReadToEnd()
              $p.WaitForExit()
              if ($outp) {
                $line = ($outp -split "\r?\n") | Where-Object { $_ -and ($_ -match 'Microsoft SQL Server') } | Select-Object -First 1
                if ($line) { $h.VersionString = $line.Trim() }
              }
            } catch {}
          }

          $res.Instances += New-Object PSObject -Property $h
        }

        # Discover instance IDs from registry
        $base1 = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
        $base2 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server\Instance Names\SQL'
        $map = @{}
        try { $i1 = Get-Item $base1 -ErrorAction SilentlyContinue; if ($i1){ $i1.GetValueNames() | ForEach-Object { $map[$_] = $i1.GetValue($_) } } } catch {}
        try { $i2 = Get-Item $base2 -ErrorAction SilentlyContinue; if ($i2){ $i2.GetValueNames() | ForEach-Object { if (-not $map.ContainsKey($_)) { $map[$_] = $i2.GetValue($_) } } } } catch {}

        if ($map.Count -eq 0) {
          # Try default-only discovery via service presence
          $svc = Get-WmiObject -Class Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction SilentlyContinue
          if ($svc) { $map['MSSQLSERVER'] = 'MSSQL10_50.MSSQLSERVER' } # harmless placeholder ID
        }

        foreach ($k in $map.Keys) { Add-Instance $k $map[$k] }

        # Collect useful SQL-related services
        try {
          $svcs = Get-WmiObject -Class Win32_Service -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like 'MSSQL*' -or $_.Name -like 'SQL*' -or $_.Name -like 'SQLAgent*'
          }
          foreach ($s in $svcs) {
            $res.Services += New-Object PSObject -Property @{
              Name      = $s.Name
              Display   = $s.DisplayName
              State     = $s.State
              StartMode = $s.StartMode
              PathName  = $s.PathName
            }
          }
        } catch {}

        if (-not $res.Notes) { $res.Notes = 'Registry+WMI+sqlcmd' }
        return $res
      }

      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } catch {
      Write-Log Error ("SQL Server collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Instances=@(); Services=@(); Notes='collector exception'; Error=$_.Exception.Message }
    }
  }
  return $out
}
