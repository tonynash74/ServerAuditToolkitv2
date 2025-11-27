<#
.SYNOPSIS
    Categorizes audit errors and provides actionable remediation guidance.

.DESCRIPTION
    Converts generic PowerShell exceptions into categorized audit errors with:
    
    - Error category (AuthenticationFailure, NetworkFailure, PermissionDenied, etc.)
    - Clear error message
    - Actionable remediation steps
    - Context about where error occurred
    - Full exception details for logging

    Enables consistent error handling across all collectors.

.PARAMETER ErrorRecord
    The ErrorRecord object from a catch block.
    Required. Typically $_ in catch blocks.

.PARAMETER Context
    Description of what operation was underway when error occurred.
    Examples: "DNS Collection", "Remote Service Enumeration", "IIS Discovery"
    Default: "Audit Operation"

.OUTPUTS
    [PSCustomObject]
    With properties:
      - Category: Error classification (AuthenticationFailure, NetworkFailure, etc.)
      - Message: Clear error message
      - FullError: Complete exception text for logging
      - Remediation: Actionable next steps
      - Context: What operation failed
      - Timestamp: When error occurred

.EXAMPLE
    try {
        Get-Service -ComputerName "BADSERVER" -ErrorAction Stop
    }
    catch {
        $error = Convert-AuditError -ErrorRecord $_ -Context "Service enumeration"
        Write-Host "Error: $($error.Category) - $($error.Message)"
        Write-Host "Fix: $($error.Remediation)"
    }

    # Output:
    # Error: NetworkFailure - The RPC server is unavailable
    # Fix: Check network connectivity to target server and ensure WinRM is running

.EXAMPLE
    try {
        Invoke-Command -ComputerName SERVER01 -ScriptBlock { Get-Process }
    }
    catch {
        $error = Convert-AuditError -ErrorRecord $_
        Export-Csv -InputObject $error -Path "errors.csv" -Append
    }

.NOTES
    Common categories:
    - AuthenticationFailure: Invalid credentials or permission issues
    - NetworkFailure: Cannot reach target (WinRM, network, firewall)
    - RemotingFailure: WinRM/PSRemoting not configured
    - FileMissing: Required file not found
    - PermissionDenied: Access denied to resource
    - TimeoutError: Operation exceeded timeout
    - UnknownError: Generic/uncategorized error

    Use this function consistently in catch blocks to provide
    uniform error reporting and guidance to administrators.

.LINK
    Invoke-ServerAudit
    Invoke-WithRetry
#>

