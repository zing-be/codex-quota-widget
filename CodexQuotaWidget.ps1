Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$nativeSource = @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

public static class CodexQuotaWidgetNative
{
    [DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hWnd, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int ellipseWidth, int ellipseHeight);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr handle);

    public static void SetRoundedRegion(Control control, int radius)
    {
        if (control.Width < 1 || control.Height < 1) return;
        IntPtr handle = CreateRoundRectRgn(0, 0, control.Width + 1, control.Height + 1, radius * 2, radius * 2);
        Region oldRegion = control.Region;
        control.Region = Region.FromHrgn(handle);
        DeleteObject(handle);
        if (oldRegion != null) oldRegion.Dispose();
    }

    public static void BeginDrag(IntPtr handle)
    {
        ReleaseCapture();
        SendMessage(handle, 0x00A1, new IntPtr(2), IntPtr.Zero);
    }
}

public sealed class CodexQuotaAsyncResult
{
    public string Kind { get; private set; }
    public string Response { get; private set; }
    public string Error { get; private set; }
    public CodexQuotaAsyncResult(string kind, string response, string error)
    {
        Kind = kind;
        Response = response;
        Error = error;
    }
}

public sealed class CodexQuotaWidgetClient : IDisposable
{
    private Process process;
    private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
    private readonly ConcurrentQueue<string> errors = new ConcurrentQueue<string>();
    private readonly ConcurrentQueue<CodexQuotaAsyncResult> completed = new ConcurrentQueue<CodexQuotaAsyncResult>();
    private readonly AutoResetEvent signal = new AutoResetEvent(false);
    private readonly object inputLock = new object();
    private readonly object requestLock = new object();
    private readonly int startupTimeoutMilliseconds;
    private int nextId = 1;
    private int operationActive;
    private volatile bool initialized;
    private volatile bool disposed;

    public CodexQuotaWidgetClient(int timeoutMilliseconds)
    {
        startupTimeoutMilliseconds = timeoutMilliseconds;
    }

