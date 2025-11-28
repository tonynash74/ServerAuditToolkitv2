# Collector Variant Layout

Collectors are now organized into explicit PowerShell compatibility bands:

- `PS2x` – baseline implementations that run on PowerShell 2.0/4.0.
- `PS4x` – placeholder for PS 4.x optimized variants (falls back to PS2x today).
- `PS5x` – optimized implementations that rely on PowerShell 5.x APIs (CIM, etc.).
- `PS7x` – reserved for PS 7.x specific enhancements (currently reuses PS5x until dedicated scripts are authored).

When you add or update a collector:

1. Place the script in the appropriate folder for the minimum PowerShell version it targets.
2. Update `collector-metadata.json` so each `variants` block points to the correct relative path (e.g. `PS2x\\Get-Services.ps1`).
3. Re-run `scripts\check-missing-variants.ps1` to ensure every declared variant exists on disk.
4. Keep the function names the same across variants so orchestration code can swap implementations transparently.

> Tip: If a higher PS version should reuse a lower version implementation until a custom script exists, point its entry in `variants` to the lower version file so fallback behavior stays explicit.
