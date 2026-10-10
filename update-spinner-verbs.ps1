# Runs a headless Claude Code session, pulls NO_OF_STRINGS strings from its
# output and installs them as the global spinner verbs in settings.json.
# Every attempt is audited in log.csv; pulled strings are kept in strings.csv.
# Compatible with Windows PowerShell 5.1.
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$config = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json
$configDir = Split-Path -Parent (Resolve-Path $ConfigPath)

function Resolve-ConfigPath([string]$path) {
    $expanded = [Environment]::ExpandEnvironmentVariables($path)
    if ([IO.Path]::IsPathRooted($expanded)) { return $expanded }
    return [IO.Path]::GetFullPath((Join-Path $configDir $expanded))
}

$noOfStrings = [int]$config.NO_OF_STRINGS
$maxRetries = [int]$config.MAX_RETRIES
$retryDelay = [int]$config.RETRY_DELAY_SECONDS
$timeoutSec = [int]$config.CLAUDE_TIMEOUT_SECONDS
$settingsPath = Resolve-ConfigPath $config.SETTINGS_PATH
$promptFile = Resolve-ConfigPath $config.PROMPT_FILE
$dataDir = Resolve-ConfigPath $config.DATA_DIR
$logCsv = Join-Path $dataDir 'log.csv'
$stringsCsv = Join-Path $dataDir 'strings.csv'
$runLog = Join-Path $dataDir 'run.log'

if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Force $dataDir | Out-Null }

function Write-RunLog([string]$message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
    Add-Content -Path $runLog -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-NextRunNo {
    if (-not (Test-Path $logCsv)) { return 1 }
    $max = 0
    foreach ($row in (Import-Csv $logCsv)) {
        if ([int]$row.Run_no -gt $max) { $max = [int]$row.Run_no }
    }
    return $max + 1
}

function Add-LogRow([int]$runNo, [datetime]$when, [bool]$status) {
    [pscustomobject]@{
        Run_no       = $runNo
        Run_datetime = $when.ToString('yyyy-MM-dd HH:mm:ss')
        Status       = $status.ToString().ToLower()
    } | Export-Csv -Path $logCsv -Append -NoTypeInformation -Encoding UTF8
}

function Add-StringRows([int]$runNo, [string[]]$strings) {
    $rows = for ($i = 0; $i -lt $strings.Count; $i++) {
        [pscustomobject]@{
            Run_no      = $runNo
            String_no   = $i + 1
            String_text = $strings[$i]
        }
    }
    $rows | Export-Csv -Path $stringsCsv -Append -NoTypeInformation -Encoding UTF8
}

function Invoke-ClaudeHeadless([string]$prompt) {
    $claude = (Get-Command claude -ErrorAction Stop).Source
    $arguments = '-p --output-format json --tools "" --strict-mcp-config --no-session-persistence'
    if ($config.MODEL) { $arguments += ' --model "{0}"' -f $config.MODEL }
    if ($config.EFFORT) { $arguments += ' --effort "{0}"' -f $config.EFFORT }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claude
    $psi.Arguments = $arguments
    $psi.WorkingDirectory = $configDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        # The prompt goes over stdin as raw UTF-8 so no shell quoting applies to it.
        $bytes = $Utf8NoBom.GetBytes($prompt)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.Close()

        if (-not $proc.WaitForExit($timeoutSec * 1000)) {
            $proc.Kill()
            throw "claude timed out after $timeoutSec s"
        }
        $proc.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($proc.ExitCode -ne 0) {
            throw "claude exited with code $($proc.ExitCode): $stderr $stdout"
        }
    } finally {
        $proc.Dispose()
    }

    $response = $stdout | ConvertFrom-Json
    if ($response.is_error) { throw "claude returned an error: $($response.result)" }
    return [string]$response.result
}

function ConvertTo-StringList([string]$text) {
    $match = [regex]::Match($text, '\[[\s\S]*\]')
    if ($match.Success) {
        try {
            $parsed = $match.Value | ConvertFrom-Json
            return @(foreach ($item in $parsed) { ([string]$item).Trim() })
        } catch { }
    }
    # Fallback: one string per line, minus code fences, bullets and numbering.
    return @(foreach ($line in ($text -split "`r?`n")) {
        $clean = $line.Trim()
        if (-not $clean -or $clean.StartsWith('```')) { continue }
        $clean = $clean -replace '^(\d+[.)]|[-*•])\s+', ''
        $clean.Trim().Trim('"', "'", ',').Trim()
    })
}