    private void EnsureStarted(int timeoutMilliseconds)
    {
        if (disposed) throw new ObjectDisposedException("CodexQuotaWidgetClient");
        if (process != null)
        {
            try { if (!process.HasExited && initialized) return; } catch { }
            try { if (!process.HasExited) process.Kill(); } catch { }
            try { process.Dispose(); } catch { }
            process = null;
            initialized = false;
        }

        string commandProcessor = Environment.GetEnvironmentVariable("ComSpec");
        if (String.IsNullOrEmpty(commandProcessor)) commandProcessor = "cmd.exe";
        ProcessStartInfo startInfo = new ProcessStartInfo(commandProcessor);
        startInfo.Arguments = "/d /s /c \"codex.cmd app-server --stdio\"";
        startInfo.CreateNoWindow = true;
        startInfo.UseShellExecute = false;
        startInfo.RedirectStandardInput = true;
        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;

        process = new Process();
        process.StartInfo = startInfo;
        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args)
        {
            if (args.Data != null) { lines.Enqueue(args.Data); signal.Set(); }
        };
        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args)
        {
            if (!String.IsNullOrWhiteSpace(args.Data)) errors.Enqueue(args.Data);
        };

        try
        {
            if (!process.Start()) throw new InvalidOperationException("Could not start Codex CLI.");
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            Send("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"codex-quota-desktop-widget\",\"version\":\"1.2.0\"},\"capabilities\":{\"experimentalApi\":true}}}");
            string initializeResponse = ReadResponse(1, timeoutMilliseconds);
            if (initializeResponse.IndexOf("\"error\"", StringComparison.Ordinal) >= 0)
                throw new InvalidOperationException("Codex app-server initialization failed.");
            Send("{\"method\":\"initialized\"}");
            initialized = true;
        }
        catch
        {
            try { if (process != null && !process.HasExited) process.Kill(); } catch { }
            try { if (process != null) process.Dispose(); } catch { }
            process = null;
            initialized = false;
            throw;
        }
    }

    private void Send(string message)
    {
        lock (inputLock)
        {
            process.StandardInput.WriteLine(message);
            process.StandardInput.Flush();
        }
    }

    private string ReadResponse(int wantedId, int timeoutMilliseconds)
    {
        Stopwatch watch = Stopwatch.StartNew();
        Regex idPattern = new Regex("\\\"id\\\"\\s*:\\s*" + wantedId + "\\s*[,}]", RegexOptions.Compiled);
        while (watch.ElapsedMilliseconds < timeoutMilliseconds)
        {
            string line;
            while (lines.TryDequeue(out line))
            {
                if (idPattern.IsMatch(line)) return line;
            }
            if (process == null || process.HasExited)
            {
                string detail = String.Join(" ", errors.ToArray());
                int code = process == null ? -1 : process.ExitCode;
                throw new InvalidOperationException("Codex CLI exited with code " + code + (String.IsNullOrWhiteSpace(detail) ? "." : ": " + detail));
            }
            int remaining = timeoutMilliseconds - (int)watch.ElapsedMilliseconds;
            if (remaining > 0) signal.WaitOne(Math.Min(remaining, 500));
        }
        throw new TimeoutException("Codex usage request timed out.");
    }

    private bool StartOperation(string kind, string method, string paramsJson, int timeoutMilliseconds)
    {
        if (disposed) throw new ObjectDisposedException("CodexQuotaWidgetClient");
        if (Interlocked.CompareExchange(ref operationActive, 1, 0) != 0) return false;
        ThreadPool.QueueUserWorkItem(delegate(object ignored)
        {
            try
            {
                string response;
                lock (requestLock)
                {
                    EnsureStarted(startupTimeoutMilliseconds);
                    int id = Interlocked.Increment(ref nextId);
                    Send("{\"id\":" + id + ",\"method\":\"" + method + "\",\"params\":" + paramsJson + "}");
                    response = ReadResponse(id, timeoutMilliseconds);
                }
                completed.Enqueue(new CodexQuotaAsyncResult(kind, response, null));
            }
            catch (Exception exception)
            {
                completed.Enqueue(new CodexQuotaAsyncResult(kind, null, exception.Message));
            }
            finally
            {
                Interlocked.Exchange(ref operationActive, 0);
            }
        });
        return true;
    }

    public bool StartUsageRead(int timeoutMilliseconds)
    {
        return StartOperation("usage", "account/rateLimits/read", "{\"excludeResetCreditDetails\":false}", timeoutMilliseconds);
    }

    public bool StartResetConsume(string idempotencyKey, int timeoutMilliseconds)
    {
        if (String.IsNullOrWhiteSpace(idempotencyKey)) throw new ArgumentException("A reset request key is required.", "idempotencyKey");
        string escapedKey = idempotencyKey.Replace("\\", "\\\\").Replace("\"", "\\\"");
        string paramsJson = "{\"idempotencyKey\":\"" + escapedKey + "\",\"creditId\":null}";
        return StartOperation("reset", "account/rateLimitResetCredit/consume", paramsJson, timeoutMilliseconds);
    }

    public CodexQuotaAsyncResult DequeueResult()
    {
        CodexQuotaAsyncResult result;
        return completed.TryDequeue(out result) ? result : null;
    }

    public void Dispose()
    {
        disposed = true;
        try { if (process != null) process.StandardInput.Close(); } catch { }
        try
        {
            if (process != null && !process.HasExited)
            {
                ProcessStartInfo killInfo = new ProcessStartInfo("taskkill.exe", "/PID " + process.Id + " /T /F");
                killInfo.CreateNoWindow = true;
                killInfo.UseShellExecute = false;
                killInfo.RedirectStandardOutput = true;
                killInfo.RedirectStandardError = true;
                using (Process killer = Process.Start(killInfo)) killer.WaitForExit(2000);
                if (!process.HasExited) process.Kill();
            }
        }
        catch { try { if (process != null && !process.HasExited) process.Kill(); } catch { } }
        try { if (process != null) process.Dispose(); } catch { }
        try { signal.Dispose(); } catch { }
    }
}
"@

