<#
.SYNOPSIS
    Executes a command with exponential backoff retry on transient failures.

.DESCRIPTION
    Automatically retries PowerShell commands on transient network/remoting failures:
    - SocketException (network down)
    - PSRemotingTransportException (WinRM timeout/connection reset)
    
    Uses exponential backoff: 2s, 4s, 8s between retries.
    Logs all retry attempts for diagnostic purposes.

.PARAMETER Command
    ScriptBlock to execute with retry logic.
    Required.

.PARAMETER MaxRetries
    Maximum number of retry attempts. Default: 3
    Range: 1-10

.PARAMETER InitialDelaySeconds
    Initial delay between retries (exponentially increasing). Default: 2
    Range: 1-10

.PARAMETER Description
    Description of operation for logging.
    If not provided, will attempt to extract from Command.

.PARAMETER Verbose
    Enable verbose logging of retry attempts and delays.

.EXAMPLE
    $result = Invoke-WithRetry -Command {
        Get-Process -Name "svchost"
    } -MaxRetries 3 -Description "Process lookup"

.EXAMPLE
    $remoteData = Invoke-WithRetry -Command {
        Invoke-Command -ComputerName SERVER01 -ScriptBlock {
            Get-Service | Where-Object { $_.Status -eq 'Running' }
        }
    } -Description "Remote service enumeration" -MaxRetries 5

.NOTES
    Transient failures trigger automatic retry with exponential backoff.
    Permanent failures (auth errors, etc.) are thrown immediately.
    All retry attempts are logged to verbose stream.

.LINK
    Get-ErrorCategory
#>

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [scriptblock]$Command,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 10)]
        [int]$MaxRetries = 3,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 10)]
        [int]$InitialDelaySeconds = 2,

        [Parameter(Mandatory=$false)]
        [string]$Description = "Command execution"
    )

    $attempt = 0
    $delay = $InitialDelaySeconds

    while ($attempt -lt $MaxRetries) {
        try {
            $attempt++
            Write-Verbose "[$Description] Attempt $attempt of $MaxRetries"
            return & $Command
        }
        catch {
            $exception = $_.Exception
            
            # Check if this is a transient error (retry-worthy)
            $isTransient = $false
            $exceptionType = $exception.GetType().Name

            if ($exception -is [System.Net.Sockets.SocketException]) {
                $isTransient = $true
                $errorType = "Network/Socket"
            }
            elseif ($exception -is [System.Management.Automation.Remoting.PSRemotingTransportException]) {
                $isTransient = $true
                $errorType = "WinRM/Remoting"
            }
            elseif ($exception.Message -match "The specified file does not exist|No such file" -and $attempt -lt 2) {
                # Transient file access issues sometimes succeed on retry
                $isTransient = $true
                $errorType = "File Access"
            }

            if ($isTransient -and $attempt -lt $MaxRetries) {
                Write-Warning ("[$Description] Transient {0} error (attempt {1}/{2}): {3}" -f $errorType, $attempt, $MaxRetries, $exception.Message)
                Write-Verbose "[$Description] Retrying in ${delay}s... (exponential backoff)"
                Start-Sleep -Seconds $delay
                $delay *= 2  # Exponential backoff
            }
            else {
                # Permanent error or max retries reached
                if ($attempt -ge $MaxRetries) {
                    Write-Error ("[$Description] Failed after $MaxRetries attempts: {0}" -f $exception.Message)
                }
                throw
            }
        }
    }
}

# Alias for convenience
Set-Alias -Name Retry -Value Invoke-WithRetry -Force -ErrorAction SilentlyContinue
