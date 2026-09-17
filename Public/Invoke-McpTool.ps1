function Invoke-McpTool {
    <#
    .SYNOPSIS
        Calls a tool on an MCP server and returns a PowerShell-friendly result.
    .DESCRIPTION
        Sends tools/call. By default text content is flattened: JSON text becomes objects, other text stays a string,
        and non-text blocks are dropped. structuredContent is preferred when present.
        Errors are returned as strings by default so an LLM tool loop can see and recover from them; use -ThrowOnError
        to raise exceptions instead. A server process dying mid-call always throws.
    .PARAMETER Server
        Session name.
    .PARAMETER Name
        Tool name.
    .PARAMETER Arguments
        Tool arguments matching the tool's inputSchema.
    .PARAMETER Raw
        Return the unmodified tools/call result (content[], isError, structuredContent).
    .PARAMETER ThrowOnError
        Throw on JSON-RPC errors and on results with isError = true.
    .PARAMETER TimeoutSec
        Per-call timeout; defaults to the session's RequestTimeoutSec.
    .EXAMPLE
        Invoke-McpTool -Server everything -Name echo -Arguments @{ message = 'hi' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [string]$Server,

        [Parameter(Mandatory, Position = 1, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Position = 2)]
        [System.Collections.IDictionary]$Arguments,

        [switch]$Raw,
        [switch]$ThrowOnError,
        [int]$TimeoutSec
    )

    process {
        $session = Get-McpSession -Server $Server

        $params = [ordered]@{
            name      = $Name
            arguments = if ($null -ne $Arguments) { $Arguments } else { @{} }
        }
        $response = Send-McpRequest -Session $session -Method 'tools/call' -Params $params -TimeoutSec $TimeoutSec -Raw

        if ($response.ContainsKey('error')) {
            $rpcError = $response['error']
            $message = "MCP error $($rpcError.code): $($rpcError.message)"
            if ($ThrowOnError) {
                throw (New-McpError -ErrorId 'McpProtocolError' -Category InvalidOperation -TargetObject $rpcError -Message $message)
            }
            return $message
        }

        $result = $response['result']
        if ($result -is [System.Collections.IDictionary] -and $result['resultType'] -and $result['resultType'] -ne 'complete') {
            throw (New-McpError -ErrorId 'McpUnsupportedResult' -Category NotImplemented -TargetObject $result `
                -Message "Tool '$Name' returned resultType '$($result['resultType'])'; PSMcpClient supports only 'complete' results.")
        }

        $isError = $result -is [System.Collections.IDictionary] -and $result['isError'] -eq $true
        $content = if ($Raw) { $result } else { ConvertFrom-McpContent -Result $result }

        if ($isError -and $ThrowOnError) {
            $flattened = if ($Raw) { ConvertFrom-McpContent -Result $result } else { $content }
            $text = if ($flattened -is [string]) { $flattened } elseif ($null -ne $flattened) { ConvertTo-Json -InputObject $flattened -Compress -Depth 20 } else { '(no content)' }
            throw (New-McpError -ErrorId 'McpToolError' -Category InvalidResult -TargetObject $result `
                -Message "Tool '$Name' on server '$Server' reported an error: $text")
        }

        $content
    }
}
