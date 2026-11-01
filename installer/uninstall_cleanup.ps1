# Run by the uninstaller: removes only what Agent Lights added to the agents' config files.
$ErrorActionPreference = 'SilentlyContinue'
$home_ = $env:USERPROFILE
$marker = '127.0.0.1:47832/api/hook'
foreach ($f in @("$home_\.claude\settings.json", "$home_\.gemini\config\hooks.json", "$home_\.codex\hooks.json")) {
  if (-not (Test-Path $f)) { continue }
  $j = Get-Content $f -Raw | ConvertFrom-Json
  if ($null -eq $j) { continue }
  if ($j.hooks) {
    foreach ($ev in @($j.hooks.PSObject.Properties.Name)) {
      $rules = @($j.hooks.$ev | ForEach-Object {
        $r = $_
        $kept = @($r.hooks | Where-Object { $_.command -notlike "*$marker*" })
        if ($kept.Count -gt 0) { $r.hooks = $kept; $r }
      })
      if ($rules.Count -gt 0) { $j.hooks.$ev = $rules } else { $j.hooks.PSObject.Properties.Remove($ev) }
    }
  }
  $prev = "$home_\.claude\agent-lights-statusline.prev"
  if ($f -like '*settings.json' -and $j.statusLine.command -like '*agent-lights-statusline*') {
    $old = if (Test-Path $prev) { (Get-Content $prev -Raw).Trim() } else { '' }
    if ($old) { $j.statusLine.command = $old } else { $j.PSObject.Properties.Remove('statusLine') }
  }
  [IO.File]::WriteAllText($f, ($j | ConvertTo-Json -Depth 20))
}
Remove-Item "$home_\.claude\agent-lights-statusline.*" -Force
