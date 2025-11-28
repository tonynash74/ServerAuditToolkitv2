<#
.SYNOPSIS
    PowerShell 7.x shim for the Hyper-V collector.

.DESCRIPTION
    Wraps the PS5 implementation but ensures Hyper-V commands are executed inside
    the Windows PowerShell compatibility layer when required.

.NOTES
    @CollectorName: Get-HyperVInfo-PS7
    @PSVersions: 7.0
    @MinWindowsVersion: 2016
    @Timeout: 75
#>

$ps5CollectorPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PS5x\Get-HyperVInfo-PS5.ps1'
if (Test-Path -LiteralPath $ps5CollectorPath) {
    . $ps5CollectorPath
}

function Get-HyperVInfo-PS7 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    if (-not (Get-Command Get-HyperVInfo-PS5 -ErrorAction SilentlyContinue)) {
        throw 'PS5 Hyper-V collector not available; cannot evaluate PS7 variant.'
    }

    try {
        # PS7 cannot load the Hyper-V module natively; leverage compatibility mode when needed.
        if (-not (Get-Module -Name Hyper-V -ErrorAction SilentlyContinue)) {
            Import-Module Hyper-V -UseWindowsPowerShell -ErrorAction Stop | Out-Null
        }
    } catch {
        # Allow Get-HyperVInfo-PS5 to handle module import errors/fallbacks.
    }

    return Get-HyperVInfo-PS5 @PSBoundParameters
}

if ($MyInvocation.InvocationName -ne '.') {
    Get-HyperVInfo-PS7 @PSBoundParameters
}