function ConvertTo-JsonString([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        switch ($ch) {
            '"' { [void]$sb.Append('\"'); break }
            '\' { [void]$sb.Append('\\'); break }
            "`n" { [void]$sb.Append('\n'); break }
            "`r" { [void]$sb.Append('\r'); break }
            "`t" { [void]$sb.Append('\t'); break }
            default {
                if ([int]$ch -lt 0x20) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# ConvertTo-Json in PowerShell 5.1 mangles indentation and escapes plain
# characters, so settings.json is serialised by hand to keep it readable.
function ConvertTo-PrettyJson($value, [int]$level = 0) {
    $pad = '  ' * $level
    $inner = '  ' * ($level + 1)
    if ($null -eq $value) { return 'null' }
    if ($value -is [bool]) { return $value.ToString().ToLower() }
    if ($value -is [string]) { return ConvertTo-JsonString $value }
    if ($value -is [System.Management.Automation.PSCustomObject]) {
        $props = @($value.PSObject.Properties)
        if ($props.Count -eq 0) { return '{}' }
        $parts = foreach ($p in $props) {
            '{0}{1}: {2}' -f $inner, (ConvertTo-JsonString $p.Name), (ConvertTo-PrettyJson $p.Value ($level + 1))
        }
        return "{`n" + ($parts -join ",`n") + "`n$pad}"
    }
    if ($value -is [System.Collections.IEnumerable]) {
        $items = @($value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($item in $items) { $inner + (ConvertTo-PrettyJson $item ($level + 1)) }
        return "[`n" + ($parts -join ",`n") + "`n$pad]"
    }
    return ([System.IConvertible]$value).ToString([cultureinfo]::InvariantCulture)
}

function Set-SpinnerVerbs([string[]]$verbs) {
    if (Test-Path $settingsPath) {
        $settings = Get-Content -Raw -Encoding UTF8 $settingsPath | ConvertFrom-Json
    } else {
        $settings = [pscustomobject]@{}
    }
    $spinnerVerbs = [pscustomobject]@{ mode = 'replace'; verbs = $verbs }
    if ($settings.PSObject.Properties['spinnerVerbs']) {
        $settings.spinnerVerbs = $spinnerVerbs
    } else {
        $settings | Add-Member -NotePropertyName spinnerVerbs -NotePropertyValue $spinnerVerbs
    }

    $json = (ConvertTo-PrettyJson $settings) + "`n"
    $tmp = "$settingsPath.tmp"
    [IO.File]::WriteAllText($tmp, $json, $Utf8NoBom)
    if (Test-Path $settingsPath) {
        # Atomic swap; the previous file is kept as settings.json.bak.
        [IO.File]::Replace($tmp, $settingsPath, "$settingsPath.bak")
    } else {
        [IO.File]::Move($tmp, $settingsPath)
    }
}

$prompt = (Get-Content -Raw -Encoding UTF8 $promptFile).Replace('{NO_OF_STRINGS}', "$noOfStrings").Trim()

$succeeded = $false
for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
    if ($attempt -gt 0) {
        Write-RunLog "Retry $attempt/$maxRetries in $retryDelay s"
        Start-Sleep -Seconds $retryDelay
    }
    $runNo = Get-NextRunNo
    $startedAt = Get-Date
    try {
        $strings = ConvertTo-StringList (Invoke-ClaudeHeadless $prompt)
        if ($strings.Count -ne $noOfStrings) {
            throw "expected $noOfStrings strings, got $($strings.Count)"
        }
        if (@($strings | Where-Object { -not $_ }).Count -gt 0) {
            throw 'output contains empty strings'
        }
        Set-SpinnerVerbs $strings
        Add-StringRows $runNo $strings
        Add-LogRow $runNo $startedAt $true
        Write-RunLog "Run $runNo succeeded: $($strings -join ', ')"
        $succeeded = $true
        break
    } catch {
        Add-LogRow $runNo $startedAt $false
        Write-RunLog "Run $runNo failed: $($_.Exception.Message)"
    }
}

if (-not $succeeded) { exit 1 }
