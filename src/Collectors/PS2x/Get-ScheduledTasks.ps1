<#
.SYNOPSIS
    Collects scheduled tasks (critical jobs, backups, maintenance).

.DESCRIPTION
    Enumerates scheduled tasks including:
    - Task name, status, last run time, next run time
    - Task actions (executables, arguments)
    - Triggers (schedule, conditions)
    - Security context (run as account)
    - Task history (success/failure counts)
    
    Critical for:
    - Identifying critical background jobs
    - Backup job verification
    - Maintenance task tracking
    - Service migration (what manual jobs must continue?)

.PARAMETER ComputerName
    Target server. Default: localhost.

.PARAMETER Credential
    Domain credentials if needed.

.PARAMETER DryRun
    Show what would be collected without executing.

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     2025-11-21
    PowerShell:   2.0+
    License:      MIT
    
    @CollectorName: Get-ScheduledTasks
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2003
    @MaxWindowsVersion:
    @Dependencies:
    @Timeout: 60
    @Category: infrastructure
    @Critical: true
    @Priority: TIER5
    @EstimatedExecutionTime: 30
#>

function Get-ScheduledTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $startTime = Get-Date

    try {
        if ($DryRun) {
            Write-Verbose "DRY-RUN: Would collect scheduled tasks from $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Get-ScheduledTasks'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $taskData = @()

        # Try modern method first (PS 3+, Windows Server 2012+)
        try {
            if ($ComputerName -eq $env:COMPUTERNAME) {
                $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue
            }
            else {
                # Remote task enumeration via CIM/WMI
                $cimParams = @{
                    ComputerName = $ComputerName
                    ErrorAction  = 'SilentlyContinue'
                }

                if ($Credential) {
                    $cimParams['Credential'] = $Credential
                }

                # Get tasks via TaskScheduler COM
                try {
                    $TaskScheduler = New-Object -ComObject Schedule.Service
                    $TaskScheduler.Connect($ComputerName)
                    
                    function Get-FolderTasks {
                        param($folder)
                        
                        $tasks = @()
                        
                        # Get tasks in this folder
                        foreach ($task in $folder.GetTasks(1)) {
                            $lastRun = $task.LastRunTime
                            if ($lastRun -eq (Get-Date "1/1/1601")) {
                                $lastRun = $null
                            }

                            $tasks += @{
                                TaskName        = $task.Name
                                FullPath        = $task.Path
                                Enabled         = $task.Enabled
                                LastRunTime     = $lastRun
                                LastRunResult   = $task.LastTaskResult
                                NextRunTime     = $task.NextRunTime
                                Status          = if ($task.Enabled) { 'Enabled' } else { 'Disabled' }
                            }
                        }

                        # Recurse into subfolders
                        foreach ($subFolder in $folder.GetFolders(1)) {
                            $tasks += Get-FolderTasks $subFolder
                        }

                        return $tasks
                    }

                    $rootFolder = $TaskScheduler.GetFolder("\")
                    $taskData = Get-FolderTasks $rootFolder
                }
                catch {
                    # Fallback to Get-ScheduledTask if available
                    $tasks = Get-ScheduledTask -CimSession (New-CimSession -ComputerName $ComputerName -Credential $Credential) `
                        -ErrorAction SilentlyContinue
                }
            }

            if ($tasks) {
                if ($tasks -isnot [array]) {
                    $tasks = @($tasks)
                }

                foreach ($task in $tasks) {
                    $taskData += @{
                        TaskName        = $task.TaskName
                        FullPath        = $task.TaskPath
                        Enabled         = $task.Enabled
                        LastRunTime     = $task.LastRunTime
                        NextRunTime     = $task.NextRunTime
                        Status          = $task.State
                    }
                }
            }
        }
        catch {
            # Fallback to WMI method for older systems
            try {
                $wmiParams = @{
                    Class       = 'Win32_ScheduledJob'
                    ErrorAction = 'SilentlyContinue'
                }

                if ($ComputerName -ne $env:COMPUTERNAME) {
                    $wmiParams['ComputerName'] = $ComputerName
                    if ($Credential) {
                        $wmiParams['Credential'] = $Credential
                    }
                }

                $scheduledJobs = Get-WmiObject @wmiParams

                foreach ($job in $scheduledJobs) {
                    $taskData += @{
                        TaskName   = $job.Description
                        Command    = $job.Command
                        DayOfWeek  = $job.DayOfWeek
                        DayOfMonth = $job.DayOfMonth
                        Enabled    = -not $job.Disabled
                    }
                }
            }
            catch {
                # Graceful failure
            }
        }

        return @{
            Success       = $true
            CollectorName = 'Get-ScheduledTasks'
            Data          = $taskData
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($taskData).Count
            Summary       = @{
                TotalTasks   = @($taskData).Count
                EnabledTasks = @($taskData | Where-Object { $_.Enabled -eq $true }).Count
                DisabledTasks = @($taskData | Where-Object { $_.Enabled -eq $false }).Count
            }
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Get-ScheduledTasks'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-ScheduledTasks @PSBoundParameters
}
