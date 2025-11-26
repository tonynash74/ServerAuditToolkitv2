function Get-SATDNS {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName,

    [Parameter(Mandatory=$true)]
    [ValidateNotNull()]
    [hashtable]$Capability,

    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$Credential
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("DNS inventory on {0}" -f $c)
      $useModule = ($Capability.HasDnsModule -and ((Get-SATPSMajor) -ge 3))

      if ($useModule) {
        $scr = {
          Import-Module DnsServer -ErrorAction SilentlyContinue | Out-Null
          $zones = @(); $fw=@()
          try { $zones = Get-DnsServerZone -ErrorAction SilentlyContinue | Select-Object ZoneName, ZoneType, IsDsIntegrated, IsReverseLookupZone } catch {}
          try { $fw = Get-DnsServerForwarder -ErrorAction SilentlyContinue | Select-Object IPAddress, UseRootHint } catch {}
          $res = @{}; $res["Zones"]=$zones; $res["Forwarders"]=$fw; $res["Notes"]='DnsServer module'; return $res
        }
        
        $invokeParams = @{
          ComputerName = $c
          ScriptBlock  = $scr
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
          $invokeParams['Credential'] = $Credential
        }
        
        $res = Invoke-Command @invokeParams
        $out[$c] = $res
      } else {
        # WMI provider on DNS servers
        $scr = {
          $zones = @()
          try {
            $wmi = Get-WmiObject -Namespace root\MicrosoftDNS -Class MicrosoftDNS_Zone -ErrorAction SilentlyContinue
            foreach ($z in $wmi) {
              $zones += New-Object PSObject -Property @{
                ZoneName = $z.Name
                ZoneType = $z.ZoneType
                IsDsIntegrated = $z.DsIntegrated
                IsReverseLookupZone = ($z.Reverse -eq $true)
              }
            }
          } catch {}
          $res = @{}; $res["Zones"]=$zones; $res["Forwarders"]=@(); $res["Notes"]='WMI root\MicrosoftDNS'; return $res
        }
        
        $invokeParams = @{
          ComputerName = $c
          ScriptBlock  = $scr
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
          $invokeParams['Credential'] = $Credential
        }
        
        $res = Invoke-WithRetry -Command {
          Invoke-Command @invokeParams
        } -Description "DNS inventory on $c (WMI provider)" -MaxRetries 3
        $out[$c] = $res
      }
    } catch [System.UnauthorizedAccessException] {
      $error = Convert-AuditError -ErrorRecord $_ -Context "DNS collector on $c"
      Write-Log Error ("DNS collector — {0}: {1}" -f $error.Category, $error.Message)
      Write-Log Info ("Remediation: {0}" -f $error.Remediation)
      $out[$c] = @{ 
        Error = $error.Message
        ErrorType = $error.Category
        ErrorDetails = $error.Remediation
      }
    } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
      $error = Convert-AuditError -ErrorRecord $_ -Context "DNS collector on $c"
      Write-Log Error ("DNS collector — {0}: {1}" -f $error.Category, $error.Message)
      Write-Log Info ("Remediation: {0}" -f $error.Remediation)
      $out[$c] = @{ 
        Error = $error.Message
        ErrorType = $error.Category
        ErrorDetails = $error.Remediation
      }
    } catch {
      $error = Convert-AuditError -ErrorRecord $_ -Context "DNS collector on $c"
      Write-Log Error ("DNS collector — {0}: {1}" -f $error.Category, $error.Message)
      Write-Log Info ("Remediation: {0}" -f $error.Remediation)
      $out[$c] = @{ 
        Error = $error.Message
        ErrorType = $error.Category
        ErrorDetails = $error.Remediation
      }
    }
  }
  return $out
}

