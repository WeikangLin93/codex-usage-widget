$procs = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*codex_usage_widget.ps1*' }
if ($procs) {
  foreach ($p in $procs) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Output ("KILLED " + $p.ProcessId)
  }
} else {
  Write-Output 'NONE'
}
