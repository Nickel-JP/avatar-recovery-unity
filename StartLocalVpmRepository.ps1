param(
    [int]$Port = 8765
)

$ErrorActionPreference = "Stop"

$python = Get-Command python -ErrorAction Stop
$arguments = "-m http.server $Port --bind 127.0.0.1 --directory `"$PSScriptRoot`""

$process = Start-Process `
    -FilePath $python.Source `
    -ArgumentList $arguments `
    -WindowStyle Hidden `
    -PassThru

Start-Sleep -Seconds 1

Write-Host "Started Avatar Recovery VPM repository server."
Write-Host "Process ID: $($process.Id)"
Write-Host "Repository URL: http://127.0.0.1:$Port/index.json"
