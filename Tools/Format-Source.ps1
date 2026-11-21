# Mechanical, behaviour-preserving reformatter for dense PowerShell source.
#   1. One statement per line: ';' between statements becomes a line break.
#   2. A { } block that held several statements on one line is opened up.
#   3. Long param(...) lists and long @{...} literals get one entry per line.
#   4. Optional: Invoke-Formatter (PSScriptAnalyzer) for indentation and spacing.
# After every file the token stream (ignoring line breaks and ';') is compared with the original;
# a file whose tokens differ is left untouched and reported.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Path,
    [int]$MaxLine = 120,
    [switch]$UseScriptAnalyzer,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Management.Automation

function Get-SignificantToken {
    param([string]$Text)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tokens) {
        if ($t.Kind -in @('NewLine', 'Semi', 'EndOfInput', 'LineContinuation')) { continue }
        $list.Add(([string]$t.Kind) + '|' + $t.Text)
    }
    return [pscustomobject]@{ Tokens = $list; Errors = @($errors) }
}

function Split-Statement {
    param([string]$Text, [int]$MaxLine)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw ('parse errors before formatting: ' + $errors[0].Message) }
    $lines = $Text -split "`n"
    $lineLength = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) { $lineLength[$i + 1] = $lines[$i].TrimEnd("`r").Length }

    # edits: offset -> replacement instructions
    $edits = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $previous = $null
    for ($n = 0; $n -lt $tokens.Count; $n++) {
        $t = $tokens[$n]
        $kind = [string]$t.Kind
        switch ($kind) {
            { $_ -in @('LCurly', 'AtCurly', 'LParen', 'AtParen', 'DollarParen', 'LBracket') } {
                $isParam = ($kind -eq 'LParen' -and $previous -and [string]$previous.Kind -eq 'Param')
                $long = ($lineLength[$t.Extent.StartLineNumber] -gt $MaxLine)
                $stack.Push([pscustomobject]@{ Kind = $kind; Token = $t; Splits = 0; IsParam = $isParam; Long = $long })
            }
            { $_ -in @('RCurly', 'RParen', 'RBracket') } {
                if ($stack.Count) {
                    $open = $stack.Pop()
                    $sameLine = ($open.Token.Extent.StartLineNumber -eq $t.Extent.StartLineNumber)
                    if ($open.Splits -gt 0 -and $sameLine) {
                        # open the block: newline after the opener, newline before the closer
                        $edits.Add([pscustomobject]@{ Offset = $open.Token.Extent.EndOffset; Length = 0; Text = "`n" })
                        $edits.Add([pscustomobject]@{ Offset = $t.Extent.StartOffset; Length = 0; Text = "`n" })
                    }
                }
            }
            'Semi' {
                $inner = $null
                if ($stack.Count) { $inner = $stack.Peek() }
                $split = $false
                if ($null -eq $inner) { $split = $true }
                elseif ($inner.Kind -eq 'LCurly') { $split = $true }
                elseif ($inner.Kind -eq 'AtCurly' -and $inner.Long) { $split = $true }
                if ($split) {
                    $next = $null
                    if ($n + 1 -lt $tokens.Count) { $next = $tokens[$n + 1] }
                    $atLineEnd = ($null -eq $next -or [string]$next.Kind -in @('NewLine', 'EndOfInput'))
                    $beforeComment = ($next -and [string]$next.Kind -eq 'Comment' -and $next.Extent.StartLineNumber -eq $t.Extent.StartLineNumber)
                    if ($atLineEnd -or $beforeComment) {
                        $edits.Add([pscustomobject]@{ Offset = $t.Extent.StartOffset; Length = 1; Text = '' })
                    }
                    else {
                        $edits.Add([pscustomobject]@{ Offset = $t.Extent.StartOffset; Length = 1; Text = "`n" })
                        if ($inner) { $inner.Splits++ }
                    }
                }
            }
            { $_ -in @('And', 'Or', 'Pipe') } {
                # A long condition or pipeline continues on the next line after the operator.
                if ($lineLength[$t.Extent.StartLineNumber] -gt ($MaxLine + 20)) {
                    $next = $tokens[$n + 1]
                    $inner = $null
                    if ($stack.Count) { $inner = $stack.Peek() }
                    $breakable = ($kind -eq 'Pipe' -and ($null -eq $inner -or $inner.Kind -eq 'LCurly')) -or ($kind -ne 'Pipe' -and $inner -and $inner.Kind -eq 'LParen')
                    if ($breakable -and [string]$next.Kind -notin @('NewLine', 'Comment')) {
                        $edits.Add([pscustomobject]@{ Offset = $t.Extent.EndOffset; Length = 0; Text = "`n" })
                    }
                }
            }
            'Comma' {
                if ($stack.Count) {
                    $inner = $stack.Peek()
                    if ($inner.IsParam -and $inner.Long) {
                        $next = $tokens[$n + 1]
                        if ([string]$next.Kind -ne 'NewLine') {
                            $edits.Add([pscustomobject]@{ Offset = $t.Extent.EndOffset; Length = 0; Text = "`n" })
                            $inner.Splits++
                        }
                    }
                }
            }
        }
        if ($kind -notin @('NewLine', 'Comment')) { $previous = $t }
    }
    if (-not $edits.Count) { return $Text }
    $builder = New-Object System.Text.StringBuilder $Text
    foreach ($e in @($edits | Sort-Object -Property Offset -Descending)) {
        [void]$builder.Remove($e.Offset, $e.Length)
        [void]$builder.Insert($e.Offset, $e.Text)
    }
    return $builder.ToString()
}

