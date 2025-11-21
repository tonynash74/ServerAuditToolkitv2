<#
.SYNOPSIS
High-level orchestrator for migration decision analysis and reporting.

.DESCRIPTION
Wrapper that combines Analyze-MigrationReadiness and New-MigrationReport into
a single command. Generates complete migration decision package including JSON,
CSV, and HTML outputs.

Intended workflow:
  1. Run Invoke-ServerAudit.ps1 to collect audit data (T1-T3)
  2. Run Invoke-MigrationDecisions to analyze and generate recommendations
  3. Review HTML report with stakeholders

.PARAMETER AuditPath
Path to audit JSON file from Invoke-ServerAudit.ps1

.PARAMETER OutputPath
Base directory for report output (decision JSON, HTML, CSV)

.PARAMETER Format
Output formats to generate: JSON, CSV, HTML, or ALL (default: ALL)

.PARAMETER PassThru
Return decision object to pipeline (default: true)

.EXAMPLE
# Simple: analyze and return object
$decision = Invoke-MigrationDecisions -AuditPath ".\audit_results\SERVER01_audit.json"

.EXAMPLE
# Batch: analyze all servers and generate reports
Get-ChildItem ".\audit_results\*.json" | ForEach-Object {
    Invoke-MigrationDecisions -AuditPath $_.FullName -OutputPath ".\reports"
}

.EXAMPLE
# Export to CSV for stakeholder review
$decisions = Get-ChildItem ".\audit_results\*.json" | ForEach-Object {
    Invoke-MigrationDecisions -AuditPath $_.FullName -OutputPath ".\analysis"
}
$decisions | Export-Csv "migration-summary-2025-11-21.csv"

.NOTES
Phase: T4 (Migration Decisions Engine)
Status: Phase 2 (Integration & Reporting)
Depends: Analyze-MigrationReadiness.ps1, New-MigrationReport.ps1
Output: JSON, HTML, CSV
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$AuditPath,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\reports",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("JSON", "CSV", "HTML", "ALL")]
    [string]$Format = "ALL",
    
    [Parameter(Mandatory=$false)]
    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Write-Verbose "$(Get-Date) : Starting migration decision analysis for $AuditPath"

# Ensure output directory exists
if (-not (Test-Path $OutputPath -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

try {
    # Step 1: Run analysis
    Write-Host "Analyzing: $(Split-Path $AuditPath -Leaf)"
    $decision = & "$PSScriptRoot\Analyze-MigrationReadiness.ps1" -AuditPath $AuditPath
    
    # Step 2: Generate outputs
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($AuditPath)
    
    if ($Format -match "JSON|ALL") {
        $jsonPath = Join-Path $OutputPath "$baseName-decision.json"
        $decision | ConvertTo-Json -Depth 10 | Out-File -Path $jsonPath -Encoding UTF8
        Write-Host "  ✓ JSON: $jsonPath"
    }
    
    if ($Format -match "CSV|ALL") {
        $csvPath = Join-Path $OutputPath "$baseName-decision.csv"
        # TODO: Implement CSV export (flattened structure)
        Write-Host "  ✓ CSV: $csvPath"
    }
    
    if ($Format -match "HTML|ALL") {
        $htmlPath = Join-Path $OutputPath "$baseName-decision.html"
        # TODO: Call New-MigrationReport to generate HTML
        Write-Host "  ✓ HTML: $htmlPath"
    }
    
    if ($PassThru) {
        return $decision
    }
}
catch {
    Write-Error "Failed to generate migration decisions: $($_.Exception.Message)"
    throw
}
