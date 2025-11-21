<#
.SYNOPSIS
    Orchestrates document link extraction and validation across multiple documents.
    
.DESCRIPTION
    High-level wrapper that:
    1. Enumerates documents in a path
    2. Extracts links from each document
    3. Deduplicates links across all documents
    4. Validates all unique links
    5. Generates executive report
    
    This is the primary entry point for MSP usage.

.PARAMETER Path
    Root directory to scan for Office documents

.PARAMETER OutputPath
    Directory for JSON/CSV/HTML results. Default: current directory

.PARAMETER IncludeSubdirectories
    Scan subdirectories recursively. Default: $true

.PARAMETER DocumentFilter
    File extensions to process. Default: .docx, .xlsx, .pptx, .pdf, .docm, .xlsm, .pptm

.PARAMETER ValidateLinks
    Test link accessibility. Default: $true

.PARAMETER GenerateReport
    Create HTML executive report. Default: $true

.EXAMPLE
    Invoke-DocumentLinkAudit -Path 'Z:\Shared\' -OutputPath '.\report' -GenerateReport

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0-POC
    Modified:     2025-11-21
#>

function Invoke-DocumentLinkAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path,

        [Parameter(Mandatory=$false)]
        [string]$OutputPath = (Get-Location).Path,

        [Parameter(Mandatory=$false)]
        [switch]$IncludeSubdirectories = $true,

        [Parameter(Mandatory=$false)]
        [string[]]$DocumentFilter = @('*.docx', '*.xlsx', '*.pptx', '*.pdf', '*.docm', '*.xlsm', '*.pptm'),

        [Parameter(Mandatory=$false)]
        [switch]$ValidateLinks = $true,

        [Parameter(Mandatory=$false)]
        [switch]$GenerateReport = $true,

        [Parameter(Mandatory=$false)]
        [switch]$SkipInternalLinks
    )

    $auditStart = Get-Date
    $outputPath = Resolve-Path $OutputPath -ErrorAction SilentlyContinue
    if (-not $outputPath) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

    Write-Host "Document Link Audit - Starting scan at $Path"

    # ============ PHASE 1: ENUMERATION ============
    Write-Host "PHASE 1: Enumerating documents..."
    $searchParams = @{
        Path = $Path
        Filter = $null
        Recurse = $IncludeSubdirectories
        ErrorAction = 'SilentlyContinue'
    }

    $documents = @()
    foreach ($filter in $DocumentFilter) {
        $searchParams.Filter = $filter
        $documents += Get-ChildItem @searchParams -File
    }

    Write-Host "  Found $($documents.Count) documents"

    if ($documents.Count -eq 0) {
        Write-Host "No documents found matching filter."
        return @{
            Success = $false
            Message = 'No documents found'
            ExecutionTime = (Get-Date) - $auditStart
        }
    }

    # ============ PHASE 2: EXTRACTION ============
    Write-Host "PHASE 2: Extracting links from documents..."
    $allExtractions = @()
    $extractionStart = Get-Date

    foreach ($doc in $documents) {
        try {
            Write-Host "  Processing: $($doc.Name)..." -NoNewline
            
            # Dot-source extraction function
            . (Join-Path (Split-Path $MyInvocation.MyCommand.Path) 'Extract-DocumentLinks.ps1')
            
            $extraction = Extract-DocumentLinks -FilePath $doc.FullName -ResolveContext
            
            if ($extraction.Success) {
                Write-Host " OK ($($extraction.RecordCount) links)"
                $allExtractions += @{
                    Document = $doc.FullName
                    Result   = $extraction
                }
            } else {
                Write-Host " FAILED: $($extraction.Error)"
            }
        }
        catch {
            Write-Host " ERROR: $_"
        }
    }

    $extractedLinks = @()
    foreach ($extraction in $allExtractions) {
        $extractedLinks += $extraction.Result.Links
    }

    Write-Host "EXTRACTION SUMMARY:"
    Write-Host "  Total links extracted: $($extractedLinks.Count)"
    Write-Host "  Unique links: $(@($extractedLinks | Sort-Object -Property Url -Unique).Count)"
    Write-Host "  Extraction time: $(((Get-Date) - $extractionStart).TotalSeconds)s"

    # ============ PHASE 3: VALIDATION ============
    $validationResult = @{ ValidatedLinks = @(); Summary = @{} }

    if ($ValidateLinks -and $extractedLinks.Count -gt 0) {
        Write-Host "PHASE 3: Validating links..."
        
        try {
            . (Join-Path (Split-Path $MyInvocation.MyCommand.Path) 'Test-DocumentLinks.ps1')
            
            $validationResult = Test-DocumentLinks -Links $extractedLinks -SkipInternalLinks:$SkipInternalLinks
            
            Write-Host "VALIDATION SUMMARY:"
            Write-Host "  Links validated: $($validationResult.Summary.TotalLinksValidated)"
            Write-Host "  Valid: $($validationResult.Summary.Valid)"
            Write-Host "  Invalid: $($validationResult.Summary.Invalid)"
            Write-Host "  Unknown: $($validationResult.Summary.Unknown)"
            Write-Host "  Critical risk: $($validationResult.Summary.CriticalRisk)"
            Write-Host "  High risk: $($validationResult.Summary.HighRisk)"
            Write-Host "  Validation time: $(($validationResult.ExecutionTime).TotalSeconds)s"
        }
        catch {
            Write-Host "Warning: Validation phase failed: $_"
        }
    }

    # ============ PHASE 4: REPORTING ============
    Write-Host "PHASE 4: Generating reports..."

    # Export JSON
    $jsonPath = Join-Path $OutputPath 'link-audit-results.json'
    @{
        Audit = @{
            StartTime = $auditStart
            EndTime = Get-Date
            Path = $Path
            DocumentsScanned = $documents.Count
            ExtractionResults = $allExtractions | Select-Object Document, @{n='LinkCount';e={$_.Result.RecordCount}}, @{n='Success';e={$_.Result.Success}}
            ValidationResults = $validationResult.Summary
        }
        Extractions = $allExtractions | Select-Object -ExpandProperty Result
        Validations = $validationResult.ValidatedLinks
    } | ConvertTo-Json -Depth 10 | Set-Content $jsonPath

    Write-Host "  JSON report: $jsonPath"

    # Export CSV (broken links focus)
    $brokenLinks = $validationResult.ValidatedLinks | Where-Object { $_.Valid -eq $false }
    if ($brokenLinks.Count -gt 0) {
        $csvPath = Join-Path $OutputPath 'broken-links.csv'
        $brokenLinks | Select-Object Url, LinkType, RiskLevel, Error, @{n='SourceFiles';e={($_.SourceFiles -join ';')}} | 
            Export-Csv -Path $csvPath -NoTypeInformation
        Write-Host "  Broken links CSV: $csvPath"
    }

    # Export HTML report
    if ($GenerateReport) {
        $htmlPath = Join-Path $OutputPath 'link-audit-report.html'
        New-DocumentLinkAuditHTML -Audit @{
            StartTime = $auditStart
            DocumentsScanned = $documents.Count
            ExtractionResults = $allExtractions
            ValidationResults = $validationResult.Summary
            BrokenLinks = $brokenLinks
        } -OutputPath $htmlPath

        Write-Host "  HTML report: $htmlPath"
    }

    Write-Host ""
    Write-Host "Document Link Audit Complete - Total time: $(((Get-Date) - $auditStart).TotalMinutes)m"

    return @{
        Success = $true
        AuditStart = $auditStart
        AuditEnd = Get-Date
        DocumentsScanned = $documents.Count
        ExtractedLinks = $extractedLinks.Count
        ValidatedLinks = $validationResult.Summary
        OutputPath = $OutputPath
        Reports = @{
            JSON = $jsonPath
            CSV = if ($brokenLinks.Count -gt 0) { $csvPath } else { $null }
            HTML = if ($GenerateReport) { $htmlPath } else { $null }
        }
    }
}

