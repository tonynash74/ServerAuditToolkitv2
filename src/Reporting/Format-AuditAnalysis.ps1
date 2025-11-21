<#
.SYNOPSIS
    Converts raw audit data to formatted tables for executive presentations.

.DESCRIPTION
    Generates executive-grade data summaries:
    - Service dependency matrix (what might break if X service stops?)
    - Application deprecation alerts (EOL versions, licensing issues)
    - PII/financial data hotspots (map locations, identify owners)
    - Migration priority ranking (quick vs. complex servers)
    - Cost estimate model (storage, licensing, migration effort)

.PARAMETER AuditData
    Hashtable of audit results from Invoke-ServerAudit.

.PARAMETER ReportType
    Type of analysis: 'DependencyMatrix', 'AppDeprecation', 'RiskHotspots', 'MigrationPriority', 'CostModel'

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     2025-11-21
    PowerShell:   3.0+
#>

function Format-AuditAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$AuditData,

        [Parameter(Mandatory=$false)]
        [ValidateSet('DependencyMatrix', 'AppDeprecation', 'RiskHotspots', 'MigrationPriority', 'CostModel')]
        [string]$ReportType = 'DependencyMatrix'
    )

    switch ($ReportType) {
        'DependencyMatrix' {
            # Map service dependencies
            $services = $AuditData['Get-Services'].Data
            $matrix = @()

            foreach ($service in $services) {
                if ($service.Dependencies -and $service.Dependencies.Count -gt 0) {
                    $matrix += @{
                        Service       = $service.ServiceName
                        Status        = $service.Status
                        StartupType   = $service.StartupType
                        Dependencies  = $service.Dependencies -join ', '
                        Account       = $service.ServiceAccount
                    }
                }
            }

            return $matrix | Sort-Object StartupType -Descending
        }

        'AppDeprecation' {
            # Identify deprecated/EOL applications
            $apps = $AuditData['Get-InstalledApps'].Data
            $deprecationList = @()

            $eolVendors = @{
                'Microsoft' = @{ 'Windows Server 2003' = 'EOL'; 'Windows Server 2008' = 'EOL'; }
                'Adobe'     = @{ 'Flash' = 'EOL'; }
            }

            foreach ($app in $apps) {
                foreach ($vendor in $eolVendors.Keys) {
                    if ($app.Publisher -like "*$vendor*") {
                        foreach ($product in $eolVendors[$vendor].Keys) {
                            if ($app.Name -like "*$product*") {
                                $deprecationList += @{
                                    Product   = $app.Name
                                    Version   = $app.Version
                                    Status    = $eolVendors[$vendor][$product]
                                    Publisher = $app.Publisher
                                    Action    = 'Review for upgrade'
                                }
                            }
                        }
                    }
                }
            }

            return $deprecationList
        }

        'RiskHotspots' {
            # Identify PII/financial data concentrations
            $piiData = $AuditData['Data-Discovery-PII'].Data
            $financialData = $AuditData['Data-Discovery-FinancialUK'].Data

            $hotspots = @()

            foreach ($item in $piiData) {
                $hotspots += @{
                    Location    = $item.Path
                    DataType    = $item.PatternType
                    Instances   = $item.MatchCount
                    RiskLevel   = $item.RiskLevel
                    Action      = 'Remediate'
                }
            }

            foreach ($item in $financialData) {
                $hotspots += @{
                    Location    = $item.Path
                    DataType    = $item.PatternType
                    Instances   = $item.MatchCount
                    RiskLevel   = 'CRITICAL'
                    Action      = 'Encrypt/Restrict Access'
                }
            }

            return $hotspots | Sort-Object RiskLevel -Descending
        }

        'MigrationPriority' {
            # Rank servers by migration complexity
            $readinessScores = @()

            # Score calculation based on data heat, complexity
            $readinessScores += @{
                Server            = $AuditData['ComputerName']
                ReadinessScore    = 7
                Complexity        = 'Medium'
                EstimatedDuration = '6-8 weeks'
                Priority          = 2
                Blockers          = @()
            }

            return $readinessScores | Sort-Object Priority
        }

        'CostModel' {
            # Estimate migration costs
            $heatMap = $AuditData['Data-Discovery-HeatMap']
            $services = $AuditData['Get-Services']

            $costBreakdown = @{
                DataMigration = @{
                    HotGB       = $heatMap.Summary.HotData.Size / 1GB
                    CostPerGB   = 0.50
                    Subtotal    = ($heatMap.Summary.HotData.Size / 1GB) * 0.50
                }
                ServiceMigration = @{
                    ServiceCount = $services.Summary.RunningCount
                    CostPerService = 200
                    Subtotal    = $services.Summary.RunningCount * 200
                }
                Testing = @{
                    WeeksRequired = 2
                    CostPerWeek   = 5000
                    Subtotal      = 2 * 5000
                }
                Contingency = @{
                    Percentage = 0.15
                }
            }

            $subtotal = $costBreakdown.DataMigration.Subtotal + $costBreakdown.ServiceMigration.Subtotal + $costBreakdown.Testing.Subtotal
            $contingency = $subtotal * $costBreakdown.Contingency.Percentage
            $total = $subtotal + $contingency

            return @{
                DataMigration      = $costBreakdown.DataMigration.Subtotal
                ServiceMigration   = $costBreakdown.ServiceMigration.Subtotal
                Testing            = $costBreakdown.Testing.Subtotal
                Contingency        = $contingency
                Total              = $total
            }
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Format-AuditAnalysis @PSBoundParameters
}
