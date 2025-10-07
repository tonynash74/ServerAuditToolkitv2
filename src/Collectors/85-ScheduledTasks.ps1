function Get-SATScheduledTasks {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability,
    [int]$MaxTasksPerServer = 2000  # safety cap
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info "Scheduled Tasks on $c"

      if ($Capability.HasScheduledTasks) {
        $scr = {
          param($Max)
          $all = Get-ScheduledTask -ErrorAction SilentlyContinue
          $rows = @()
          foreach ($t in $all | Select-Object -First $Max) {
            $info = $null
            try { $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath } catch {}
            # Extract primary action command/args if present
            $cmd  = $null; $args = $null
            try {
              $act = $t.Actions | Select-Object -First 1
              $cmd = $act.Execute; $args = $act.Arguments
            } catch {}
            $rows += [pscustomobject]@{
              TaskName   = $t.TaskName
              TaskPath   = $t.TaskPath
              State      = $t.State
              Enabled    = $t.Enabled
              UserId     = $t.Principal.UserId
              RunLevel   = $t.Principal.RunLevel
              ActionExe  = $cmd
              ActionArgs = $args
              NextRun    = $info.NextRunTime
              LastRun    = $info.LastRunTime
              LastResult = $info.LastTaskResult
            }
          }
          [pscustomobject]@{ Tasks = $rows; Notes='ScheduledTasks module' }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $MaxTasksPerServer
        $out[$c] = @{
          Tasks = @($res.Tasks | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Notes = $res.Notes
        }

      } else {
        $scr = {
          param($Max)
          $csv = (& schtasks /Query /V /FO CSV 2>$null)
          # Quick CSV parse (avoid culture pitfalls: rely on PowerShell CSV parser)
          $rows = @()
          if ($csv) {
            $parsed = $csv | ConvertFrom-Csv
            foreach ($r in $parsed | Select-Object -First $Max) {
              $rows += [pscustomobject]@{
                TaskName   = $r.'TaskName'
                TaskPath   = $r.'TaskName' -replace '^(.*\\).*','$1' # heuristic
                State      = $r.'Status'
                Enabled    = $r.'Scheduled Task State'
                UserId     = $r.'Run As User'
                RunLevel   = $null
                ActionExe  = $r.'Task To Run'
                ActionArgs = $null
                NextRun    = $r.'Next Run Time'
                LastRun    = $r.'Last Run Time'
                LastResult = $r.'Last Result'
              }
            }
          }
          [pscustomobject]@{ Tasks=$rows; Notes='schtasks fallback' }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $MaxTasksPerServer
        $out[$c] = @{
          Tasks = @($res.Tasks | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Notes = $res.Notes
        }
      }

    } catch {
      Write-Log Error "ScheduledTasks collector failed on $c : $($_.Exception.Message)"
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