$nativeReferences = @(
    [System.Windows.Forms.Form].Assembly.Location,
    [System.Drawing.Region].Assembly.Location,
    [System.Diagnostics.Process].Assembly.Location,
    [System.Collections.Concurrent.ConcurrentQueue[string]].Assembly.Location
) | Select-Object -Unique
Add-Type -TypeDefinition $nativeSource -Language CSharp -ReferencedAssemblies $nativeReferences

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-QuotaWindow {
    param($Window, [string]$FallbackTitle)
    if ($null -eq $Window) { return $null }

    $duration = [int](Get-PropertyValue $Window 'windowDurationMins')
    $usedValue = Get-PropertyValue $Window 'usedPercent'
    if ($null -eq $usedValue) { return $null }
    $remaining = [Math]::Max(0, [Math]::Min(100, 100 - [double]$usedValue))
    $title = $FallbackTitle
    if ($duration -eq 300) {
        $title = '5 小时额度'
    } elseif ($duration -eq 10080) {
        $title = '每周额度'
    } elseif ($duration -gt 0) {
        $title = "$duration 分钟额度"
    }

    $resetText = '重置时间未知'
    $resetValue = Get-PropertyValue $Window 'resetsAt'
    if ($null -ne $resetValue -and [double]$resetValue -gt 0) {
        try {
            $resetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$resetValue).ToLocalTime()
            if ($resetAt.Date -eq [DateTimeOffset]::Now.Date) {
                $resetText = '重置 ' + $resetAt.ToString('HH:mm')
            } else {
                $resetText = '重置 ' + $resetAt.ToString('MM-dd HH:mm')
            }
        } catch { }
    }

    return [pscustomobject]@{
        Title = $title
        Remaining = $remaining
        ResetText = $resetText
    }
}

function Convert-UsageResponse {
    param([string]$Raw)
    $response = $Raw | ConvertFrom-Json
    if ($response.error) {
        $message = Get-PropertyValue $response.error 'message'
        if ($message) { throw [string]$message }
        throw 'Codex 返回了错误响应。'
    }

    $result = Get-PropertyValue $response 'result'
    $limitsById = Get-PropertyValue $result 'rateLimitsByLimitId'
    $limits = Get-PropertyValue $limitsById 'codex'
    if ($null -eq $limits) { $limits = Get-PropertyValue $result 'rateLimits' }
    if ($null -eq $limits) { throw 'Codex 没有返回额度数据。' }

    $primary = Get-QuotaWindow (Get-PropertyValue $limits 'primary') '5 小时额度'
    $secondary = Get-QuotaWindow (Get-PropertyValue $limits 'secondary') '每周额度'
    $resetSummary = Get-PropertyValue $result 'rateLimitResetCredits'
    $resetCount = Get-PropertyValue $resetSummary 'availableCount'
    return [pscustomobject]@{
        Primary = $primary
        Secondary = $secondary
        ResetCreditCount = if ($null -eq $resetCount) { $null } else { [Math]::Max(0, [int]$resetCount) }
    }
}

function New-QuotaCard {
    param([int]$Top, [string]$Title)
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = [System.Drawing.Point]::new(8, $Top)
    $card.Size = [System.Drawing.Size]::new(312, 72)
    $card.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
    [CodexQuotaWidgetNative]::SetRoundedRegion($card, 15)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Location = [System.Drawing.Point]::new(12, 9)
    $titleLabel.Size = [System.Drawing.Size]::new(160, 20)
    $titleLabel.Text = $Title
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(55, 63, 57)
    $titleLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)

    $percentLabel = New-Object System.Windows.Forms.Label
    $percentLabel.Location = [System.Drawing.Point]::new(232, 4)
    $percentLabel.Size = [System.Drawing.Size]::new(68, 39)
    $percentLabel.Text = '--%'
    $percentLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $percentLabel.ForeColor = [System.Drawing.Color]::FromArgb(32, 126, 76)
    $percentLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 22, [System.Drawing.FontStyle]::Bold)

    $resetLabel = New-Object System.Windows.Forms.Label
    $resetLabel.Location = [System.Drawing.Point]::new(12, 35)
    $resetLabel.Size = [System.Drawing.Size]::new(180, 18)
    $resetLabel.Text = '等待额度数据…'
    $resetLabel.ForeColor = [System.Drawing.Color]::FromArgb(112, 121, 114)
    $resetLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 8, [System.Drawing.FontStyle]::Regular)

    $barBack = New-Object System.Windows.Forms.Panel
    $barBack.Location = [System.Drawing.Point]::new(12, 59)
    $barBack.Size = [System.Drawing.Size]::new(288, 4)
    $barBack.BackColor = [System.Drawing.Color]::FromArgb(231, 235, 230)

    $barFill = New-Object System.Windows.Forms.Panel
    $barFill.Location = [System.Drawing.Point]::new(0, 0)
    $barFill.Size = [System.Drawing.Size]::new(0, 4)
    $barFill.BackColor = [System.Drawing.Color]::FromArgb(47, 153, 91)
    $barBack.Controls.Add($barFill)
    [CodexQuotaWidgetNative]::SetRoundedRegion($barBack, 2)

    $card.Controls.AddRange(@($titleLabel, $percentLabel, $resetLabel, $barBack))
    return [pscustomobject]@{
        Panel = $card
        Title = $titleLabel
        Percent = $percentLabel
        Reset = $resetLabel
        BarBack = $barBack
        BarFill = $barFill
    }
}

