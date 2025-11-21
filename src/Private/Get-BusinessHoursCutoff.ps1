<#
.SYNOPSIS
    Determines if execution should stop due to approaching business hours.

.DESCRIPTION
    Enforces a business hours cutoff to prevent audit execution jamming during
    the start of the business day. If current time is within N minutes of the
    business start hour, returns $true to signal graceful shutdown.

    For MSP environments, this ensures audits don't overwhelm server resources
    during peak business hours (e.g., 8:00 AM - 5:00 PM).

.PARAMETER BusinessStartHour
    Hour of day when business hours start (0-23). Default: 8 (8:00 AM).

.PARAMETER CutoffMinutesBefore
    How many minutes before business start to stop execution. Default: 60 (stop at 7:00 AM).

.PARAMETER Timezone
    Timezone for business hours calculation. Default: 'Local' (system timezone).
    Examples: 'Pacific Standard Time', 'Central European Time', 'GMT Standard Time'

.EXAMPLE
    if (Test-BusinessHoursCutoff) {
        Write-Warning "Approaching business hours. Stopping audit."
        exit 0
    }

.EXAMPLE
    $cutoff = Test-BusinessHoursCutoff -BusinessStartHour 9 -CutoffMinutesBefore 90
    if ($cutoff) {
        Write-Host "Must stop by 7:30 AM (90 min before 9 AM start)"
    }

.OUTPUTS
    [bool]
    Returns $true if current time is within cutoff window of business start.
    Returns $false if safe to continue execution.

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     2025-11-21
    PowerShell:   2.0+
    License:      MIT

    Use Case:
    - Prevents audit storms during business hours
    - Allows night-time audits (off-hours) to run fully
    - Gracefully stops long-running audits (e.g., data discovery)

    Example Timeline (startHour=8, cutoffMinutes=60):
    - 6:00 AM   → Safe to run (2hr before cutoff)
    - 6:50 AM   → Safe to run (1hr 10min before cutoff)
    - 7:00 AM   → CUTOFF — Stop execution (within 1hr of 8 AM)
    - 8:00 AM   → CUTOFF — Business hours start (STOP)
    - 5:00 PM   → Safe to run again (past business hours)

.LINK
    https://github.com/tonynash74/ServerAuditToolkitv2

#>

function Test-BusinessHoursCutoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [ValidateRange(0, 23)]
        [int]$BusinessStartHour = 8,

        [Parameter(Mandatory=$false)]
        [ValidateRange(0, 1440)]
        [int]$CutoffMinutesBefore = 60,

        [Parameter(Mandatory=$false)]
        [string]$Timezone = 'Local'
    )

    try {
        # Get current time in specified timezone
        $now = if ($Timezone -eq 'Local') {
            Get-Date
        }
        else {
            $tzinfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
            [System.TimeZoneInfo]::ConvertTime((Get-Date), $tzinfo)
        }

        # Calculate cutoff time (N minutes before business start)
        $businessStart = $now.Date.AddHours($BusinessStartHour)
        $cutoffTime = $businessStart.AddMinutes(-$CutoffMinutesBefore)

        # If current time is at or past cutoff, return $true (STOP)
        if ($now -ge $cutoffTime -and $now -lt $businessStart.AddHours(24)) {
            return $true
        }

        return $false
    }
    catch {
        Write-Error "Failed to check business hours cutoff: $_"
        # Fail closed — assume we should stop to be safe
        return $true
    }
}

# Alias for convenience
Set-Alias -Name Test-AuditCutoff -Value Test-BusinessHoursCutoff -Scope Global -Force
