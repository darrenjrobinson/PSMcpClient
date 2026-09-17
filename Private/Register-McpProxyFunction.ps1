function Get-McpProxyFunctionName {
    param(
        [Parameter(Mandatory)]$Tool,
        [string]$Prefix
    )

    if ($Prefix) { "${Prefix}_$($Tool.Name)" } else { [string]$Tool.Name }
}

function Get-McpProxyParameterType {
    param($PropertySchema)

    if ($PropertySchema -isnot [System.Collections.IDictionary]) { return $null }

    $type = $PropertySchema['type']
    if ($type -is [System.Collections.IList]) {
        $type = @($type | Where-Object { $_ -ne 'null' } | Select-Object -First 1)[0]
    }

    switch ("$type") {
        'string' { 'string' }
        'boolean' { 'switch' }
        'integer' { 'long' }
        'number' { 'double' }
        'array' { 'object[]' }
        default { $null }
    }
}

function New-McpProxyFunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Tool,
        [Parameter(Mandatory)][string]$FunctionName
    )

    $schema = $Tool.InputSchema
    $properties = if ($schema -is [System.Collections.IDictionary] -and $schema['properties'] -is [System.Collections.IDictionary]) { $schema['properties'] } else { @{} }

    # PSAISuite splats the model's JSON arguments as named parameters, so each schema property becomes a parameter.
    # ${...} syntax keeps hyphenated/dotted property names valid; nothing is Mandatory so a missing argument never prompts.
    $declarations = foreach ($propertyName in $properties.Keys) {
        $type = Get-McpProxyParameterType -PropertySchema $properties[$propertyName]
        $escaped = ([string]$propertyName) -replace '`', '``' -replace '\}', '`}'
        if ($type) { "    [$type]`${$escaped}" } else { "    `${$escaped}" }
    }

    $serverLiteral = $Session.Name -replace "'", "''"
    $toolLiteral = ([string]$Tool.Name) -replace "'", "''"

    $source = @"
param(
$($declarations -join ",`n")
)
`$arguments = @{}
foreach (`$key in `$PSBoundParameters.Keys) {
    `$value = `$PSBoundParameters[`$key]
    if (`$value -is [switch]) { `$value = `$value.IsPresent }
    `$arguments[`$key] = `$value
}
Invoke-McpTool -Server '$serverLiteral' -Name '$toolLiteral' -Arguments `$arguments
"@

    $body = [scriptblock]::Create($source)
    Set-Item -LiteralPath "function:global:$FunctionName" -Value $body
}

function Remove-McpProxyFunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session
    )

    # Remove-Item function:global:x is a silent no-op from module scope; go through the global session state instead
    $globalItems = $global:ExecutionContext.SessionState.InvokeProvider.Item
    foreach ($functionName in @($Session.ProxyFunctions)) {
        try { $globalItems.Remove("function:$functionName", $false) }
        catch { Write-Verbose "[$($Session.Name)] proxy function '$functionName' already removed" }
    }
    $Session.ProxyFunctions = @()
}

function Register-McpProxyFunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [object[]]$Tools = @(),
        [string]$Prefix
    )

    Remove-McpProxyFunction -Session $Session

    $registered = [System.Collections.Generic.List[string]]::new()
    foreach ($tool in $Tools) {
        $functionName = Get-McpProxyFunctionName -Tool $tool -Prefix $Prefix

        $existing = Get-Command -Name $functionName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($existing) {
            if ($existing.CommandType -eq 'Alias') {
                Write-Warning "[$($Session.Name)] tool '$($tool.Name)' maps to '$functionName', an existing alias for '$($existing.Definition)'. Aliases outrank functions, so PSAISuite would invoke the alias instead of the MCP tool. Re-run with -Prefix."
            }
            else {
                Write-Warning "[$($Session.Name)] proxy function '$functionName' shadows an existing $($existing.CommandType) of the same name until Disconnect-McpServer. Use -Prefix to avoid the collision."
            }
        }

        try {
            New-McpProxyFunction -Session $Session -Tool $tool -FunctionName $functionName
            $registered.Add($functionName)
        }
        catch {
            Write-Warning "[$($Session.Name)] could not create proxy function '$functionName' for tool '$($tool.Name)': $($_.Exception.Message)"
        }
    }

    $Session.ProxyFunctions = $registered.ToArray()
    Write-Verbose "[$($Session.Name)] registered $($registered.Count) global proxy function(s)"
}
