function Get-SATCertificates {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $stores = @('My','WebHosting','CA','Root','TrustedPeople','TrustedPublisher')
  $out = @{}

  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Certificate inventory on {0}" -f $c)
      $scr = {
        param($stores)
        $result = @{}
        foreach ($store in $stores) {
          try {
            $items = Get-ChildItem -Path ("cert:\LocalMachine\{0}" -f $store) -ErrorAction SilentlyContinue |
                     Select-Object Subject, Thumbprint, NotBefore, NotAfter, EnhancedKeyUsageList, HasPrivateKey, FriendlyName
            $result[$store] = $items
          } catch { $result[$store] = @() }
        }
        $sslRaw = (& netsh http show sslcert 2>$null)
        $res = @{}
        $res["Stores"] = $result
        $res["HttpSysSsl"] = "$sslRaw"
        $res["Notes"] = 'cert:\ provider'
        return $res
      }
      $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList (,$stores)
      $out[$c] = @{ Stores=$res.Stores; HttpSys=$res.HttpSysSsl; Notes=$res.Notes }
    } catch {
      Write-Log Error ("Certificates collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}

