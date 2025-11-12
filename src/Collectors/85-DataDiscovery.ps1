function Get-SATDataDiscovery {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Data discovery on {0}" -f $c)

      $scr = {
        $result = @{
          Shares    = @()   # per-share summary
          Folders   = @()   # per-share top-level folders
          FileTypes = @()   # per-share extension rollup
          Notes     = ''
          Error     = $null
        }

        # enumerate shares (module -> WMI)
        $shares = @()
        $used = 'none'
        try {
          if (Get-Command Get-SmbShare -ErrorAction SilentlyContinue) {
            $tmp = Get-SmbShare -ErrorAction SilentlyContinue | Where-Object {
              $_.ShareType -eq 0 -and $_.Name -notmatch '^\w\$$'
            }
            foreach ($s in $tmp) {
              $shares += New-Object PSObject -Property @{ Name=$s.Name; Path=$s.Path }
            }
            if ($shares.Count -gt 0) { $used = 'Get-SmbShare' }
          }
        } catch {}

        if ($shares.Count -eq 0) {
          try {
            $tmp = Get-WmiObject -Class Win32_Share -Filter "Type=0" -ErrorAction SilentlyContinue | Where-Object {
              $_.Name -notmatch '^\w\$$'
            }
            foreach ($s in $tmp) {
              $shares += New-Object PSObject -Property @{ Name=$s.Name; Path=$s.Path }
            }
            if ($shares.Count -gt 0 -and $used -eq 'none') { $used = 'WMI' }
          } catch {}
        }

        if ($shares.Count -eq 0) {
          $result.Notes = 'No data shares found'
          return $result
        }

        # helper: classify share by name/path
        function Get-Category([string]$name,[string]$path,[double]$binPct,[double]$officePct) {
          $n = ($name  -as [string]); if (-not $n) { $n = '' }
          $p = ($path  -as [string]); if (-not $p) { $p = '' }
          $np = ($n + ' ' + $p).ToLower()

          if ($np -match 'profile|roaming|users|redirected|home(dir)?s?|upd') { return 'Profiles' }
          if ($np -match 'software|install|setup|packages|apps|deployment|sccm|pdq') {
            if ($binPct -ge 10) { return 'SoftwareDist' }
          }
          if ($binPct -ge 15 -and $officePct -lt 10) { return 'LOBBinaries' }
          if ($officePct -ge 20) { return 'Documents' }
          return 'General'
        }

        # Scan config (keep PS2/.NET 3.5 safe)
        $maxFilesPerShare = 200000
        $topFoldersMax    = 50
        $topExtMax        = 50

        foreach ($sh in $shares) {
          $path = $sh.Path
          if (-not $path -or -not (Test-Path $path)) {
            $result.Shares += New-Object PSObject -Property @{
              Server=$env:COMPUTERNAME; Share=$sh.Name; Path=$path; Category='Unavailable'
              TotalFiles=0; TotalBytes=0; HotPct=0; WarmPct=0; ColdPct=0; FrozenPct=0; Oldest=$null; Newest=$null
              BinaryPct=0; OfficePct=0; Sampled=$false; Notes="Path missing or inaccessible"; Source=$used
            }
            continue
          }

          $now = Get-Date
          $totalFiles = 0L; $totalBytes = 0L
          $hot=0L; $warm=0L; $cold=0L; $frozen=0L
          $oldest = [datetime]::MaxValue
          $newest = [datetime]::MinValue
          $extAgg = @{}             # ext -> @{Count;Bytes}
          $subAgg = @{}             # top folder -> @{Count;Bytes;Hot;Warm;Cold;Frozen}
          $binCount = 0L; $officeCount = 0L
          $sampled = $false

          $binExts = @('.exe','.dll','.msi','.bat','.cmd','.ps1','.vbs','.js','.jar','.com')
          $docExts = @('.doc','.docx','.xls','.xlsx','.ppt','.pptx','.pdf','.rtf','.txt','.csv','.vsd','.vsdx')

          # enumerate files safely
          try {
            $enum = [System.IO.Directory]::EnumerateFiles($path,'*',[System.IO.SearchOption]::AllDirectories)
          } catch {
            $enum = @()
          }

          foreach ($fp in $enum) {
            if ($totalFiles -ge $maxFilesPerShare) { $sampled = $true; break }
            try {
              $fi = New-Object System.IO.FileInfo($fp)
            } catch { continue }

            $totalFiles++
            $len = 0L; try { $len = $fi.Length } catch {}
            $totalBytes += $len

            $lw = $null; try { $lw = $fi.LastWriteTime } catch {}
            if ($lw) {
              if ($lw -gt $newest) { $newest = $lw }
              if ($lw -lt $oldest) { $oldest = $lw }
              $age = ($now - $lw).Days
              if ($age -le 30) { $hot++ }
              elseif ($age -le 180) { $warm++ }
              elseif ($age -le 365) { $cold++ }
              else { $frozen++ }
            }

            $ext = $null; try { $ext = $fi.Extension } catch {}
            if (-not $ext) { $ext = '(none)' } else { $ext = $ext.ToLower() }

            if (-not $extAgg.ContainsKey($ext)) { $extAgg[$ext] = @{Count=0L;Bytes=0L} }
            $e = $extAgg[$ext]; $e.Count = $e.Count + 1L; $e.Bytes = $e.Bytes + $len; $extAgg[$ext] = $e

            if ($binExts -contains $ext) { $binCount++ }
            if ($docExts -contains $ext) { $officeCount++ }

            # Top-level folder rollup
            $rel = $null
            try {
              $rel = $fi.FullName.Substring($path.Length).TrimStart('\','/')
            } catch {}
            $tf = '(root)'
            if ($rel) {
              $parts = $rel -split '[\\/]',2
              if ($parts.Length -gt 0 -and $parts[0] -ne '') { $tf = $parts[0] }
            }
            if (-not $subAgg.ContainsKey($tf)) { $subAgg[$tf] = @{Count=0L;Bytes=0L;Hot=0L;Warm=0L;Cold=0L;Frozen=0L} }
            $s = $subAgg[$tf]; $s.Count++; $s.Bytes+=$len
            if ($lw) {
              $age2 = ($now - $lw).Days
              if ($age2 -le 30) { $s.Hot++ }
              elseif ($age2 -le 180) { $s.Warm++ }
              elseif ($age2 -le 365) { $s.Cold++ }
              else { $s.Frozen++ }
            }
            $subAgg[$tf] = $s
          } # foreach file

          # percentages
          $den = [math]::Max(1, [double]$totalFiles)
          $hotPct    = [math]::Round(($hot    *100.0)/$den,1)
          $warmPct   = [math]::Round(($warm   *100.0)/$den,1)
          $coldPct   = [math]::Round(($cold   *100.0)/$den,1)
          $frozenPct = [math]::Round(($frozen *100.0)/$den,1)
          $binPct    = [math]::Round(($binCount    *100.0)/$den,1)
          $officePct = [math]::Round(($officeCount *100.0)/$den,1)

          $cat = Get-Category $sh.Name $path $binPct $officePct

          $result.Shares += New-Object PSObject -Property @{
            Server     = $env:COMPUTERNAME
            Share      = $sh.Name
            Path       = $path
            Category   = $cat
            TotalFiles = [int64]$totalFiles
            TotalBytes = [int64]$totalBytes
            HotPct     = $hotPct
            WarmPct    = $warmPct
            ColdPct    = $coldPct
            FrozenPct  = $frozenPct
            Oldest     = (if ($oldest -eq [datetime]::MaxValue) { $null } else { $oldest })
            Newest     = (if ($newest -eq [datetime]::MinValue) { $null } else { $newest })
            BinaryPct  = $binPct
            OfficePct  = $officePct
            Sampled    = $sampled
            Source     = $used
          }

          # materialize top folders
          $subs = @()
          foreach ($k in $subAgg.Keys) {
            $val = $subAgg[$k]
            $subs += New-Object PSObject -Property @{
              Server=$env:COMPUTERNAME; Share=$sh.Name; Folder=$k
              Files=[int64]$val.Count; Bytes=[int64]$val.Bytes
              HotPct=[math]::Round(($val.Hot*100.0)/[math]::Max(1,[double]$val.Count),1)
              WarmPct=[math]::Round(($val.Warm*100.0)/[math]::Max(1,[double]$val.Count),1)
              ColdPct=[math]::Round(($val.Cold*100.0)/[math]::Max(1,[double]$val.Count),1)
              FrozenPct=[math]::Round(($val.Frozen*100.0)/[math]::Max(1,[double]$val.Count),1)
            }
          }
          $result.Folders += @($subs | Sort-Object Bytes -Descending | Select-Object -First $topFoldersMax)

          # materialize top filetypes
          $types = @()
          foreach ($k in $extAgg.Keys) {
            $v = $extAgg[$k]
            $types += New-Object PSObject -Property @{
              Server=$env:COMPUTERNAME; Share=$sh.Name; Ext=$k
              Files=[int64]$v.Count; Bytes=[int64]$v.Bytes
            }
          }
          $result.FileTypes += @($types | Sort-Object Bytes -Descending | Select-Object -First $topExtMax)
        } # foreach share

        return $result
      } # scriptblock

      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } catch {
      Write-Log Error ("Data discovery collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Shares=@(); Folders=@(); FileTypes=@(); Error=$_.Exception.Message; Notes='collector exception' }
    }
  }
  return $out
}