function Set-SimpleIndent {
    # Fallback indentation when PSScriptAnalyzer is not available: indent by bracket depth.
    param([string]$Text)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $lines = $Text -split "`n"
    $depthAtLine = @{}
    $protected = @{}
    $depth = 0
    foreach ($t in $tokens) {
        $kind = [string]$t.Kind
        $line = $t.Extent.StartLineNumber
        if (-not $depthAtLine.ContainsKey($line)) {
            $d = $depth
            if ($kind -in @('RCurly', 'RParen', 'RBracket')) { $d = [Math]::Max(0, $depth - 1) }
            $depthAtLine[$line] = $d
        }
        if ($t.Extent.EndLineNumber -gt $line) {
            # multi-line token (here-string, multi-line string or comment): never re-indent its inner lines
            for ($l = $line + 1; $l -le $t.Extent.EndLineNumber; $l++) { $protected[$l] = $true }
        }
        if ($kind -in @('LCurly', 'AtCurly', 'LParen', 'AtParen', 'DollarParen', 'LBracket')) { $depth++ }
        elseif ($kind -in @('RCurly', 'RParen', 'RBracket')) { $depth = [Math]::Max(0, $depth - 1) }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $number = $i + 1
        if ($protected.ContainsKey($number)) { continue }
        $content = $lines[$i].Trim()
        if (-not $content) { $lines[$i] = ''; continue }
        $d = 0
        if ($depthAtLine.ContainsKey($number)) { $d = $depthAtLine[$number] }
        $lines[$i] = (' ' * (4 * $d)) + $content
    }
    return ($lines -join "`n")
}

$settings = @{
    IncludeRules = @('PSPlaceOpenBrace', 'PSPlaceCloseBrace', 'PSUseConsistentWhitespace', 'PSUseConsistentIndentation', 'PSAlignAssignmentStatement')
    Rules        = @{
        PSPlaceOpenBrace           = @{ Enable = $true; OnSameLine = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true }
        PSPlaceCloseBrace          = @{ Enable = $true; NewLineAfter = $false; IgnoreOneLineBlock = $true; NoEmptyLineBefore = $false }
        PSUseConsistentIndentation = @{ Enable = $true; Kind = 'space'; IndentationSize = 4; PipelineIndentation = 'IncreaseIndentationForFirstPipeline' }
        PSUseConsistentWhitespace  = @{ Enable = $true; CheckInnerBrace = $true; CheckOpenBrace = $true; CheckOpenParen = $true; CheckOperator = $true; CheckPipe = $true; CheckSeparator = $true; CheckParameter = $false }
        PSAlignAssignmentStatement = @{ Enable = $false }
    }
}

$result = New-Object System.Collections.Generic.List[object]
foreach ($file in $Path) {
    $bytes = [IO.File]::ReadAllBytes($file)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $original = (New-Object Text.UTF8Encoding($false)).GetString($bytes, $(if ($hasBom) { 3 } else { 0 }), $bytes.Length - $(if ($hasBom) { 3 } else { 0 }))
    $crlf = $original.Contains("`r`n")
    $text = $original.Replace("`r`n", "`n")
    $status = 'unchanged'
    $detail = ''
    try {
        $before = Get-SignificantToken $text
        if ($before.Errors.Count) { throw ('does not parse: ' + $before.Errors[0].Message) }
        $new = Split-Statement -Text $text -MaxLine $MaxLine
        if ($UseScriptAnalyzer) { $new = Invoke-Formatter -ScriptDefinition $new -Settings $settings }
        else { $new = Set-SimpleIndent $new }
        $new = (($new -split "`n") | ForEach-Object { $_.TrimEnd() }) -join "`n"
        $after = Get-SignificantToken $new
        if ($after.Errors.Count) { throw ('result does not parse: ' + $after.Errors[0].Message) }
        if ($before.Tokens.Count -ne $after.Tokens.Count) { throw "token count changed $($before.Tokens.Count) -> $($after.Tokens.Count)" }
        for ($i = 0; $i -lt $before.Tokens.Count; $i++) {
            if ($before.Tokens[$i] -cne $after.Tokens[$i]) { throw "token $i changed: $($before.Tokens[$i]) -> $($after.Tokens[$i])" }
        }
        if ($new -cne $text) {
            $status = 'formatted'
            if (-not $CheckOnly) {
                if ($crlf) { $new = $new.Replace("`n", "`r`n") }
                [IO.File]::WriteAllText($file, $new, (New-Object Text.UTF8Encoding($hasBom)))
            }
        }
    }
    catch { $status = 'SKIPPED'; $detail = $_.Exception.Message }
    $result.Add([pscustomobject]@{ File = $file; Status = $status; Detail = $detail })
}
$result
