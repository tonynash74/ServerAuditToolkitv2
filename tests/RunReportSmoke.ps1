# Smoke test for New-SATReport
# Usage: RunReportSmoke.ps1 [-ArchiveMode <archive|delete>] [-Compress <$true|$false>]
param(
    [ValidateSet('archive','delete')]
    [string]$ArchiveMode = 'archive',
    [bool]$Compress = $true
)

# Dot-source the report helper
. "$PSScriptRoot\..\src\Private\Report.ps1"

# Provide a minimal Write-Log if not present
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log { param($Level, $Message) Write-Output "[$Level] $Message" }
}

# Minimal sample Data hashtable (only a few collectors)
$sample = @{
    'Get-SATSystem' = @{ 'srv1' = @{ Name = 'srv1' } }
    'Get-SATIIS' = @{ 'srv1' = @{ Sites = @(@{ Name='Default Web Site'; State='Started'; AppPool='DefaultAppPool'; PhysicalPath='C:\inetpub\wwwroot'; Bindings=@(@{protocol='http';bindingInformation='*:80:'}) }); AppPools = @(@{ Name='DefaultAppPool'; State='Started'; RuntimeVersion='v4.0'; PipelineMode='Integrated'; IdentityType='ApplicationPoolIdentity' }) } }
    'Get-SATHyperV' = @{ 'srv1' = @{ VMs = @(@{ Name='vm1'; State='Running'; MemoryAssigned='4GB'; CPUUsage='5'; Uptime='3 days'; Generation='2' }) } }
    'Get-SATSMB' = @{ 'srv1' = @{ Shares = @(@{ Name='Share1'; Path='C:\Shares\Share1'; Description='Test Share'; EncryptData=$false }); Permissions = @(@{ Share='Share1'; Path='C:\Shares\Share1'; NtfsTop = @(@{ IdentityReference='DOMAIN\\User'; FileSystemRights='FullControl'; AccessControlType='Allow'; IsInherited=$false }) }) } }
    'Get-SATCertificates' = @{ 'srv1' = @{ Stores = @{ 'My' = @(@{ Subject='CN=example.com'; Thumbprint='ABC123'; NotBefore=(Get-Date).AddYears(-1); NotAfter=(Get-Date).AddDays(90); HasPrivateKey=$true; FriendlyName='example' }) } } }
    'Get-SATNetwork' = @{ 'srv1' = @{ Adapters = @(@{ Name='Ethernet0'; MacAddress='00-11-22-33-44-55'; InterfaceOperationalStatus='Up'; LinkSpeed='1 Gbps' }); IPConfig = @(@{ InterfaceAlias='Ethernet0'; Description='Ethernet adapter'; IPv4Address = @(@{ IPAddress='192.168.1.10' }); IPv6Address = @(); Ipv4DefaultGateway = @{ NextHop = '192.168.1.1' }; DNSServer = @(@{ ServerAddresses = @('192.168.1.2','192.168.1.3') }); DHCP = $false }) } }
    'Get-SATStorage' = @{ 'srv1' = @{ Volumes = @(@{ DriveLetter='C:'; FileSystemLabel='OS'; FileSystem='NTFS'; Size=100GB; SizeRemaining=60GB; HealthStatus='Healthy'; Path='C:\' }); Disks = @(@{ Number=0; FriendlyName='Disk0'; SerialNumber='SN123'; BusType='SATA'; PartitionStyle='MBR'; HealthStatus='Healthy'; Size=500GB }) } }
    'Get-SATLocalAccounts' = @{ 'srv1' = @{ Users = @(@{ Name='Administrator'; Enabled=$true; LastLogon=(Get-Date).AddDays(-1); PasswordExpires=$false; PasswordRequired=$true; SID='S-1-5-21-...' }); Groups = @(@{ Name='Administrators'; SID='S-1-5-32-544' }); Members = @(@{ Group='Administrators'; Name='Administrator'; ObjectClass='User'; SID='S-1-5-21-...' }) } }
}

$out = Join-Path $PSScriptRoot 'out'
# Ensure out directory exists and is empty
if (-not (Test-Path $out)) {
    New-Item -Path $out -ItemType Directory -Force | Out-Null
} else {
    if ($ArchiveMode -eq 'delete') {
        Get-ChildItem -Path $out -Force | Where-Object { $_.FullName -ne (Join-Path $out 'archive') } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        # Archive existing contents
        $archiveRoot = Join-Path $out 'archive'
        if (-not (Test-Path $archiveRoot)) { New-Item -Path $archiveRoot -ItemType Directory -Force | Out-Null }
        $archiveTs = (Get-Date -Format 'yyyyMMdd_HHmmss')
        $archiveDir = Join-Path $archiveRoot $archiveTs
        New-Item -Path $archiveDir -ItemType Directory -Force | Out-Null
        Get-ChildItem -Path $out -Force | Where-Object { $_.FullName -ne $archiveRoot -and $_.FullName -ne $archiveDir } | ForEach-Object {
            $dest = Join-Path $archiveDir $_.Name
            Move-Item -Path $_.FullName -Destination $dest -Force
        }

        if ($Compress) {
            # Compress the archive directory to a zip and remove the folder
            $zipPath = "${archiveDir}.zip"
            try {
                Compress-Archive -Path (Join-Path $archiveDir '*') -DestinationPath $zipPath -Force
                Remove-Item -Path $archiveDir -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Log Warn "Failed to compress archive $archiveDir : $($_.Exception.Message)"
            }
        }
    }
}

$ts = (Get-Date -Format 'yyyyMMdd_HHmmss')
$report = New-SATReport -Data $sample -OutDir $out -Timestamp $ts

Write-Output "Report generated: $report"
Write-Output "Output directory contents:"
Get-ChildItem -Path $out | ForEach-Object { Write-Output " - $($_.Name) ($($_.Length) bytes)" }
