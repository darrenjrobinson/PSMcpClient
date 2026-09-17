function Register-McpExitHandler {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Best-effort kill at exit; nothing useful can be done on failure')]
    [CmdletBinding()]
    param()

    if ($script:ExitHandlerRegistered) { return }

    $sessions = $script:Sessions
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
        foreach ($session in @($sessions.Values)) {
            try {
                if (-not $session.Process.HasExited) { $session.Process.Kill($true) }
            }
            catch { }
        }
    }.GetNewClosure()

    $script:ExitHandlerRegistered = $true
}

function Stop-McpProcess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Each step is a best-effort shutdown escalation; a failure just falls through to the next')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session
    )

    $process = $Session.Process
    try { $Session.StdIn.Close() } catch { }
    try { if (-not $process.HasExited) { $null = $process.WaitForExit(2000) } } catch { }
    try {
        if (-not $process.HasExited) {
            $process.Kill($true)
            $null = $process.WaitForExit(5000)
        }
    }
    catch { }

    $tail = Get-McpStderrTail -Session $Session -Lines 50
    if ($tail) { Write-Verbose "[$($Session.Name)] stderr:`n$tail" }

    try { $process.Dispose() } catch { }
}

function Remove-McpSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session
    )

    Remove-McpProxyFunction -Session $Session
    Stop-McpProcess -Session $Session
    $null = $script:Sessions.Remove($Session.Name)
}

function New-McpSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [System.Collections.IDictionary]$Environment,
        [string]$WorkingDirectory,
        [int]$InitializeTimeoutSec,
        [int]$RequestTimeoutSec,
        [int]$DiscoverTimeoutSec
    )

    if ($script:Sessions.ContainsKey($Name)) {
        throw (New-McpError -ErrorId 'McpSessionExists' -Category ResourceExists -TargetObject $Name `
            -Message "An MCP session named '$Name' already exists. Disconnect it first with: Disconnect-McpServer -Server '$Name'")
    }

    if ($InitializeTimeoutSec -le 0) { $InitializeTimeoutSec = $script:DefaultInitializeTimeoutSec }
    if ($RequestTimeoutSec -le 0) { $RequestTimeoutSec = $script:DefaultRequestTimeoutSec }
    if ($DiscoverTimeoutSec -le 0) { $DiscoverTimeoutSec = $InitializeTimeoutSec }

    $startParams = @{ Command = $Command; Arguments = $Arguments }
    if ($Environment) { $startParams.Environment = $Environment }
    if ($WorkingDirectory) { $startParams.WorkingDirectory = $WorkingDirectory }
    $proc = Start-McpProcess @startParams

    $session = [pscustomobject]@{
        PSTypeName           = 'PSMcpClient.Session'
        Name                 = $Name
        Command              = $Command
        Arguments            = $Arguments
        Process              = $proc.Process
        StdIn                = $proc.StdIn
        StdOut               = $proc.StdOut
        StderrTask           = $proc.StderrTask
        PendingRead          = $null
        NextId               = 0
        IgnoredIds           = [System.Collections.Generic.List[string]]::new()
        Era                  = $null
        NegotiatedVersion    = $null
        ServerInfo           = $null
        Capabilities         = $null
        Instructions         = $null
        Tools                = $null
        ToolsStale           = $false
        ProxyRegistered      = $false
        ProxyFunctions       = @()
        ProxyPrefix          = $null
        ProxyNames           = $null
        InitializeTimeoutSec = $InitializeTimeoutSec
        RequestTimeoutSec    = $RequestTimeoutSec
        DiscoverTimeoutSec   = $DiscoverTimeoutSec
    }

    try {
        Initialize-McpSession -Session $session
    }
    catch {
        Stop-McpProcess -Session $session
        throw
    }

    $script:Sessions[$Name] = $session
    Register-McpExitHandler
    $session
}
