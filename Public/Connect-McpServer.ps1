function Connect-McpServer {
    <#
    .SYNOPSIS
        Starts a stdio MCP server process and establishes a named session.
    .DESCRIPTION
        Spawns the server as a child process, detects whether it speaks the modern (2026-07-28, per-request _meta)
        or legacy (initialize handshake) protocol, completes the handshake and registers the session by name.
        Servers can be described explicitly or loaded from a standard "mcpServers" JSON config file as used by
        Claude Desktop, Claude Code and VS Code.
    .PARAMETER Name
        Session name. With -ConfigPath, one or more config keys to connect; omit to connect every server in the file.
    .PARAMETER Command
        Executable to launch (e.g. npx, node, python, a full path). On Windows, .cmd/.bat shims are run via cmd.exe.
    .PARAMETER Arguments
        Arguments passed to the command.
    .PARAMETER Environment
        Environment variables merged over the current process environment for the child.
    .PARAMETER WorkingDirectory
        Working directory for the child process.
    .PARAMETER ConfigPath
        Path to an mcpServers JSON file.
    .PARAMETER InitializeTimeoutSec
        Timeout for the legacy initialize request (default 120; first-run npx downloads can be slow).
    .PARAMETER RequestTimeoutSec
        Default timeout for all other requests (default 30).
    .PARAMETER DiscoverTimeoutSec
        Timeout for the server/discover era probe (defaults to InitializeTimeoutSec).
    .PARAMETER PassThru
        Return the session object(s).
    .EXAMPLE
        Connect-McpServer -Name everything -Command npx -Arguments '-y','@modelcontextprotocol/server-everything'
    .EXAMPLE
        Connect-McpServer -ConfigPath ./mcp.json -Name entrapulse -Verbose
    #>
    [CmdletBinding(DefaultParameterSetName = 'Explicit')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Explicit', Position = 0)]
        [Parameter(ParameterSetName = 'Config')]
        [string[]]$Name,

        [Parameter(Mandatory, ParameterSetName = 'Explicit')]
        [string]$Command,

        [Parameter(ParameterSetName = 'Explicit')]
        [string[]]$Arguments = @(),

        [Parameter(ParameterSetName = 'Explicit')]
        [System.Collections.IDictionary]$Environment,

        [Parameter(ParameterSetName = 'Explicit')]
        [string]$WorkingDirectory,

        [Parameter(Mandatory, ParameterSetName = 'Config')]
        [string]$ConfigPath,

        [int]$InitializeTimeoutSec,
        [int]$RequestTimeoutSec,
        [int]$DiscoverTimeoutSec,
        [switch]$PassThru
    )

    $specs = if ($PSCmdlet.ParameterSetName -eq 'Config') {
        @(Read-McpConfig -ConfigPath $ConfigPath -Name $Name)
    }
    else {
        if ($Name.Count -ne 1) {
            throw (New-McpError -ErrorId 'McpInvalidName' -Category InvalidArgument -TargetObject $Name `
                -Message 'Specify exactly one -Name when connecting with -Command.')
        }
        @(@{
                Name             = $Name[0]
                Command          = $Command
                Arguments        = $Arguments
                Environment      = $Environment
                WorkingDirectory = $WorkingDirectory
            })
    }

    foreach ($spec in $specs) {
        $sessionParams = @{
            Name                 = $spec.Name
            Command              = $spec.Command
            Arguments            = @($spec.Arguments)
            InitializeTimeoutSec = $InitializeTimeoutSec
            RequestTimeoutSec    = $RequestTimeoutSec
            DiscoverTimeoutSec   = $DiscoverTimeoutSec
        }
        if ($spec.Environment) { $sessionParams.Environment = $spec.Environment }
        if ($spec.WorkingDirectory) { $sessionParams.WorkingDirectory = $spec.WorkingDirectory }

        $session = New-McpSession @sessionParams
        Write-Verbose "Connected '$($session.Name)' ($($session.Era), $($session.NegotiatedVersion), pid $($session.Process.Id))"
        if ($PassThru) { $session }
    }
}
