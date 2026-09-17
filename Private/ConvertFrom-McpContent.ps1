function ConvertFrom-McpContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Result
    )

    if ($Result -isnot [System.Collections.IDictionary]) { return $Result }

    if ($Result.ContainsKey('structuredContent') -and $null -ne $Result['structuredContent']) {
        return $Result['structuredContent']
    }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($block in @($Result['content'])) {
        if ($block -isnot [System.Collections.IDictionary]) { continue }

        if ($block['type'] -eq 'text') {
            $text = [string]$block['text']
            $trimmed = $text.Trim()
            $parsed = $null
            if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
                try { $parsed = ConvertFrom-Json -InputObject $trimmed -AsHashtable -Depth 64 } catch { $parsed = $null }
            }
            if ($null -ne $parsed) { $items.Add($parsed) } else { $items.Add($text) }
        }
        else {
            Write-Verbose "Dropped '$($block['type'])' content block; use -Raw to keep non-text content"
        }
    }

    switch ($items.Count) {
        0 { return $null }
        1 { return $items[0] }
        default { return $items.ToArray() }
    }
}
