function Get-McpStderrTail {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'stderr is diagnostic only; an unreadable stream must not mask the original error')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [int]$Lines = 20
    )

    $text = $null
    try {
        if ($Session.StderrTask.Wait(1000)) { $text = $Session.StderrTask.Result }
    }
    catch { }

    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $all = @($text -split "`r?`n" | Where-Object { $_ })
    ($all | Select-Object -Last $Lines) -join "`n"
}

function New-McpProcessExitedError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [string]$Context
    )

    $exitCode = try { $Session.Process.ExitCode } catch { 'unknown' }
    $message = "MCP server '$($Session.Name)' exited (exit code $exitCode)"
    if ($Context) { $message += " $Context" }
    $tail = Get-McpStderrTail -Session $Session
    if ($tail) { $message += ".`nLast stderr output:`n$tail" } else { $message += '.' }

    New-McpError -ErrorId 'McpProcessExited' -Category ResourceUnavailable -TargetObject $Session.Name -Message $message
}

function Write-McpMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Message
    )

    $json = ConvertTo-Json -InputObject $Message -Compress -Depth 20
    Write-Verbose "[$($Session.Name)] -> $json"

    if ($Session.Process.HasExited) {
        throw (New-McpProcessExitedError -Session $Session -Context 'before the request could be sent')
    }

    try {
        $Session.StdIn.WriteLine($json)
    }
    catch [System.IO.IOException] {
        throw (New-McpProcessExitedError -Session $Session -Context 'while writing to its stdin')
    }
}

function Read-McpLine {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Task.Wait throws for faulted tasks; the fault is inspected and rethrown after the loop')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][int]$TimeoutMs
    )

    # A ReadLineAsync that times out stays pending on the StreamReader; reuse it rather than start a second one
    if ($null -eq $Session.PendingRead) {
        $Session.PendingRead = $Session.StdOut.ReadLineAsync()
    }
    $task = $Session.PendingRead

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $task.IsCompleted) {
        $remaining = $TimeoutMs - $stopwatch.ElapsedMilliseconds
        if ($remaining -le 0) {
            return [pscustomobject]@{ State = 'Timeout'; Line = $null }
        }

        $slice = [int][Math]::Min($remaining, 250)
        try { $null = $task.Wait($slice) } catch { }
        if ($task.IsCompleted) { break }

        if ($Session.Process.HasExited) {
            try { $null = $task.Wait(500) } catch { }
            if (-not $task.IsCompleted) {
                return [pscustomobject]@{ State = 'Eof'; Line = $null }
            }
        }
    }

    $Session.PendingRead = $null
    if ($task.IsFaulted) {
        throw $task.Exception.InnerException
    }

    $line = $task.Result
    if ($null -eq $line) {
        return [pscustomobject]@{ State = 'Eof'; Line = $null }
    }
    [pscustomobject]@{ State = 'Line'; Line = $line }
}
