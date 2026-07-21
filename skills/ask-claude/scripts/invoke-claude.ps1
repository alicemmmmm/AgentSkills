[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('ask', 'review', 'debate', 'execute')]
    [string]$Branch,
    [Parameter(Mandatory = $true)]
    [string]$Prompt,
    [string]$Topic = '',
    [string]$ResumeSessionId = '',
    [string]$Model = '',
    [int]$Round = 1,
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$IndexPath = ''
)

$ErrorActionPreference = 'Stop'

function ConvertFrom-ClaudeJson {
    param([object[]]$OutputLines)
    $text = ($OutputLines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Claude CLI returned no output.' }
    try { return $text | ConvertFrom-Json -ErrorAction Stop } catch {}
    # Claude CLI on Windows may hard-wrap its one-line JSON at the console width,
    # including inside property names. JSON string newlines are escaped, so removing
    # physical line breaks restores the original machine-readable payload.
    $compactedText = $text -replace '[\r\n]+', ''
    try { return $compactedText | ConvertFrom-Json -ErrorAction Stop } catch { $compactError = $_.Exception.Message }
    # Windows PowerShell 5.1 treats JSON keys case-insensitively. Claude usage
    # metadata can contain model names that differ only by case, so parse only
    # the two fields this wrapper requires when full-object parsing fails.
    $resultMatch = [regex]::Match($compactedText, '"result":(?<value>"(?:\\.|[^"\\])*")')
    $sessionMatch = [regex]::Match($compactedText, '"session_id":(?<value>"(?:\\.|[^"\\])*")')
    if ($resultMatch.Success -and $sessionMatch.Success) {
        $resultValue = ('{"value":' + $resultMatch.Groups['value'].Value + '}') | ConvertFrom-Json -ErrorAction Stop
        $sessionValue = ('{"value":' + $sessionMatch.Groups['value'].Value + '}') | ConvertFrom-Json -ErrorAction Stop
        return [pscustomobject]@{ result = $resultValue.value; session_id = $sessionValue.value }
    }
    foreach ($line in [Linq.Enumerable]::Reverse([string[]]($text -split "`r?`n"))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { return $line | ConvertFrom-Json -ErrorAction Stop } catch {}
    }
    throw "Claude CLI did not return valid JSON. Parse error: $compactError Output: $($text.Substring(0, [Math]::Min(500, $text.Length)))"
}

$claudeArgs = @('-p', '--output-format', 'json')
if ($Branch -eq 'execute') { $claudeArgs += @('--permission-mode', 'bypassPermissions') }
elseif ($Branch -ne 'ask') { $claudeArgs += @('--permission-mode', 'default') }
if ($ResumeSessionId) { $claudeArgs += @('--resume', $ResumeSessionId) }
if ($Model) { $claudeArgs += @('--model', $Model) }

$claudeCommand = Get-Command claude -ErrorAction Stop
$claudeExecutable = $claudeCommand.Source
if ($claudeExecutable.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
    $candidate = Join-Path (Split-Path -Parent $claudeExecutable) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
    if (-not (Test-Path -LiteralPath $candidate)) { throw "Cannot resolve Claude executable from $claudeExecutable" }
    $claudeExecutable = $candidate
}

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $claudeExecutable
$startInfo.Arguments = ($claudeArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.CreateNoWindow = $true
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
[void]$process.Start()
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$process.StandardInput.Write($Prompt)
$process.StandardInput.Close()
$process.WaitForExit()
$exitCode = $process.ExitCode
$rawOutputText = $stdoutTask.Result.Trim()
$errorText = $stderrTask.Result.Trim()
$rawOutput = @($rawOutputText)
if ($exitCode -ne 0) {
    throw "Claude CLI failed with exit code $exitCode. Output: $errorText"
}

$response = ConvertFrom-ClaudeJson $rawOutput
$sessionId = [string]$response.session_id
$resultText = [string]$response.result
if ([string]::IsNullOrWhiteSpace($resultText)) { throw 'Claude CLI JSON did not contain a non-empty result.' }
if ($Branch -eq 'debate' -and [string]::IsNullOrWhiteSpace($sessionId)) {
    throw 'Claude debate call returned no session_id; do not continue it as the same debate.'
}

if (-not $IndexPath) {
    $IndexPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.state\sessions.jsonl'
}
$now = [DateTimeOffset]::Now.ToString('o')
$normalizedPrompt = ($Prompt -replace '\s+', ' ').Trim()
$normalizedResult = ($resultText -replace '\s+', ' ').Trim()
$record = [ordered]@{
    session_id = $sessionId; parent_session_id = $(if ($ResumeSessionId) { $ResumeSessionId } else { $null })
    branch = $Branch; topic = $Topic; cwd = $WorkingDirectory; created_at = $now; last_used_at = $now
    status = 'active'; round = $Round; resumed = [bool]$ResumeSessionId
    prompt_preview = $normalizedPrompt.Substring(0, [Math]::Min(80, $normalizedPrompt.Length))
    summary = $normalizedResult.Substring(0, [Math]::Min(200, $normalizedResult.Length))
}

$indexRecorded = $false
$indexError = $null
if ($sessionId) {
    try {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $IndexPath)) | Out-Null
        [IO.File]::AppendAllText($IndexPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $indexRecorded = $true
    } catch {
        $indexError = $_.Exception.Message
        $fallbackPath = Join-Path $WorkingDirectory '.ask-claude\sessions.jsonl'
        try {
            [IO.Directory]::CreateDirectory((Split-Path -Parent $fallbackPath)) | Out-Null
            [IO.File]::AppendAllText($fallbackPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $IndexPath = $fallbackPath; $indexRecorded = $true; $indexError = $null
        } catch { $indexError = "$indexError; fallback failed: $($_.Exception.Message)" }
    }
}

[ordered]@{
    result = $resultText; session_id = $sessionId; branch = $Branch; round = $Round
    resumed = [bool]$ResumeSessionId; index_recorded = $indexRecorded
    index_path = $IndexPath; index_error = $indexError
} | ConvertTo-Json -Depth 5
