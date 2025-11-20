<#
.SYNOPSIS
    Template for creating new collectors with metadata compliance.

.DESCRIPTION
    Copy this template when creating new collectors. Ensure metadata tags match the collector-metadata.json entry.
    
    METADATA TAGS (do not remove):
    - @CollectorName: Get-YourCollectorName
    - @PSVersions: 2.0,4.0,5.1,7.0 (comma-separated, no spaces)
    - @MinWindowsVersion: 2008R2
    - @MaxWindowsVersion: (optional, leave blank if no upper limit)
    - @Dependencies: ModuleName1,ModuleName2 (comma-separated, no spaces)
    - @Timeout: 30 (seconds)
    - @Category: core|application|infrastructure
    - @Critical: true|false (is this collector required for migration decisions?)

.PARAMETER ComputerName
    Target server to audit. Defaults to localhost.

.PARAMETER Credential
    PSCredential for remote connections. Only used if ComputerName is not localhost.

.PARAMETER DryRun
    If $true, validates prerequisites but does not execute collector.

.EXAMPLE
    . .\Get-YourCollectorName.ps1
    $result = Get-YourCollectorName -ComputerName "SERVER01"

.NOTES
    - Always use Try/Catch for robust error handling
    - Return a hashtable with @{ Success=$true; Data=$collectorOutput; Errors=@() }
    - Ensure outputs are serializable (no COM objects in production PS2 environments)
    - Avoid -AsHashTable parameter in PS2 (not supported)
#>

function Get-YourCollectorName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    # @CollectorName: Get-YourCollectorName
    # @PSVersions: 2.0,4.0,5.1,7.0
    # @MinWindowsVersion: 2008R2
    # @MaxWindowsVersion:
    # @Dependencies:
    # @Timeout: 30
    # @Category: core
    # @Critical: true

    $result = @{
        Success        = $false
        CollectorName  = 'Get-YourCollectorName'
        ComputerName   = $ComputerName
        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        ExecutionTime  = 0
        Data           = @{}
        Errors         = @()
        Warnings       = @()
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Validate prerequisites (PS version, Windows feature, module availability)
        if ($DryRun) {
            Write-Verbose "DRY RUN: Validating prerequisites only."
            $result.Success = $true
            $result.Data = @{ DryRun = $true; Message = "Prerequisites validated. Ready to execute." }
            return $result
        }

        # Build invocation parameters
        $invokeParams = @{
            ComputerName = $ComputerName
            ErrorAction  = 'Stop'
        }

        if ($PSBoundParameters.ContainsKey('Credential')) {
            $invokeParams.Credential = $Credential
        }

        # Collect data (example: Get-WmiObject on remote or local)
        if ($ComputerName -eq $env:COMPUTERNAME) {
            # Local execution (faster, no WinRM overhead)
            $collectorData = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
        } else {
            # Remote execution via WMI
            $collectorData = Get-WmiObject -Class Win32_OperatingSystem @invokeParams
        }

        # Normalize output (flatten objects for consistent serialization)
        $result.Data = @{
            CollectedItems = @()
            SummaryCount   = 0
        }

        if ($collectorData) {
            $result.Data.CollectedItems = @($collectorData) | ForEach-Object {
                @{
                    Property1 = $_.Property1
                    Property2 = $_.Property2
                }
            }
            $result.Data.SummaryCount = $result.Data.CollectedItems.Count
        }

        $result.Success = $true

    } catch [System.UnauthorizedAccessException] {
        $result.Errors += "Access Denied: Ensure you have permissions to access $ComputerName"
        Write-Error "Access denied accessing $ComputerName : $_"

    } catch [System.Net.NetworkInformation.PingException] {
        $result.Errors += "Network Error: Cannot reach $ComputerName"
        Write-Error "Cannot reach $ComputerName : $_"

    } catch {
        $result.Errors += "Unexpected Error: $_"
        Write-Error "Collector failed: $_"

    } finally {
        $stopwatch.Stop()
        $result.ExecutionTime = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    }

    return $result
}

# Invoke-AsScript (allows dot-sourcing without exporting function globally)
if ($MyInvocation.InvocationName -eq '.') {
    # Sourced
    Export-ModuleMember -Function Get-YourCollectorName
} else {
    # Direct call
    Get-YourCollectorName @PSBoundParameters
}