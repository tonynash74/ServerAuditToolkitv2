# src/Collectors/50-DHCP.ps1
function Get-SATDHCP {
  [CmdletBinding()] param([string[]]$ComputerName,[hashtable]$Capability)

  $out=@{}
  foreach($c in $ComputerName){
    Write-Log Info "DHCP config on $c"
    if($Capability.HasDhcpModule){
      $scr = {
        @{
          Server   = (Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Measure).Count
          Scopes   = Get-DhcpServerv4Scope | Select ScopeId, Name, State, StartRange, EndRange, SubnetMask
          Options  = Get-DhcpServerv4OptionValue -All | Select OptionId, Name, Value, ScopeId
          Leases   = (Get-DhcpServerv4Lease -AllLeases -ErrorAction SilentlyContinue | Measure).Count
        }
      }
      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } else {
      $tmp = "\\$c\ADMIN$\Temp\sat-dhcp-export.xml"
      Invoke-Command -ComputerName $c -ScriptBlock { param($p) mkdir (Split-Path $p) -ea 0 | Out-Null; netsh dhcp server export $p all } -ArgumentList $tmp
      $raw = Invoke-Command -ComputerName $c -ScriptBlock { param($p) Get-Content $p -Raw } -ArgumentList $tmp
      $out[$c] = @{ Export = ($raw.Substring(0,[Math]::Min($raw.Length,2000))); Notes='netsh export sample captured' }
    }
  }
  return $out
}