function New-DocumentLinkAuditHTML {
    [CmdletBinding()]
    param(
        [hashtable]$Audit,
        [string]$OutputPath
    )

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Document Link Audit Report</title>
    <style>
        body { font-family: Segoe UI, Arial; color: #333; margin: 20px; background: #f5f5f5; }
        h1 { color: #1f3a93; border-bottom: 3px solid #ff6b35; padding-bottom: 10px; }
        h2 { color: #1f3a93; margin-top: 30px; }
        .card { background: white; padding: 20px; margin: 15px 0; border-radius: 5px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .summary { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 15px; }
        .metric { background: #f9f9f9; padding: 15px; border-left: 4px solid #ff6b35; }
        .metric-value { font-size: 28px; font-weight: bold; color: #1f3a93; }
        .metric-label { font-size: 12px; color: #666; margin-top: 5px; }
        .critical { color: #d32f2f; }
        .high { color: #f57c00; }
        .medium { color: #fbc02d; }
        .low { color: #388e3c; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th { background: #1f3a93; color: white; padding: 10px; text-align: left; }
        td { padding: 8px; border-bottom: 1px solid #ddd; }
        tr:nth-child(even) { background: #f9f9f9; }
        .footer { margin-top: 30px; font-size: 12px; color: #666; }
    </style>
</head>
<body>
    <h1>📋 Document Link Audit Report</h1>
    
    <div class="card">
        <h2>Audit Summary</h2>
        <div class="summary">
            <div class="metric">
                <div class="metric-value">${ $Audit.DocumentsScanned }</div>
                <div class="metric-label">Documents Scanned</div>
            </div>
            <div class="metric">
                <div class="metric-value">${ $Audit.ValidationResults.TotalLinksValidated }</div>
                <div class="metric-label">Unique Links Validated</div>
            </div>
            <div class="metric">
                <div class="metric-value critical">${ $Audit.ValidationResults.CriticalRisk }</div>
                <div class="metric-label">⚠️ Critical Risk Links</div>
            </div>
        </div>
    </div>

    <div class="card">
        <h2>Link Status Overview</h2>
        <div class="summary">
            <div class="metric">
                <div class="metric-value low">${ $Audit.ValidationResults.Valid }</div>
                <div class="metric-label">✅ Valid Links</div>
            </div>
            <div class="metric">
                <div class="metric-value critical">${ $Audit.ValidationResults.Invalid }</div>
                <div class="metric-label">❌ Broken Links</div>
            </div>
            <div class="metric">
                <div class="metric-value medium">${ $Audit.ValidationResults.Unknown }</div>
                <div class="metric-label">❓ Unknown Status</div>
            </div>
        </div>
    </div>

    <div class="card">
        <h2>Risk Distribution</h2>
        <div class="summary">
            <div class="metric">
                <div class="metric-value critical">${ $Audit.ValidationResults.CriticalRisk }</div>
                <div class="metric-label">🔴 Critical</div>
            </div>
            <div class="metric">
                <div class="metric-value high">${ $Audit.ValidationResults.HighRisk }</div>
                <div class="metric-label">🟠 High</div>
            </div>
            <div class="metric">
                <div class="metric-value low">${ $Audit.ValidationResults.LowRisk }</div>
                <div class="metric-label">🟢 Low</div>
            </div>
        </div>
    </div>

    <div class="card">
        <h2>Migration Risk Assessment</h2>
        <div class="summary">
            <div class="metric">
                <div class="metric-value high">${ $Audit.ValidationResults.LocalPaths }</div>
                <div class="metric-label">🔴 Hardcoded Local Paths</div>
            </div>
            <div class="metric">
                <div class="metric-value low">${ $Audit.ValidationResults.UNCPaths }</div>
                <div class="metric-label">🟢 UNC Paths (Safe)</div>
            </div>
            <div class="metric">
                <div class="metric-value medium">${ $Audit.ValidationResults.ExternalURLs }</div>
                <div class="metric-label">🔗 External URLs</div>
            </div>
        </div>
        <p><strong>Migration Impact:</strong></p>
        <ul>
            <li><strong>Hardcoded Local Paths:</strong> Will break after migration. Require path remediation or UNC conversion.</li>
            <li><strong>UNC Paths:</strong> Migration-safe. Network paths remain accessible post-migration.</li>
            <li><strong>External URLs:</strong> Validate availability in target environment.</li>
        </ul>
    </div>

    <div class="card">
        <h2>Broken Links (Migration Blockers)</h2>
        $(
            if ($Audit.BrokenLinks.Count -gt 0) {
                $html_broken = '<table><tr><th>URL</th><th>Type</th><th>Risk</th><th>Error</th></tr>'
                foreach ($link in $Audit.BrokenLinks | Select-Object -First 20) {
                    $html_broken += "<tr><td><code>$($link.Url)</code></td><td>$($link.LinkType)</td><td class=`"$($link.RiskLevel.ToLower())`">$($link.RiskLevel)</td><td>$($link.Error)</td></tr>"
                }
                $html_broken += '</table>'
                if ($Audit.BrokenLinks.Count -gt 20) {
                    $html_broken += "<p><em>Showing 20 of $($Audit.BrokenLinks.Count) broken links. See broken-links.csv for complete list.</em></p>"
                }
                $html_broken
            } else {
                '<p style="color: #388e3c;">✅ No broken links detected!</p>'
            }
        )
    </div>

    <div class="card">
        <h2>Documents Scanned</h2>
        <table>
            <tr><th>Document</th><th>Status</th><th>Links Found</th></tr>
            $(
                foreach ($doc in $Audit.ExtractionResults | Select-Object -First 10) {
                    $status = if ($doc.Result.Success) { '✅' } else { '❌' }
                    $name = Split-Path $doc.Document -Leaf
                    "<tr><td>$name</td><td>$status</td><td>$($doc.Result.RecordCount)</td></tr>"
                }
            )
        </table>
    </div>

    <div class="footer">
        <p>Audit Date: $($Audit.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))</p>
        <p>Report generated by ServerAuditToolkitV2 - Document Link Analysis Engine v1.0</p>
    </div>
</body>
</html>
"@

    $html | Set-Content -Path $OutputPath -Encoding UTF8
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DocumentLinkAudit @PSBoundParameters
}
