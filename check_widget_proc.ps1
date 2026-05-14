$procs = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*codex_usage_widget.ps1*' }
if ($procs) {
  $procs | Select-Object ProcessId, Name, CommandLine | ConvertTo-Json -Depth 3
} else {
  'NONE'
}