function Set-QuotaCard {
    param($Card, $Quota)
    if ($null -eq $Quota) {
        $Card.Percent.Text = '--%'
        $Card.Reset.Text = '此额度窗口暂不可用'
        $Card.BarFill.Width = 0
        return
    }

    $Card.Title.Text = $Quota.Title
    $Card.Percent.Text = ('{0:0}%' -f $Quota.Remaining)
    $Card.Reset.Text = $Quota.ResetText
    $Card.BarFill.Width = [Math]::Max(0, [Math]::Min($Card.BarBack.Width, [int][Math]::Round($Card.BarBack.Width * $Quota.Remaining / 100)))

    if ($Quota.Remaining -lt 10) {
        $color = [System.Drawing.Color]::FromArgb(194, 67, 58)
    } elseif ($Quota.Remaining -le 50) {
        $color = [System.Drawing.Color]::FromArgb(168, 112, 24)
    } else {
        $color = [System.Drawing.Color]::FromArgb(32, 126, 76)
    }
    $Card.Percent.ForeColor = $color
    $Card.BarFill.BackColor = $color
    if ($Card.BarFill.Width -ge 4) { [CodexQuotaWidgetNative]::SetRoundedRegion($Card.BarFill, 2) }
}

function Invoke-UsageUpdate {
    if ($script:isRefreshing) { return }
    try {
        if ($null -eq $script:client) { $script:client = [CodexQuotaWidgetClient]::new(10000) }
        if (-not $script:client.StartUsageRead(10000)) { return }
        $script:isRefreshing = $true
        $script:refreshButton.Enabled = $false
        $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(92, 116, 101)
        $script:statusLabel.Text = '正在更新…'
        Update-ResetCreditMenuItem
    } catch {
        $script:isRefreshing = $false
        $script:resetCreditCount = $null
        Update-ResetCreditMenuItem
        $script:refreshButton.Enabled = $true
        $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(194, 67, 58)
        $script:statusLabel.Text = '额度同步失败：将自动重试'
        $script:form.AccessibleDescription = $_.Exception.Message
        $script:toolTip.SetToolTip($script:statusLabel, $_.Exception.Message)
    }
}

function Update-ResetCreditMenuItem {
    if ($null -eq $script:resetCreditMenuItem) { return }
    if ($script:isRefreshing) {
        $script:resetCreditMenuItem.Text = '额度同步中…'
        $script:resetCreditMenuItem.Enabled = $false
    } elseif ($null -ne $script:pendingResetKey) {
        $script:resetCreditMenuItem.Text = '重试上次重置请求（使用同一请求编号）'
        $script:resetCreditMenuItem.Enabled = $true
    } elseif ($null -eq $script:resetCreditCount) {
        $script:resetCreditMenuItem.Text = '重置卡状态暂不可用'
        $script:resetCreditMenuItem.Enabled = $false
    } elseif ($script:resetCreditCount -le 0) {
        $script:resetCreditMenuItem.Text = '使用重置卡（0 张可用）'
        $script:resetCreditMenuItem.Enabled = $false
    } else {
        $script:resetCreditMenuItem.Text = '使用重置卡（' + $script:resetCreditCount + ' 张可用）'
        $script:resetCreditMenuItem.Enabled = $true
    }
}

