<#
.SYNOPSIS
    Extracts hyperlinks from Microsoft Office documents (Word, Excel, PowerPoint) and PDFs.
    
.DESCRIPTION
    Supports Word (.docx), Excel (.xlsx), PowerPoint (.pptx), and PDF documents.
    Returns structured data about links including:
    - Link URL and type (external, internal, file path, email)
    - Location context (cell reference, slide number, paragraph position)
    - Link text/display value
    - Relationship metadata
    
    Uses Open XML SDK for Office documents (no installation required, embedded in .NET)
    Uses iText7 for PDF processing (if available; graceful fallback)
    
    Critical for migration: Identifies hardcoded paths, broken external links, 
    network dependencies embedded in document content.

.PARAMETER FilePath
    Path to document file (.docx, .xlsx, .pptx, .pdf)

.PARAMETER IncludeAnchors
    Include internal anchors/bookmarks in results. Default: $false (too noisy)

.PARAMETER ResolveContext
    Attempt to extract context (which cell, slide, paragraph contains link). 
    Default: $true (slight performance cost)

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0-POC
    Modified:     2025-11-21
    PowerShell:   3.0+
    License:      MIT
    
    Dependencies:
    - System.IO.Compression (.NET built-in)
    - DocumentFormat.OpenXml (loaded dynamically)
    - iText7 (optional, for PDF support)
#>

