@{
  ModuleToProcess   = 'ServerAuditToolkitV2.psm1' 
  ModuleVersion     = '0.2.0'
  GUID              = 'b3ae2b02-3a86-4b5f-9e5b-1c8ee4c4f1ab'
  Author            = 'tonynash74'
  CompanyName       = ''
  PowerShellVersion = '2.0'
  FunctionsToExport = '*'
  AliasesToExport   = @()
  CmdletsToExport   = @()
  Description       = 'Server audit + migration-readiness toolkit (PS2+ compatible)'

  FunctionsToExport = @(
    'Invoke-ServerAudit',
    'Get-SATSystem','Get-SATRolesFeatures','Get-SATNetwork','Get-SATStorage',
    'Get-SATADDS','Get-SATDNS','Get-SATDHCP','Get-SATIIS','Get-SATHyperV',
    'Get-SATSMB','Get-SATPrinters','Get-SATCertificates','Get-SATScheduledTasks','Get-SATLocalAccounts'
  )

  PrivateData = @{
    PSData = @{
      Tags       = @('Windows','Audit','Migration','Server')
      LicenseUri = 'https://opensource.org/licenses/MIT'
      ProjectUri = 'https://github.com/tonynash74/ServerAuditToolkitv2'
    }
  }
}