function Complete-BackgroundOperation {
    if ($null -eq $script:client) { return }
    $finished = $script:client.DequeueResult()
    if ($null -eq $finished) { return }
    $script:isRefreshing = $false
    $script:refreshButton.Enabled = $true

    if (-not [string]::IsNullOrWhiteSpace($finished.Error)) {
        if ($finished.Kind -eq 'reset') {
            $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(194, 67, 58)
            $script:statusLabel.Text = '重置请求结果未确认：右键可安全重试'
            $script:form.AccessibleDescription = $finished.Error
            $script:toolTip.SetToolTip($script:statusLabel, $finished.Error)
            [System.Windows.Forms.MessageBox]::Show(('重置请求未能确认：' + $finished.Error + "`r`n右键重试会复用同一请求编号。"), '重置状态未确认', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } else {
            $script:resetCreditCount = $null
            Update-ResetCreditMenuItem
            $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(194, 67, 58)
            $script:statusLabel.Text = '额度同步失败：将自动重试'
            $script:form.AccessibleDescription = $finished.Error
            $script:toolTip.SetToolTip($script:statusLabel, $finished.Error)
        }
        return
    }

    try {
        $response = $finished.Response | ConvertFrom-Json
        if ($response.error) {
            $message = Get-PropertyValue $response.error 'message'
            if ($message) { throw [string]$message }
            throw 'Codex 返回了错误响应。'
        }

        if ($finished.Kind -eq 'usage') {
            $snapshot = Convert-UsageResponse $finished.Response
            Set-QuotaCard $script:cards[0] $snapshot.Primary
            Set-QuotaCard $script:cards[1] $snapshot.Secondary
            $script:resetCreditCount = $snapshot.ResetCreditCount
            Update-ResetCreditMenuItem
            $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(108, 117, 110)
            $script:statusLabel.Text = '额度已同步  ' + (Get-Date).ToString('HH:mm:ss') + '    ·    每 5 秒刷新'
            $script:toolTip.SetToolTip($script:statusLabel, '额度通过本机 Codex CLI 读取。')
            return
        }

        $result = Get-PropertyValue $response 'result'
        $outcome = [string](Get-PropertyValue $result 'outcome')
        switch ($outcome) {
            'reset' {
                $script:pendingResetKey = $null
                Invoke-UsageUpdate
                $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(32, 126, 76)
                $script:statusLabel.Text = '重置卡已生效，正在同步额度…'
            }
            'alreadyRedeemed' {
                $script:pendingResetKey = $null
                Invoke-UsageUpdate
                $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(32, 126, 76)
                $script:statusLabel.Text = '重置卡已生效，正在同步额度…'
            }
            'noCredit' {
                $script:pendingResetKey = $null
                Invoke-UsageUpdate
                $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(194, 67, 58)
                $script:statusLabel.Text = '没有可用的重置卡'
            }
            'nothingToReset' {
                $script:pendingResetKey = $null
                Invoke-UsageUpdate
                $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(168, 112, 24)
                $script:statusLabel.Text = '当前没有符合重置条件的额度'
            }
            default {
                throw 'Codex 返回了未知的重置结果；右键重试时会复用同一请求编号。'
            }
        }
    } catch {
        $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(194, 67, 58)
        $script:statusLabel.Text = '重置请求结果未确认：右键可安全重试'
        $script:form.AccessibleDescription = $_.Exception.Message
        $script:toolTip.SetToolTip($script:statusLabel, $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(('重置请求未能确认：' + $_.Exception.Message + "`r`n右键重试会复用同一请求编号。"), '重置状态未确认', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    } finally {
        Update-ResetCreditMenuItem
    }
}

function Invoke-ResetCreditUse {
    if ($script:isRefreshing) { return }
    if ($null -eq $script:pendingResetKey -and $null -eq $script:resetCreditCount) {
        Invoke-UsageUpdate
        $script:statusLabel.Text = '正在读取重置卡状态…'
        return
    }
    if ($null -eq $script:pendingResetKey -and $script:resetCreditCount -le 0) {
        [System.Windows.Forms.MessageBox]::Show('当前没有可用的重置卡。', 'Codex 额度小窗', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    if ($null -eq $script:pendingResetKey) {
        $prompt = '确定使用 1 张重置卡吗？这会消耗一张卡，并重置符合条件的 Codex 使用额度。'
    } else {
        $prompt = '上次请求结果未确认。将使用同一请求编号安全重试，避免重复消耗重置卡。是否继续？'
    }
    $answer = [System.Windows.Forms.MessageBox]::Show($prompt, '确认使用重置卡', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    if ($null -eq $script:pendingResetKey) { $script:pendingResetKey = [Guid]::NewGuid().ToString('D') }
    try {
        if ($null -eq $script:client) { $script:client = [CodexQuotaWidgetClient]::new(10000) }
        if (-not $script:client.StartResetConsume($script:pendingResetKey, 15000)) { throw '额度操作正在处理中，请稍后再试。' }
        $script:isRefreshing = $true
        $script:refreshButton.Enabled = $false
        $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(168, 112, 24)
        $script:statusLabel.Text = '正在使用重置卡…'
        Update-ResetCreditMenuItem
    } catch {
        $script:isRefreshing = $false
        $script:refreshButton.Enabled = $true
        $script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(194, 67, 58)
        $script:statusLabel.Text = '重置请求结果未确认：右键可安全重试'
        $script:form.AccessibleDescription = $_.Exception.Message
        $script:toolTip.SetToolTip($script:statusLabel, $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(('重置请求未能确认：' + $_.Exception.Message + "`r`n右键重试会复用同一请求编号。"), '重置状态未确认', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    } finally {
        Update-ResetCreditMenuItem
    }
}

$script:isRefreshing = $false
$script:client = $null
$script:resetCreditCount = $null
$script:resetCreditMenuItem = $null
$script:pendingResetKey = $null
$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = 'Codex 额度概览'
$script:form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$script:form.Size = [System.Drawing.Size]::new(328, 200)
$script:form.BackColor = [System.Drawing.Color]::FromArgb(246, 247, 243)
$script:form.ForeColor = [System.Drawing.Color]::FromArgb(39, 46, 41)
$script:form.TopMost = $true
$script:form.ShowInTaskbar = $false
$script:form.Opacity = 0.90
[CodexQuotaWidgetNative]::SetRoundedRegion($script:form, 18)

$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$script:form.Location = [System.Drawing.Point]::new(($workingArea.Right - $script:form.Width - 24), ($workingArea.Top + 24))

$header = New-Object System.Windows.Forms.Panel
$header.Location = [System.Drawing.Point]::new(0, 0)
$header.Size = [System.Drawing.Size]::new(328, 20)
$header.BackColor = [System.Drawing.Color]::FromArgb(246, 247, 243)

$logo = New-Object System.Windows.Forms.Label
$logo.Location = [System.Drawing.Point]::new(13, 3)
$logo.Size = [System.Drawing.Size]::new(14, 14)
$logo.Text = 'C'
$logo.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$logo.BackColor = [System.Drawing.Color]::Transparent
$logo.ForeColor = [System.Drawing.Color]::FromArgb(31, 119, 70)
$logo.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 8, [System.Drawing.FontStyle]::Bold)

$heading = New-Object System.Windows.Forms.Label
$heading.Location = [System.Drawing.Point]::new(34, 1)
$heading.Size = [System.Drawing.Size]::new(190, 18)
$heading.Text = 'Codex 额度概览'
$heading.ForeColor = [System.Drawing.Color]::FromArgb(36, 43, 38)
$heading.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)

$script:refreshButton = New-Object System.Windows.Forms.Button
$script:refreshButton.Location = [System.Drawing.Point]::new(270, 0)
$script:refreshButton.Size = [System.Drawing.Size]::new(20, 20)
$script:refreshButton.Text = '↻'
$script:refreshButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$script:refreshButton.FlatAppearance.BorderSize = 0
$script:refreshButton.BackColor = [System.Drawing.Color]::FromArgb(232, 239, 232)
$script:refreshButton.ForeColor = [System.Drawing.Color]::FromArgb(31, 119, 70)
$script:refreshButton.Font = [System.Drawing.Font]::new('Segoe UI Symbol', 10, [System.Drawing.FontStyle]::Regular)
$script:refreshButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:refreshButton.Add_Click({ Invoke-UsageUpdate })
[CodexQuotaWidgetNative]::SetRoundedRegion($script:refreshButton, 8)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Location = [System.Drawing.Point]::new(298, 0)
$closeButton.Size = [System.Drawing.Size]::new(20, 20)
$closeButton.Text = '×'
$closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$closeButton.FlatAppearance.BorderSize = 0
$closeButton.BackColor = [System.Drawing.Color]::FromArgb(232, 235, 231)
$closeButton.ForeColor = [System.Drawing.Color]::FromArgb(91, 101, 94)
$closeButton.Font = [System.Drawing.Font]::new('Segoe UI', 12, [System.Drawing.FontStyle]::Regular)
$closeButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$closeButton.Add_Click({ $script:form.Close() })
[CodexQuotaWidgetNative]::SetRoundedRegion($closeButton, 8)

$script:cards = @(
    (New-QuotaCard 21 '5 小时额度'),
    (New-QuotaCard 99 '每周额度')
)

$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.Location = [System.Drawing.Point]::new(13, 178)
$script:statusLabel.Size = [System.Drawing.Size]::new(302, 18)
$script:statusLabel.Text = '正在连接 Codex CLI…'
$script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(108, 117, 110)
$script:statusLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 8, [System.Drawing.FontStyle]::Regular)
$script:toolTip = New-Object System.Windows.Forms.ToolTip

$script:form.Controls.Add($header)
$script:form.Controls.Add($logo)
$script:form.Controls.Add($heading)
$script:form.Controls.Add($script:refreshButton)
$script:form.Controls.Add($closeButton)
$script:form.Controls.Add($script:cards[0].Panel)
$script:form.Controls.Add($script:cards[1].Panel)
$script:form.Controls.Add($script:statusLabel)

$dragHandler = {
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [CodexQuotaWidgetNative]::BeginDrag($script:form.Handle)
    }
}
function Set-WidgetDragHandler {
    param([System.Windows.Forms.Control]$Control)
    if (($Control -ne $script:refreshButton) -and ($Control -ne $closeButton)) {
        $Control.Add_MouseDown($dragHandler)
    }
    foreach ($child in $Control.Controls) { Set-WidgetDragHandler $child }
}
Set-WidgetDragHandler $script:form

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$refreshMenuItem = $contextMenu.Items.Add('立即刷新')
$refreshMenuItem.Add_Click({ Invoke-UsageUpdate })
$script:resetCreditMenuItem = $contextMenu.Items.Add('重置卡状态读取中…')
$script:resetCreditMenuItem.Enabled = $false
$script:resetCreditMenuItem.Add_Click({ Invoke-ResetCreditUse })
$contextMenu.Add_Opening({ Update-ResetCreditMenuItem })
$topMostMenuItem = $contextMenu.Items.Add('置顶显示')
$topMostMenuItem.Checked = $true
$topMostMenuItem.Add_Click({
    $script:form.TopMost = -not $script:form.TopMost
    $topMostMenuItem.Checked = $script:form.TopMost
})
$contextMenu.Items.Add('-') | Out-Null
$exitMenuItem = $contextMenu.Items.Add('退出')
$exitMenuItem.Add_Click({ $script:form.Close() })
$script:form.ContextMenuStrip = $contextMenu
function Set-WidgetContextMenu {
    param([System.Windows.Forms.Control]$Control, [System.Windows.Forms.ContextMenuStrip]$Menu)
    $Control.ContextMenuStrip = $Menu
    foreach ($child in $Control.Controls) { Set-WidgetContextMenu $child $Menu }
}
Set-WidgetContextMenu $script:form $contextMenu

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 5000
$script:timer.Add_Tick({ Invoke-UsageUpdate })
$script:timer.Start()
$script:completionTimer = New-Object System.Windows.Forms.Timer
$script:completionTimer.Interval = 100
$script:completionTimer.Add_Tick({ Complete-BackgroundOperation })
$script:completionTimer.Start()
$script:form.Add_Shown({ Invoke-UsageUpdate })
$script:form.Add_FormClosed({
    $script:timer.Stop()
    $script:timer.Dispose()
    $script:completionTimer.Stop()
    $script:completionTimer.Dispose()
    $script:toolTip.Dispose()
    if ($null -ne $script:client) { $script:client.Dispose() }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($script:form)

