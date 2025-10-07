function Get-SATCertificates {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability
  )

  $stores = @('My','WebHosting','CA','Root','TrustedPeople','TrustedPublisher')

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info "Certificate inventory on $c"

      $scr = {
        param($stores)
        $result = @{}

        foreach ($store in $stores) {
          try {
            $items = Get-ChildItem -Path ("cert:\LocalMachine\{0}" -f $store) -ErrorAction Stop |
                     Select-Object Subject, Thumbprint, NotBefore, NotAfter, EnhancedKeyUsageList, HasPrivateKey, FriendlyName
            $result[$store] = $items
          } catch {
            $result[$store] = @()
          }
        }

        # HTTP.SYS bindings (useful for IIS / listeners)
        $sslRaw = & netsh http show sslcert 2>$null

        [pscustomobject]@{
          Stores = $result
          HttpSysSsl = $sslRaw
          Notes = 'cert:\ provider'
        }
      }

      $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList (,$stores)
      # to simple hash
      $h = @{}
      foreach ($k in $stores) { $h[$k] = @($res.Stores[$k] | ConvertTo-Json -Depth 6 | ConvertFrom-Json) }
      $out[$c] = @{
        Stores    = $h
        HttpSys   = "$($res.HttpSysSsl)"
        Notes     = $res.Notes
      }

    } catch {
      Write-Log Error "Certificates collector failed on $c : $($_.Exception.Message)"
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
