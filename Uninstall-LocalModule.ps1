<#
.SYNOPSIS
    Uninstall the ServerAuditToolkitV2 module from the current user's PowerShell Modules folder.

.DESCRIPTION
    Removes the installed module folder (default: ServerAuditToolkitV2) from the user's PowerShell Modules folder
    (respects redirected Documents such as OneDrive). Also attempts to Remove-Module from the current session.

.PARAMETER ModuleName
    Module folder/name to uninstall. Default: ServerAuditToolkitV2

.PARAMETER Force
    Remove without prompting.

.EXAMPLE
    .\Uninstall-LocalModule.ps1 -Force
#>

param(
    [string]$ModuleName = 'ServerAuditToolkitV2',
    [switch]$Force
)

try {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $userModules = Join-Path $documents 'PowerShell\Modules'
    if (-not (Test-Path $userModules)) {
        $userModules = Join-Path $env:USERPROFILE 'Documents\PowerShell\Modules'
    }

    $modulePath = Join-Path $userModules $ModuleName

    if (-not (Test-Path $modulePath)) {
        Write-Host "Module folder not found at: $modulePath" -ForegroundColor Yellow
        $found = Get-ChildItem -Path ($env:PSModulePath -split ';') -Filter $ModuleName -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $modulePath = $found.FullName } else { Write-Host "No installed module found for '$ModuleName'." -ForegroundColor Cyan; exit 0 }
    }

    if (Get-Module -Name $ModuleName) {
        try {
            Remove-Module -Name $ModuleName -Force -ErrorAction Stop
            Write-Host "Removed module from current session: $ModuleName" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to remove module from session: $_"
        }
    }

    if (Test-Path $modulePath) {
        if ($Force) {
            Remove-Item -LiteralPath $modulePath -Recurse -Force -ErrorAction Stop
            Write-Host "Removed installed module folder: $modulePath" -ForegroundColor Green
        } else {
            $resp = Read-Host "Confirm removal of module folder '$modulePath' (Y/N)"
            if ($resp -in @('Y','y')) {
                Remove-Item -LiteralPath $modulePath -Recurse -Force -ErrorAction Stop
                Write-Host "Removed installed module folder: $modulePath" -ForegroundColor Green
            } else {
                Write-Host "Aborted uninstall. Use -Force to remove without prompting." -ForegroundColor Yellow
            }
        }
    }
} catch {
    Write-Error "Uninstall failed: $($_.Exception.Message)"
    exit 1
}
