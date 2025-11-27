Set-Location $PSScriptRoot\..\

$files = @(
  'T5-PHASE-2-PLAN.md','T5-README.md','T5-PROJECT-COMPLETION-SUMMARY.md','T5-PR-SUBMISSION-READY.md','T5-PHASE-3-COMPLETION.md','T5-PHASE-2-QUICK-REFERENCE.md','T5-PHASE-2-COMPLETION.md','T5-PHASE-1-PR-SUBMISSION.md','T5-PHASE-1-PR-QUICK-GUIDE.md','T5-PHASE-1-COMPLETION.md','T5-PHASE-1-COMPLETION-CERTIFICATE.md','T5-COMPLETE-PROJECT-SUMMARY.md','T5-ARCHITECTURE-OVERVIEW.md','T4-QUICK-START.md','T4-PHASE-KICKOFF-SUMMARY.md','T4-MIGRATION-DECISIONS-ENGINE.md','T4-LAUNCH-SUMMARY.md','T1-Implementation.md','SPRINT-4-M011-QUICK-REFERENCE.md','SPRINT-3-QUICK-REFERENCE.md','SPRINT-2-COMPLETION-REPORT.md','SPRINT-1-COMPLETION-REPORT.md','PHASE-3-PROJECT-PLAN.md','PHASE-3-PROGRESS-SUMMARY.md','PHASE-3-FINAL-COMPLETION.md','PHASE-3-COMPLETION-SUMMARY.md','PHASE-2-QUICK-START.md','PHASE-2-LAUNCH-SUMMARY.md','PHASE-2-EXECUTION-PLAN.md'
)

$moved = @()
foreach ($f in $files) {
    $src = Join-Path -Path (Get-Location) -ChildPath $f
    $dest = Join-Path -Path (Get-Location) -ChildPath (Join-Path 'docs' $f)
    if (Test-Path -LiteralPath $dest) {
        if (Test-Path -LiteralPath $src) {
            Write-Host "Removing root copy (docs already has it): $f"
            git -C . rm -- "$f"
            $moved += "Removed: $f"
        } else {
            Write-Host "No root copy to remove: $f"
        }
    } elseif (Test-Path -LiteralPath $src) {
        Write-Host "Moving: $f -> docs/$f"
        git -C . mv -- "$f" "docs/$f"
        $moved += "Moved: $f"
    } else {
        Write-Host "Missing (no action): $f"
    }
}

Write-Host "\nGit status (porcelain):"
git -C . status --porcelain

Write-Host "\nSummary of actions:"
$moved | ForEach-Object { Write-Host " - $_" }
