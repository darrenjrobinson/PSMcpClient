function New-McpError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ErrorId,
        [Parameter(Mandatory)][string]$Message,
        [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::InvalidOperation,
        $TargetObject,
        [System.Exception]$Exception
    )

    if (-not $Exception) {
        $Exception = [System.InvalidOperationException]::new($Message)
    }

    [System.Management.Automation.ErrorRecord]::new($Exception, $ErrorId, $Category, $TargetObject)
}
