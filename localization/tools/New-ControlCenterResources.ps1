[CmdletBinding()]
param(
    [string]$TablePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'control-center-strings.tsv'),
    [string[]]$Languages = @('en-US', 'zh-CN'),
    [string]$StringsRoot = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'ControlCenter\Strings')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Compiles the translation table into ControlCenter/Strings/<lang>/Resources.resw.
# Resource names are "<key>.<property>" for XAML rows and "<key>" for code rows.
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 parses scripts as ANSI,
# and non-ASCII comments can swallow the following line break.

if (-not (Test-Path -LiteralPath $TablePath -PathType Leaf)) {
    throw "Translation table not found: $TablePath"
}

# The main table plus every fragment in localization/fragments/*.tsv are merged,
# so several people (or agents) can add keys without touching a shared file.
$tablePaths = @($TablePath)
$fragmentRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'fragments'
if (Test-Path -LiteralPath $fragmentRoot -PathType Container) {
    $tablePaths += @(Get-ChildItem -LiteralPath $fragmentRoot -File -Filter *.tsv | ForEach-Object FullName)
}

$rows = @()
foreach ($path in $tablePaths) {
    $rows += @(Import-Csv -LiteralPath $path -Delimiter "`t" -Encoding utf8)
}
if ($rows.Count -eq 0) { throw "Translation table has no rows: $TablePath" }
Write-Host "Merged $($tablePaths.Count) table file(s), $($rows.Count) rows."

# Reject duplicate resource names up front: MakePri fails the build on them.
$duplicates = @($rows |
    Group-Object { "$($_.key)|$($_.prop)" } |
    Where-Object { $_.Count -gt 1 })
if ($duplicates.Count -gt 0) {
    throw "Duplicate key/property rows: $(($duplicates | ForEach-Object Name) -join ', ')"
}

function Get-ResourceName {
    param($Row)
    $property = $Row.prop -replace '[#*]\d*$', ''
    if ($property -eq 'code') { return $Row.key }
    return "$($Row.key).$property"
}

function ConvertTo-ReswXml {
    param([System.Collections.Specialized.OrderedDictionary]$Entries)

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$builder.AppendLine('<root>')
    [void]$builder.AppendLine('  <resheader name="resmimetype">')
    [void]$builder.AppendLine('    <value>text/microsoft-resx</value>')
    [void]$builder.AppendLine('  </resheader>')
    [void]$builder.AppendLine('  <resheader name="version">')
    [void]$builder.AppendLine('    <value>2.0</value>')
    [void]$builder.AppendLine('  </resheader>')
    [void]$builder.AppendLine('  <resheader name="reader">')
    [void]$builder.AppendLine('    <value>System.Resources.ResXResourceReader, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value>')
    [void]$builder.AppendLine('  </resheader>')
    [void]$builder.AppendLine('  <resheader name="writer">')
    [void]$builder.AppendLine('    <value>System.Resources.ResXResourceWriter, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value>')
    [void]$builder.AppendLine('  </resheader>')

    foreach ($name in $Entries.Keys) {
        $escapedName = [System.Security.SecurityElement]::Escape([string]$name)
        $escapedValue = [System.Security.SecurityElement]::Escape([string]$Entries[$name])
        [void]$builder.AppendLine("  <data name=`"$escapedName`" xml:space=`"preserve`">")
        [void]$builder.AppendLine("    <value>$escapedValue</value>")
        [void]$builder.AppendLine('  </data>')
    }

    [void]$builder.AppendLine('</root>')
    return $builder.ToString()
}

foreach ($language in $Languages) {
    # en-US is authored in the 'english' column; every other language uses its own column.
    $sourceColumn = 'english'
    if ($language -ne 'en-US') { $sourceColumn = $language }

    if (-not ($rows[0].PSObject.Properties.Name -contains $sourceColumn)) {
        throw "Translation table has no column '$sourceColumn' for language '$language'."
    }

    $entries = [ordered]@{}
    $fallbacks = 0
    foreach ($row in $rows) {
        $name = Get-ResourceName -Row $row
        $english = [string]$row.english
        $translated = [string]$row.$sourceColumn

        if ([string]::IsNullOrWhiteSpace($translated)) {
            $entries[$name] = $english
            if ($language -ne 'en-US') { $fallbacks++ }
        }
        else {
            $entries[$name] = $translated
        }
    }

    $languageDirectory = Join-Path $StringsRoot $language
    New-Item -ItemType Directory -Path $languageDirectory -Force | Out-Null
    $targetPath = Join-Path $languageDirectory 'Resources.resw'
    $xml = ConvertTo-ReswXml -Entries $entries
    [System.IO.File]::WriteAllText($targetPath, $xml, [System.Text.UTF8Encoding]::new($true))

    $note = ''
    if ($language -ne 'en-US') { $note = " ($fallbacks entries fall back to English)" }
    Write-Host "Wrote $($entries.Count) resources -> $targetPath$note"
}