function Convert-AuditError {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory=$false)]
        [string]$Context = "Audit Operation"
    )

    $category = 'UnknownError'
    $remediation = 'Check system logs for more details'
    $exceptionType = $ErrorRecord.Exception.GetType().Name
    $message = $ErrorRecord.Exception.Message

    # -----------------------------------------------------------------
    # Categorize based on exception type
    # -----------------------------------------------------------------

    if ($ErrorRecord.Exception -is [System.UnauthorizedAccessException]) {
        $category = 'PermissionDenied'
        $remediation = 'Verify user account has Administrator privileges on target server'
    }
    elseif ($ErrorRecord.Exception -is [System.Net.Sockets.SocketException]) {
        $category = 'NetworkFailure'
        $remediation = 'Check network connectivity: ping target, verify WinRM on port 5985/5986'
    }
    elseif ($ErrorRecord.Exception -is [System.Management.Automation.Remoting.PSRemotingTransportException]) {
        $category = 'RemotingFailure'
        $remediation = 'Enable WinRM on target: Enable-PSRemoting -Force; check firewall rules'
    }
    elseif ($ErrorRecord.Exception -is [System.IO.FileNotFoundException]) {
        $category = 'FileMissing'
        $remediation = 'Verify file path exists and is accessible; check read permissions'
    }
    elseif ($ErrorRecord.Exception -is [System.IO.DirectoryNotFoundException]) {
        $category = 'DirectoryMissing'
        $remediation = 'Verify directory path exists and is accessible; check network share'
    }
    elseif ($ErrorRecord.Exception -is [System.TimeoutException]) {
        $category = 'TimeoutError'
        $remediation = 'Operation exceeded timeout limit; try again or increase timeout value'
    }
    elseif ($ErrorRecord.Exception -is [System.Management.Automation.RuntimeException]) {
        # Catch generic runtime errors and sub-categorize
        if ($message -match 'Access Denied|access denied') {
            $category = 'PermissionDenied'
            $remediation = 'Verify user has required permissions on target server or resources'
        }
        elseif ($message -match 'The RPC server is unavailable') {
            $category = 'NetworkFailure'
            $remediation = 'RPC service not responding; check target server health and network'
        }
        else {
            $category = 'RuntimeError'
            $remediation = "Investigate runtime error: $message"
        }
    }
    elseif ($ErrorRecord.Exception.Message -match 'Access Denied|access denied') {
        $category = 'PermissionDenied'
        $remediation = 'Verify user account is in Administrators group; check NTFS/share ACLs'
    }
    elseif ($ErrorRecord.Exception.Message -match 'No such file|does not exist|cannot find path') {
        $category = 'FileMissing'
        $remediation = 'Verify path is correct and accessible; check network connectivity to UNC paths'
    }
    elseif ($ErrorRecord.Exception.Message -match 'WinRM|PSRemoting|5985|5986') {
        $category = 'RemotingFailure'
        $remediation = 'Check WinRM service and firewall: Get-Service WinRM; Test-NetConnection -Port 5985'
    }
    elseif ($ErrorRecord.Exception.Message -match 'timed out|timeout|exceeded') {
        $category = 'TimeoutError'
        $remediation = 'Operation took too long; increase timeout or check server load'
    }
    elseif ($ErrorRecord.Exception.Message -match 'authentication|credential|username|password') {
        $category = 'AuthenticationFailure'
        $remediation = 'Verify credentials are correct; check if account is locked or disabled'
    }
    elseif ($ErrorRecord.Exception.Message -match 'cannot connect|connection failed|connection refused') {
        $category = 'NetworkFailure'
        $remediation = 'Target is unreachable; verify network connectivity and firewall rules'
    }

    # -----------------------------------------------------------------
    # Build result object with full details
    # -----------------------------------------------------------------

    $result = [PSCustomObject]@{
        Category = $category
        Message = $message
        ExceptionType = $exceptionType
        FullError = $ErrorRecord | Out-String
        Remediation = $remediation
        Context = $Context
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        InvocationInfo = @{
            ScriptName = $ErrorRecord.InvocationInfo.ScriptName
            LineNumber = $ErrorRecord.InvocationInfo.ScriptLineNumber
            Command = $ErrorRecord.InvocationInfo.MyCommand.Name
        }
    }

    return $result
}

# -----------------------------------------------------------------
# Convenience function for logging categorized errors
# -----------------------------------------------------------------

function Write-AuditError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [PSCustomObject]$AuditError,

        [Parameter(Mandatory=$false)]
        [switch]$IncludeFull
    )

    process {
        Write-Host ""
        Write-Host "================================================" -ForegroundColor DarkGray
        Write-Host "ERROR: $($AuditError.Context)" -ForegroundColor Red
        Write-Host "================================================" -ForegroundColor DarkGray
        Write-Host ""
        
        Write-Host "Category:   " -NoNewline
        Write-Host $AuditError.Category -ForegroundColor Yellow
        
        Write-Host "Message:    " -NoNewline
        Write-Host $AuditError.Message -ForegroundColor White
        
        Write-Host ""
        Write-Host "Remediation:" -ForegroundColor Green
        Write-Host "  -> $($AuditError.Remediation)" -ForegroundColor Green
        Write-Host ""

        if ($IncludeFull) {
            Write-Host "Full Details:" -ForegroundColor DarkGray
            Write-Host $AuditError.FullError -ForegroundColor DarkGray
        }

        Write-Host "Timestamp:  $($AuditError.Timestamp)" -ForegroundColor DarkGray
        Write-Host ""
    }
}
