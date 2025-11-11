@{
  RootModule        = 'ServerAuditToolkitV2.psm1'
  ModuleVersion     = '0.1.0'
  GUID              = 'b3ae2b02-3a86-4b5f-9e5b-1c8ee4c4f1ab'
  Author            = 'tony.nash@intecbusiness.co.uk'
  CompatiblePSEditions = @('Desktop') # PS 4/5.1
  PowerShellVersion = '4.0'
  FunctionsToExport = @(
    'Invoke-ServerAudit',
    'Get-SATSystem','Get-SATRolesFeatures','Get-SATNetwork','Get-SATStorage',
    'Get-SATADDS','Get-SATDNS','Get-SATDHCP','Get-SATIIS','Get-SATPrinters','Get-SATHyperV',
    'Get-SATCertificates','Get-SATScheduledTasks','Get-SATLocalAccounts'
  )
  PrivateData = @{
    PSData = @{
      Tags = @('Windows','Audit','Migration','Server')
      LicenseUri = 'https://opensource.org/licenses/MIT'
    }
  }
}
