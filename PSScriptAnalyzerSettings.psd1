@{
  Severity = @('Error','Warning')
  ExcludeRules = @(
    'PSAvoidUsingWriteHost' # we use Write-Verbose/Write-Log; keep host minimal
  )
}
