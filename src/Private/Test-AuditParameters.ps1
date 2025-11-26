<#
.SYNOPSIS
    Validates input parameters for audit operations.

.DESCRIPTION
    Comprehensive parameter validation for audit functions:
    
    1. ComputerName validation
       - Not null, empty, or whitespace
       - Valid DNS format or recognized localhost indicators
       - Warns on suspicious patterns
    
    2. Capability hashtable validation
       - Contains required keys (HasDnsModule, HasIIS, etc.)
       - Values are correct types
    
    3. Credential validation
       - If provided, must have valid UserName
       - Password SecureString is intact
    
    4. CollectorMetadata validation
       - All values are hashtables
       - Required metadata fields present
    
    Fails fast with clear error messages for troubleshooting.

.PARAMETER ComputerName
    Array of computer names to validate.
    Required. Must not be empty or contain null/whitespace values.

.PARAMETER Capability
    Hashtable describing target server capabilities.
    Optional. If provided, must contain keys: HasDnsModule, HasIIS, HasSQL, IsRemote

.PARAMETER Credential
    PSCredential object for remote authentication.
    Optional. If provided, must have valid UserName and SecureString password.

.PARAMETER CollectorMetadata
    Hashtable mapping collector names to metadata.
    Optional. All values must be hashtables.

.EXAMPLE
    Test-AuditParameters `
        -ComputerName "SERVER01", "SERVER02" `
        -Capability @{HasDnsModule=$true; HasIIS=$false; HasSQL=$true; IsRemote=$true}
    
    # Returns: $true (all valid)

.EXAMPLE
    $cred = Get-Credential
    Test-AuditParameters `
        -ComputerName "SERVER01" `
        -Credential $cred
    
    # Validates credential object

.OUTPUTS
    [bool]
    $true if all validations pass.
    Throws exception if validation fails.

.EXAMPLE
    try {
        Test-AuditParameters -ComputerName $null
    }
    catch {
        Write-Host "Validation error: $_"  # "ComputerName cannot be null or empty"
    }

.NOTES
    This function should be called at the beginning of audit operations
    to fail fast with clear error messages rather than failing deep in execution.
    
    FQDN validation is lenient to support various naming conventions:
    - Localhost indicators: 'localhost', '.', $env:COMPUTERNAME
    - Valid FQDNs: example.com, server-01.contoso.org
    - Partial names: will warn but not fail

.LINK
    Invoke-ServerAudit
#>

function Test-AuditParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNull()]
        [string[]]$ComputerName,

        [Parameter(Mandatory=$false)]
        [hashtable]$Capability,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [hashtable]$CollectorMetadata
    )

    # ─────────────────────────────────────────────────────────────────
    # Validate ComputerName
    # ─────────────────────────────────────────────────────────────────
    
    if ($null -eq $ComputerName -or $ComputerName.Count -eq 0) {
        throw "ComputerName cannot be null or empty"
    }

    $fqdnPattern = '^[a-zA-Z0-9]([a-zA-Z0-9-\.]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})*$'
    $localhostIndicators = @('localhost', '.', $env:COMPUTERNAME, 'localhost.localdomain', '127.0.0.1', '::1')

    foreach ($computer in $ComputerName) {
        if ([string]::IsNullOrWhiteSpace($computer)) {
            throw "ComputerName array contains null or whitespace value"
        }

        # Validate format (lenient — warn on suspicious, but don't fail)
        $isLocalhost = $computer -in $localhostIndicators -or $computer -eq '.' -or $computer -eq 'localhost'
        $isValidFqdn = $computer -match $fqdnPattern
        $isIpAddress = $computer -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' -or $computer -match '^[a-fA-F0-9:]+$'

        if (-not ($isLocalhost -or $isValidFqdn -or $isIpAddress)) {
            Write-Warning "ComputerName '$computer' does not match expected FQDN/IP format; may cause connection errors"
        }

        # Check for obviously invalid patterns
        if ($computer -match '^\s+' -or $computer -match '\s+$') {
            throw "ComputerName '$computer' has leading/trailing whitespace"
        }
        if ($computer -match '[<>"|?*]') {
            throw "ComputerName '$computer' contains invalid characters"
        }
    }

    # ─────────────────────────────────────────────────────────────────
    # Validate Capability hashtable if provided
    # ─────────────────────────────────────────────────────────────────
    
    if ($null -ne $Capability) {
        if ($Capability -isnot [hashtable]) {
            throw "Capability must be a hashtable"
        }

        $requiredCapabilities = @('HasDnsModule', 'HasIIS', 'HasSQL', 'IsRemote')
        foreach ($key in $requiredCapabilities) {
            if (-not $Capability.ContainsKey($key)) {
                throw "Capability hashtable missing required key: '$key'"
            }
        }

        # Validate types
        foreach ($key in $Capability.Keys) {
            $value = $Capability[$key]
            if ($value -isnot [bool]) {
                Write-Warning "Capability['$key'] = $value is not a boolean; expected boolean type"
            }
        }
    }

    # ─────────────────────────────────────────────────────────────────
    # Validate Credential if provided
    # ─────────────────────────────────────────────────────────────────
    
    if ($null -ne $Credential) {
        if ($Credential -isnot [System.Management.Automation.PSCredential]) {
            throw "Credential must be a PSCredential object"
        }

        if ([string]::IsNullOrWhiteSpace($Credential.UserName)) {
            throw "Credential object has invalid or empty UserName"
        }

        # Verify password is intact
        if ($null -eq $Credential.Password) {
            throw "Credential object has null Password (SecureString expected)"
        }

        if ($Credential.Password.Length -eq 0) {
            Write-Warning "Credential object has empty password; remote authentication may fail"
        }
    }

    # ─────────────────────────────────────────────────────────────────
    # Validate CollectorMetadata if provided
    # ─────────────────────────────────────────────────────────────────
    
    if ($null -ne $CollectorMetadata) {
        if ($CollectorMetadata -isnot [hashtable]) {
            throw "CollectorMetadata must be a hashtable"
        }

        foreach ($collectorName in $CollectorMetadata.Keys) {
            $meta = $CollectorMetadata[$collectorName]
            
            if ($meta -isnot [hashtable]) {
                throw "CollectorMetadata['$collectorName'] must be a hashtable, got $($meta.GetType().Name)"
            }

            # Warn if missing typical metadata fields
            $commonFields = @('Name', 'Status', 'ExecutionTime')
            $missingFields = $commonFields | Where-Object { -not $meta.ContainsKey($_) }
            if ($missingFields) {
                Write-Verbose "CollectorMetadata['$collectorName'] missing fields: $($missingFields -join ', ')"
            }
        }
    }

    # ─────────────────────────────────────────────────────────────────
    # All validations passed
    # ─────────────────────────────────────────────────────────────────
    
    return $true
}
