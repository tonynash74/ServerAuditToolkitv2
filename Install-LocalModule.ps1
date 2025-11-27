<#
.SYNOPSIS
    Install the ServerAuditToolkitV2 module into the current user's PowerShell Modules folder

.DESCRIPTION
    Copies `ServerAuditToolkitV2.psd1`, `ServerAuditToolkitV2.psm1` and the `src` folder into
    `$env:USERPROFILE\Documents\PowerShell\Modules\ServerAuditToolkitV2` and then imports the module.

.PARAMETER ModuleName
    Module folder/name to install. Default: ServerAuditToolkitV2

.PARAMETER SourcePath
    Path to the repository root containing `ServerAuditToolkitV2.psd1` and `src`.
    Default: the script's parent folder.

.PARAMETER Force
    Overwrite any existing installation without prompting.

EXAMPLE
    .\Install-LocalModule.ps1 -Force

#>

param(
    [string]$ModuleName = 'ServerAuditToolkitV2',
    [string]$SourcePath = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [switch]$Force
)

try {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $userModules = Join-Path $documents 'PowerShell\Modules'
    if (-not (Test-Path $userModules)) {
        $userModules = Join-Path $env:USERPROFILE 'Documents\PowerShell\Modules'
        if (-not (Test-Path $userModules)) {
            New-Item -ItemType Directory -Path $userModules -Force | Out-Null
        }
    }

    $manifestCandidate = Join-Path $SourcePath "$ModuleName.psd1"
    if (-not (Test-Path $manifestCandidate)) {
        $manifestCandidate = Get-ChildItem -Path $SourcePath -Filter '*.psd1' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -ieq $ModuleName } | Select-Object -First 1 | ForEach-Object { $_.FullName }
    }

    if (-not $manifestCandidate -or -not (Test-Path $manifestCandidate)) {
        Write-Error "Module manifest '$ModuleName.psd1' not found under '$SourcePath'."
        exit 1
    }

    $dest = Join-Path $userModules $ModuleName
    if (Test-Path $dest) {
        if ($Force) {
            Remove-Item -Recurse -Force -Path $dest
        } else {
            $choice = Read-Host "Module already exists at '$dest'. Overwrite? (Y/N)"
            if ($choice -notin @('Y','y')) {
                Write-Host "Aborting install. Use -Force to overwrite."
                exit 0
            }
            Remove-Item -Recurse -Force -Path $dest
        }
    }

    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    Copy-Item -Path $manifestCandidate -Destination $dest -Force
    $psm1Candidate = Join-Path $SourcePath "$ModuleName.psm1"
    if (Test-Path $psm1Candidate) {
        Copy-Item -Path $psm1Candidate -Destination $dest -Force
    } else {
        Write-Warning "Module root psm1 not found at '$psm1Candidate'. Import may fail."
    }

    $srcPath = Join-Path $SourcePath 'src'
    if (Test-Path $srcPath) {
        Copy-Item -Path $srcPath -Destination $dest -Recurse -Force
    } else {
        Write-Warning "No 'src' directory found under '$SourcePath' — ensure module files are present alongside the manifest."
    }

    Write-Host "Installed module files to: $dest"

    try {
        Import-Module -Name $ModuleName -Force -ErrorAction Stop
        Write-Host "Successfully imported module: $ModuleName"
        Get-Command -Module $ModuleName | Select-Object Name,CommandType | Format-Table -AutoSize
    } catch {
        Write-Error "Import-Module failed: $($_.Exception.Message)"
        exit 1
    }
} catch {
    Write-Error "Install failed: $($_.Exception.Message)"
    exit 1
}