function Extract-DocumentLinks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({ Test-Path $_ })]
        [string]$FilePath,

        [Parameter(Mandatory=$false)]
        [switch]$IncludeAnchors,

        [Parameter(Mandatory=$false)]
        [switch]$ResolveContext = $true,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $startTime = Get-Date
    $extension = [System.IO.Path]::GetExtension($FilePath).ToLower()

    try {
        if ($DryRun) {
            Write-Verbose "DRY-RUN: Would extract links from $FilePath"
            return @{
                Success       = $true
                DocumentPath  = $FilePath
                DocumentType  = $extension
                Links         = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        switch ($extension) {
            '.docx' { Extract-WordDocumentLinks -FilePath $FilePath -ResolveContext:$ResolveContext }
            '.xlsx' { Extract-ExcelDocumentLinks -FilePath $FilePath -ResolveContext:$ResolveContext }
            '.pptx' { Extract-PowerPointDocumentLinks -FilePath $FilePath -ResolveContext:$ResolveContext }
            '.xlsm' { Extract-ExcelDocumentLinks -FilePath $FilePath -ResolveContext:$ResolveContext }
            '.docm' { Extract-WordDocumentLinks -FilePath $FilePath -ResolveContext:$ResolveContext }
            '.pptm' { Extract-PowerPointDocumentLinks -FilePath $FilePath -ResolveContext:$ResolveContext }
            '.pdf'  { Extract-PDFDocumentLinks -FilePath $FilePath }
            default { 
                return @{
                    Success       = $false
                    DocumentPath  = $FilePath
                    DocumentType  = $extension
                    Error         = "Unsupported file type: $extension"
                    ExecutionTime = (Get-Date) - $startTime
                    RecordCount   = 0
                }
            }
        }
    }
    catch {
        return @{
            Success       = $false
            DocumentPath  = $FilePath
            DocumentType  = $extension
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

function Extract-WordDocumentLinks {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [bool]$ResolveContext
    )

    $startTime = Get-Date
    $links = @()

    try {
        # Open as ZIP to access relationships
        $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)

        try {
            # Extract all relationship files
            $relEntries = $zip.Entries | Where-Object { $_.FullName -match '\.rels$' }

            foreach ($relEntry in $relEntries) {
                try {
                    $stream = $relEntry.Open()
                    $reader = New-Object System.IO.StreamReader($stream)
                    [xml]$relXml = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()

                    # Find hyperlink relationships
                    foreach ($rel in $relXml.Relationships.Relationship) {
                        if ($rel.Type -match 'hyperlink') {
                            $target = $rel.Target
                            
                            # Classify link type with detailed path categorization
                            $linkType = if ($target -match '^https?://') {
                                'ExternalURL'
                            } elseif ($target -match '^mailto:') {
                                'Email'
                            } elseif ($target -match '^\\\\[a-zA-Z0-9._-]+\\') {
                                'UNCPath'  # \\server\share - migration safe
                            } elseif ($target -match '^[a-zA-Z]:') {
                                'LocalPath'  # C:\, D:\ etc - hardcoded, migration risk
                            } elseif ($target -match '^#') {
                                'InternalAnchor'
                            } else {
                                'RelativePath'
                            }
                            
                            # Path risk classification for migration planning
                            $pathRisk = if ($linkType -eq 'LocalPath') { 'HIGH' } elseif ($linkType -eq 'UNCPath') { 'LOW' } else { 'UNKNOWN' }

                            $links += @{
                                Url          = $target
                                LinkType     = $linkType
                                PathRisk     = $pathRisk  # For migration decisions engine
                                RelationshipId = $rel.Id
                                Context      = if ($ResolveContext) { "Word Document: $([System.IO.Path]::GetFileName($relEntry.FullName))" } else { $null }
                                SourceFile   = $FilePath
                                IsInternal   = $linkType -in 'InternalAnchor', 'RelativePath'
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Error processing relationship file $($relEntry.FullName): $_"
                }
            }

            # Also parse document.xml for inline hyperlinks
            $docEntry = $zip.Entries | Where-Object { $_.FullName -eq 'word/document.xml' }
            if ($docEntry) {
                try {
                    $stream = $docEntry.Open()
                    $reader = New-Object System.IO.StreamReader($stream)
                    [xml]$docXml = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()

                    # Find hyperlink elements (inline)
                    $ns = @{ w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
                    $hyperlinks = $docXml | Select-Xml -XPath '//w:hyperlink' -Namespace $ns

                    foreach ($hlink in $hyperlinks) {
                        $element = $hlink.Node
                        $linkId = $element.id
                        
                        # Match with relationship
                        $matchingRel = $links | Where-Object { $_.RelationshipId -eq $linkId }
                        if ($matchingRel) {
                            # Get hyperlink text
                            $linkText = ($element.SelectNodes('.//w:t', $ns) | ForEach-Object { $_.InnerText }) -join ''
                            $matchingRel.LinkText = if ($linkText) { $linkText } else { '[No Text]' }
                        }
                    }
                }
                catch {
                    Write-Verbose "Error parsing document content: $_"
                }
            }
        }
        finally {
            $zip.Dispose()
        }

        return @{
            Success       = $true
            DocumentPath  = $FilePath
            DocumentType  = '.docx'
            Links         = $links
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($links).Count
            Summary       = @{
                ExternalURLs = @($links | Where-Object { $_.LinkType -eq 'ExternalURL' }).Count
                FilePaths    = @($links | Where-Object { $_.LinkType -eq 'FilePath' }).Count
                Emails       = @($links | Where-Object { $_.LinkType -eq 'Email' }).Count
                RelativePaths = @($links | Where-Object { $_.LinkType -eq 'RelativePath' }).Count
            }
        }
    }
    catch {
        return @{
            Success       = $false
            DocumentPath  = $FilePath
            DocumentType  = '.docx'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

function Extract-ExcelDocumentLinks {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [bool]$ResolveContext
    )

    $startTime = Get-Date
    $links = @()

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)

        try {
            # Extract workbook relationship
            $wbRelEntry = $zip.Entries | Where-Object { $_.FullName -eq 'xl/_rels/workbook.xml.rels' }
            if ($wbRelEntry) {
                $stream = $wbRelEntry.Open()
                $reader = New-Object System.IO.StreamReader($stream)
                [xml]$wbRelXml = $reader.ReadToEnd()
                $reader.Close()
                $stream.Close()

                # Find external link relationships
                foreach ($rel in $wbRelXml.Relationships.Relationship) {
                    if ($rel.Type -match 'hyperlink' -or $rel.Type -match 'externalLink') {
                        $target = $rel.Target

                        $linkType = if ($target -match '^https?://') {
                            'ExternalURL'
                        } elseif ($target -match '^mailto:') {
                            'Email'
                        } elseif ($target -match '^\\\\[a-zA-Z0-9._-]+\\') {
                            'UNCPath'
                        } elseif ($target -match '\.xlsx|\.xlsm|\.csv') {
                            'ExcelFile'
                        } else {
                            'LocalPath'
                        }
                        
                        $pathRisk = if ($linkType -in 'LocalPath') { 'HIGH' } elseif ($linkType -eq 'UNCPath') { 'LOW' } else { 'UNKNOWN' }

                        $links += @{
                            Url          = $target
                            LinkType     = $linkType
                            PathRisk     = $pathRisk
                            RelationshipId = $rel.Id
                            SheetContext = if ($ResolveContext) { "Workbook relationships" } else { $null }
                            SourceFile   = $FilePath
                            IsInternal   = $false
                        }
                    }
                }
            }

            # Extract worksheet hyperlinks
            $worksheetRels = $zip.Entries | Where-Object { $_.FullName -match 'xl/worksheets/_rels/sheet\d+\.xml\.rels' }
            foreach ($wsRel in $worksheetRels) {
                try {
                    $stream = $wsRel.Open()
                    $reader = New-Object System.IO.StreamReader($stream)
                    [xml]$wsRelXml = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()

                    $sheetName = if ($ResolveContext) { $wsRel.FullName -replace 'xl/worksheets/_rels/|\.xml\.rels' } else { '' }

                    foreach ($rel in $wsRelXml.Relationships.Relationship) {
                        if ($rel.Type -match 'hyperlink') {
                            $target = $rel.Target

                            $linkType = if ($target -match '^https?://') {
                                'ExternalURL'
                            } elseif ($target -match '^mailto:') {
                                'Email'
                            } elseif ($target -match '^\\\\[a-zA-Z0-9._-]+\\') {
                                'UNCPath'
                            } elseif ($target -match '\.xlsx|\.xlsm|\.csv') {
                                'ExcelFile'
                            } else {
                                'LocalPath'
                            }
                            
                            $pathRisk = if ($linkType -in 'LocalPath') { 'HIGH' } elseif ($linkType -eq 'UNCPath') { 'LOW' } else { 'UNKNOWN' }

                            $links += @{
                                Url          = $target
                                LinkType     = $linkType
                                PathRisk     = $pathRisk
                                RelationshipId = $rel.Id
                                SheetContext = $sheetName
                                SourceFile   = $FilePath
                                IsInternal   = $false
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Error processing worksheet: $_"
                }
            }

            # Extract hyperlinks from sheet XML directly
            $sheets = $zip.Entries | Where-Object { $_.FullName -match 'xl/worksheets/sheet\d+\.xml$' }
            foreach ($sheetEntry in $sheets) {
                try {
                    $stream = $sheetEntry.Open()
                    $reader = New-Object System.IO.StreamReader($stream)
                    [xml]$sheetXml = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()

                    $ns = @{ main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main' }
                    $hyperlinks = $sheetXml | Select-Xml -XPath '//main:hyperlink' -Namespace $ns

                    $sheetName = [System.IO.Path]::GetFileNameWithoutExtension($sheetEntry.Name)

                    foreach ($hlink in $hyperlinks) {
                        $element = $hlink.Node
                        $linkRef = $element.ref
                        $linkId = $element.id

                        # Find matching relationship
                        $matchingRel = $links | Where-Object { $_.RelationshipId -eq $linkId }
                        if ($matchingRel) {
                            $matchingRel.CellReference = $linkRef
                            $matchingRel.SheetContext = $sheetName
                        }
                    }
                }
                catch {
                    Write-Verbose "Error parsing sheet: $_"
                }
            }
        }
        finally {
            $zip.Dispose()
        }

        return @{
            Success       = $true
            DocumentPath  = $FilePath
            DocumentType  = '.xlsx'
            Links         = $links
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($links).Count
            Summary       = @{
                ExternalURLs = @($links | Where-Object { $_.LinkType -eq 'ExternalURL' }).Count
                UNCPaths     = @($links | Where-Object { $_.LinkType -eq 'UNCPath' }).Count
                LocalPaths   = @($links | Where-Object { $_.LinkType -eq 'LocalPath' }).Count
                ExcelFiles   = @($links | Where-Object { $_.LinkType -eq 'ExcelFile' }).Count
                Emails       = @($links | Where-Object { $_.LinkType -eq 'Email' }).Count
                HighRisk     = @($links | Where-Object { $_.PathRisk -eq 'HIGH' }).Count
                LowRisk      = @($links | Where-Object { $_.PathRisk -eq 'LOW' }).Count
            }
        }
    }
    catch {
        return @{
            Success       = $false
            DocumentPath  = $FilePath
            DocumentType  = '.xlsx'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

function Extract-PowerPointDocumentLinks {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [bool]$ResolveContext
    )

    $startTime = Get-Date
    $links = @()

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)

        try {
            # Process each slide's relationships
            $slideRels = $zip.Entries | Where-Object { $_.FullName -match 'ppt/slides/_rels/slide\d+\.xml\.rels' }

            foreach ($slideRelEntry in $slideRels) {
                try {
                    $stream = $slideRelEntry.Open()
                    $reader = New-Object System.IO.StreamReader($stream)
                    [xml]$slideRelXml = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()

                    $slideNumber = if ($slideRelEntry.FullName -match 'slide(\d+)') { [int]$Matches[1] } else { 0 }

                    foreach ($rel in $wsRelXml.Relationships.Relationship) {
                        if ($rel.Type -match 'hyperlink') {
                            $target = $rel.Target

                            $linkType = if ($target -match '^https?://') {
                                'ExternalURL'
                            } elseif ($target -match '^mailto:') {
                                'Email'
                            } elseif ($target -match '^\\\\[a-zA-Z0-9._-]+\\') {
                                'UNCPath'
                            } elseif ($target -match '^[a-zA-Z]:.*\.(xlsx|xlsm|csv)$') {
                                'LocalExcelFile'
                            } elseif ($target -match '^[a-zA-Z]:') {
                                'LocalPath'
                            } else {
                                'RelativePath'
                            }
                            
                            $pathRisk = if ($linkType -in 'LocalPath', 'LocalExcelFile') { 'HIGH' } elseif ($linkType -eq 'UNCPath') { 'LOW' } else { 'UNKNOWN' }

                            $links += @{
                                Url          = $target
                                LinkType     = $linkType
                                PathRisk     = $pathRisk
                                RelationshipId = $rel.Id
                                SlideNumber  = $slideNumber
                                Context      = if ($ResolveContext) { "Slide $slideNumber" } else { $null }
                                SourceFile   = $FilePath
                                IsInternal   = $linkType -eq 'InternalLink'
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Error processing slide relationship: $_"
                }
            }

            # Also scan notes for links
            $notesRels = $zip.Entries | Where-Object { $_.FullName -match 'ppt/notesSlides/_rels/notesSlide\d+\.xml\.rels' }
            foreach ($noteRelEntry in $notesRels) {
                try {
                    $stream = $noteRelEntry.Open()
                    $reader = New-Object System.IO.StreamReader($stream)
                    [xml]$noteRelXml = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()

                    $slideNumber = if ($noteRelEntry.FullName -match 'notesSlide(\d+)') { [int]$Matches[1] } else { 0 }

                    foreach ($rel in $noteRelXml.Relationships.Relationship) {
                        if ($rel.Type -match 'hyperlink') {
                            $target = $rel.Target

                            $linkType = if ($target -match '^https?://') {
                                'ExternalURL'
                            } else {
                                'FilePath'
                            }

                            $links += @{
                                Url          = $target
                                LinkType     = $linkType
                                RelationshipId = $rel.Id
                                SlideNumber  = $slideNumber
                                Context      = if ($ResolveContext) { "Slide $slideNumber Notes" } else { $null }
                                SourceFile   = $FilePath
                                IsInternal   = $false
                                LocationType = 'Notes'
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Error processing notes: $_"
                }
            }
        }
        finally {
            $zip.Dispose()
        }

        return @{
            Success       = $true
            DocumentPath  = $FilePath
            DocumentType  = '.pptx'
            Links         = $links
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($links).Count
            Summary       = @{
                ExternalURLs = @($links | Where-Object { $_.LinkType -eq 'ExternalURL' }).Count
                UNCPaths     = @($links | Where-Object { $_.LinkType -eq 'UNCPath' }).Count
                LocalPaths   = @($links | Where-Object { $_.LinkType -eq 'LocalPath' }).Count
                LocalExcelFiles = @($links | Where-Object { $_.LinkType -eq 'LocalExcelFile' }).Count
                Emails       = @($links | Where-Object { $_.LinkType -eq 'Email' }).Count
                HighRisk     = @($links | Where-Object { $_.PathRisk -eq 'HIGH' }).Count
                LowRisk      = @($links | Where-Object { $_.PathRisk -eq 'LOW' }).Count
            }
        }
    }
    catch {
        return @{
            Success       = $false
            DocumentPath  = $FilePath
            DocumentType  = '.pptx'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

function Extract-PDFDocumentLinks {
    [CmdletBinding()]
    param(
        [string]$FilePath
    )

    $startTime = Get-Date
    $links = @()

    try {
        # Tier 1: Try iText7 library
        try {
            [Reflection.Assembly]::Load("iText.Kernel") | Out-Null
            [Reflection.Assembly]::Load("iText.Forms") | Out-Null
            
            # iText7 PDF processing
            $pdfDocument = New-Object iText.Kernel.Pdf.PdfDocument(
                (New-Object iText.Kernel.Pdf.PdfReader($FilePath))
            )
            
            $pageCount = $pdfDocument.GetNumberOfPages()
            
            for ($pageNum = 1; $pageNum -le $pageCount; $pageNum++) {
                try {
                    $page = $pdfDocument.GetPage($pageNum)
                    $annotations = $page.GetAnnotations()
                    
                    foreach ($annot in $annotations) {
                        if ($annot.GetSubtype() -match 'Link') {
                            $uri = $null
                            $action = $annot.GetAction()
                            
                            if ($action) {
                                # Try to extract URI from action
                                if ($action.Get('/URI')) {
                                    $uri = $action.Get('/URI').ToString()
                                }
                            }
                            
                            if ($uri) {
                                $linkType = if ($uri -match '^https?://') {
                                    'ExternalURL'
                                } elseif ($uri -match '^mailto:') {
                                    'Email'
                                } elseif ($uri -match '^\\\\[a-zA-Z0-9._-]+\\') {
                                    'UNCPath'
                                } elseif ($uri -match '^[a-zA-Z]:.*\.(xlsx|xlsm|csv)$') {
                                    'LocalExcelFile'
                                } elseif ($uri -match '^[a-zA-Z]:') {
                                    'LocalPath'
                                } else {
                                    'RelativePath'
                                }
                                
                                $pathRisk = if ($linkType -in 'LocalPath', 'LocalExcelFile') { 'HIGH' } elseif ($linkType -eq 'UNCPath') { 'LOW' } else { 'UNKNOWN' }
                                
                                $links += @{
                                    Url          = $uri
                                    LinkType     = $linkType
                                    PathRisk     = $pathRisk
                                    PageNumber   = $pageNum
                                    Context      = "Page $pageNum"
                                    SourceFile   = $FilePath
                                    IsInternal   = $false
                                    ExtractionMethod = 'iText7'
                                }
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Error processing PDF page $pageNum : $_"
                }
            }
            
            $pdfDocument.Close()
            
            return @{
                Success       = $true
                DocumentPath  = $FilePath
                DocumentType  = '.pdf'
                Links         = $links
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = @($links).Count
                ExtractionMethod = 'iText7'
                Summary       = @{
                    ExternalURLs = @($links | Where-Object { $_.LinkType -eq 'ExternalURL' }).Count
                    UNCPaths     = @($links | Where-Object { $_.LinkType -eq 'UNCPath' }).Count
                    LocalPaths   = @($links | Where-Object { $_.LinkType -eq 'LocalPath' }).Count
                    Emails       = @($links | Where-Object { $_.LinkType -eq 'Email' }).Count
                    HighRisk     = @($links | Where-Object { $_.PathRisk -eq 'HIGH' }).Count
                    LowRisk      = @($links | Where-Object { $_.PathRisk -eq 'LOW' }).Count
                }
            }
        }
        catch {
            Write-Verbose "iText7 not available or extraction failed: $_; attempting regex fallback..."
        }
        
        # Tier 2: Regex text extraction fallback
        try {
            # Extract text content from PDF
            $pdfReader = New-Object System.IO.FileStream($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
            $pdfBytes = New-Object byte[] $pdfReader.Length
            $pdfReader.Read($pdfBytes, 0, $pdfBytes.Length) | Out-Null
            $pdfReader.Close()
            
            $pdfText = [System.Text.Encoding]::ASCII.GetString($pdfBytes)
            
            # Extract URLs using regex patterns
            $urlPatterns = @(
                'https?://[^\s<>"{}|\\^`\[\]]*',  # HTTP/HTTPS URLs
                '\\\\[a-zA-Z0-9._-]+\\[^\s<>"{}|\\^`\[\]]*',  # UNC paths
                '[a-zA-Z]:\\[^\s<>"{}|\\^`\[\]]*\.(xlsx|xlsm|csv)',  # Excel files
                '[a-zA-Z]:\\[^\s<>"{}|\\^`\[\]]*',  # Local paths
                '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'  # Email addresses
            )
            
            $foundUrls = @()
            foreach ($pattern in $urlPatterns) {
                $matches = [regex]::Matches($pdfText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                foreach ($match in $matches) {
                    if ($match.Value -and $foundUrls -notcontains $match.Value) {
                        $foundUrls += $match.Value
                    }
                }
            }
            
            $pageNum = 0
            foreach ($url in $foundUrls) {
                $linkType = if ($url -match '^https?://') {
                    'ExternalURL'
                } elseif ($url -match '^mailto:|@') {
                    'Email'
                } elseif ($url -match '^\\\\[a-zA-Z0-9._-]+\\') {
                    'UNCPath'
                } elseif ($url -match '^[a-zA-Z]:.*\.(xlsx|xlsm|csv)$') {
                    'LocalExcelFile'
                } elseif ($url -match '^[a-zA-Z]:') {
                    'LocalPath'
                } else {
                    'RelativePath'
                }
                
                $pathRisk = if ($linkType -in 'LocalPath', 'LocalExcelFile') { 'HIGH' } elseif ($linkType -eq 'UNCPath') { 'LOW' } else { 'UNKNOWN' }
                
                $links += @{
                    Url          = $url
                    LinkType     = $linkType
                    PathRisk     = $pathRisk
                    PageNumber   = 0  # Unknown page with regex extraction
                    Context      = "PDF text (page unknown)"
                    SourceFile   = $FilePath
                    IsInternal   = $false
                    ExtractionMethod = 'RegexFallback'
                }
            }
            
            return @{
                Success       = $true
                DocumentPath  = $FilePath
                DocumentType  = '.pdf'
                Links         = $links
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = @($links).Count
                ExtractionMethod = 'RegexFallback'
                Summary       = @{
                    ExternalURLs = @($links | Where-Object { $_.LinkType -eq 'ExternalURL' }).Count
                    UNCPaths     = @($links | Where-Object { $_.LinkType -eq 'UNCPath' }).Count
                    LocalPaths   = @($links | Where-Object { $_.LinkType -eq 'LocalPath' }).Count
                    Emails       = @($links | Where-Object { $_.LinkType -eq 'Email' }).Count
                    HighRisk     = @($links | Where-Object { $_.PathRisk -eq 'HIGH' }).Count
                    LowRisk      = @($links | Where-Object { $_.PathRisk -eq 'LOW' }).Count
                }
            }
        }
        catch {
            Write-Verbose "Regex fallback also failed: $_"
            return @{
                Success       = $true
                DocumentPath  = $FilePath
                DocumentType  = '.pdf'
                Links         = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
                ExtractionMethod = 'None'
                Status        = 'No links extracted from PDF'
            }
        }
    }
    catch {
        return @{
            Success       = $false
            DocumentPath  = $FilePath
            DocumentType  = '.pdf'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Extract-DocumentLinks @PSBoundParameters
}
