function Get-SATScheduledTasks {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability,
    [int]$MaxTasksPerServer = 2000
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Scheduled Tasks on {0}" -f $c)

      $useModule = ($Capability.HasScheduledTasks -and ((Get-SATPSMajor) -ge 3))

      if ($useModule) {
        $scr = {
          param($Max)
          $rows = @()
          $all = @()
          try { $all = Get-ScheduledTask -ErrorAction SilentlyContinue } catch {}

          foreach ($t in ($all | Select-Object -First $Max)) {
            $info = $null
            try { $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue } catch {}

            $cmd  = $null; $args = $null
            try {
              $act = $t.Actions | Select-Object -First 1
              if ($act) { $cmd = $act.Execute; $args = $act.Arguments }
            } catch {}

            $rows += $t | Select-Object `
              @{n='TaskName';e={$t.TaskName}},
              @{n='TaskPath';e={$t.TaskPath}},
              @{n='State';e={$t.State}},
              @{n='Enabled';e={$t.Enabled}},
              @{n='UserId';e={$t.Principal.UserId}},
              @{n='RunLevel';e={$t.Principal.RunLevel}},
              @{n='ActionExe';e={$cmd}},
              @{n='ActionArgs';e={$args}},
              @{n='NextRun';e={$info.NextRunTime}},
              @{n='LastRun';e={$info.LastRunTime}},
              @{n='LastResult';e={$info.LastTaskResult}}
          }

          $res = @{}
          $res["Tasks"] = $rows
          $res["Notes"] = 'ScheduledTasks module'
          return $res
        }

        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $MaxTasksPerServer
        $out[$c] = $res

      } else {
        # PS2-friendly: parse schtasks CSV (best effort; headers vary by OS locale/build)
        $scr = {
          param($Max)
          $csv = (& schtasks /Query /V /FO CSV 2>$null)
          $rows = @()

          if ($csv) {
            $parsed = $csv | ConvertFrom-Csv
            $count = 0
            foreach ($r in $parsed) {
              if ($count -ge $Max) { break }
              $count++

              # Field name variants across versions/locales
              $nameField   = 'TaskName'
              $statusField = 'Status'
              $stateField  = 'Scheduled Task State'
              $exeField    = 'Task To Run'
              $runAsField  = 'Run As User'
              $nextField   = 'Next Run Time'
              $lastField   = 'Last Run Time'
              $resultField = 'Last Result'

              $taskName = $r.$nameField
              $taskPath = $null
              if ($taskName) {
                # heuristic: everything before last '\' is path
                $idx = $taskName.LastIndexOf('\')
                if ($idx -gt 0) { $taskPath = $taskName.Substring(0,$idx+1) }
              }

              $rows += New-Object PSObject -Property @{
                TaskName   = $taskName
                TaskPath   = $taskPath
                State      = ($r.$stateField -as [string]) # may be empty
                Enabled    = $r.$statusField
                UserId     = $r.$runAsField
                RunLevel   = $null
                ActionExe  = $r.$exeField
                ActionArgs = $null
                NextRun    = $r.$nextField
                LastRun    = $r.$lastField
                LastResult = $r.$resultField
              }
            }
          }

          $res = @{}
          $res["Tasks"] = $rows
          $res["Notes"] = 'schtasks CSV fallback'
          return $res
        }

        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $MaxTasksPerServer
        $out[$c] = $res
      }

    } catch {
      Write-Log Error ("ScheduledTasks collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
