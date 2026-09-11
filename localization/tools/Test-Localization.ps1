[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Compile-free consistency checks:
#   1. translation table: unique resource names, non-empty keys, coverage;
#   2. resw files match the table and share identical key sets;
#   3. every x:Uid in XAML exists in the table;
#   4. every Loc.S / Loc.F key in C# exists in the table;
#   5. OBS plugin locale files expose exactly the same keys as en-US.ini.
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 parses scripts as ANSI.
# All data files are read as UTF-8 explicitly.

$problems = [System.Collections.Generic.List[string]]::new()
$tablePath = Join-Path $RepoRoot 'localization\control-center-strings.tsv'
$stringsRoot = Join-Path $RepoRoot 'ControlCenter\Strings'
$controlCenterRoot = Join-Path $RepoRoot 'ControlCenter'
$pluginLocaleRoot = Join-Path $RepoRoot 'OBSPlugin\win-openxr\data\locale'

# The main table plus every fragment in localization/fragments/*.tsv are merged.
$tablePaths = @($tablePath)
$fragmentRoot = Join-Path $RepoRoot 'localization\fragments'
if (Test-Path -LiteralPath $fragmentRoot -PathType Container) {
    $tablePaths += @(Get-ChildItem -LiteralPath $fragmentRoot -File -Filter *.tsv | ForEach-Object FullName)
}

$rows = @()
foreach ($path in $tablePaths) {
    $rows += @(Import-Csv -LiteralPath $path -Delimiter "`t" -Encoding utf8)
}

function Get-ResourceName {
    param($Row)
    $property = $Row.prop -replace '[#*]\d*$', ''
    if ($property -eq 'code') { return $Row.key }
    return "$($Row.key).$property"
}

# --- 1. translation table ---
foreach ($row in $rows) {
    if ([string]::IsNullOrWhiteSpace($row.key)) {
        $problems.Add('A row has an empty key.')
    }
}

$duplicateRows = @($rows | Group-Object { Get-ResourceName -Row $_ } | Where-Object { $_.Count -gt 1 })
foreach ($duplicate in $duplicateRows) {
    $problems.Add("Duplicate resource name '$($duplicate.Name)' appears $($duplicate.Count) times in the table.")
}

$tableNames = [System.Collections.Generic.HashSet[string]]::new()
$knownKeys = [System.Collections.Generic.HashSet[string]]::new()
foreach ($row in $rows) {
    [void]$tableNames.Add((Get-ResourceName -Row $row))
    [void]$knownKeys.Add($row.key)
}

$untranslated = @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.'zh-CN') })
Write-Host "Translation table: $($rows.Count) rows, $($untranslated.Count) still falling back to English."

# --- 2. resw ---
$languageKeys = @{}
foreach ($languageDirectory in (Get-ChildItem -LiteralPath $stringsRoot -Directory)) {
    $language = $languageDirectory.Name
    $reswPath = Join-Path $languageDirectory.FullName 'Resources.resw'
    if (-not (Test-Path -LiteralPath $reswPath -PathType Leaf)) {
        $problems.Add("Missing $reswPath")
        continue
    }

    [xml]$document = Get-Content -LiteralPath $reswPath -Raw -Encoding utf8
    $names = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($data in $document.root.data) {
        if (-not $names.Add([string]$data.name)) {
            $problems.Add("$reswPath contains duplicate resource '$($data.name)'.")
        }
    }
    $languageKeys[$language] = $names

    foreach ($missing in ($tableNames | Where-Object { -not $names.Contains($_) })) {
        $problems.Add("$reswPath is missing '$missing' from the translation table.")
    }
}

$referenceLanguage = 'en-US'
if (-not $languageKeys.ContainsKey($referenceLanguage)) {
    $problems.Add("Reference language '$referenceLanguage' has no resources.")
}
else {
    foreach ($language in $languageKeys.Keys) {
        if ($language -eq $referenceLanguage) { continue }
        foreach ($name in ($languageKeys[$language] | Where-Object { -not $languageKeys[$referenceLanguage].Contains($_) })) {
            $problems.Add("$language has '$name' but $referenceLanguage does not.")
        }
        foreach ($name in ($languageKeys[$referenceLanguage] | Where-Object { -not $languageKeys[$language].Contains($_) })) {
            $problems.Add("$referenceLanguage has '$name' but $language does not.")
        }
    }
}

# --- 3. XAML x:Uid ---
foreach ($xamlFile in (Get-ChildItem -LiteralPath $controlCenterRoot -Recurse -File -Filter *.xaml)) {
    $content = Get-Content -LiteralPath $xamlFile.FullName -Raw -Encoding utf8
    foreach ($match in [regex]::Matches($content, 'x:Uid="(?<key>[^"]+)"')) {
        $key = $match.Groups['key'].Value
        if (-not $knownKeys.Contains($key)) {
            $problems.Add("$($xamlFile.Name) uses x:Uid=`"$key`" which is not in the translation table.")
        }
    }
}

# --- 4. C# Loc calls ---
# Loc takes a *resource name*, not an x:Uid key. A XAML-derived key therefore
# has to carry its property suffix (Foo.Text), otherwise the lookup misses and
# the UI silently falls back to English.
foreach ($sourceFile in (Get-ChildItem -LiteralPath $controlCenterRoot -Recurse -File -Filter *.cs)) {
    $content = Get-Content -LiteralPath $sourceFile.FullName -Raw -Encoding utf8
    foreach ($match in [regex]::Matches($content, 'Loc\.(?:S|F)\("(?<key>[^"]+)"')) {
        $key = $match.Groups['key'].Value
        if (-not $tableNames.Contains($key)) {
            $hint = ''
            if ($knownKeys.Contains($key)) {
                $hint = " ('$key' is an x:Uid key; use its resource name with the property suffix, e.g. $key.Text)"
            }
            $problems.Add("$($sourceFile.Name) calls Loc with '$key' which is not a resource name in the translation table.$hint")
        }
    }
}

# --- 5. OBS plugin locale files ---
function Get-IniKeys {
    param([string]$Path)
    $keys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        if ($line -match '^\s*(?<key>[A-Za-z0-9_]+)\s*=') { [void]$keys.Add($Matches['key']) }
    }
    return $keys
}

$pluginFiles = @(Get-ChildItem -LiteralPath $pluginLocaleRoot -File -Filter *.ini)
$englishKeys = $null
foreach ($file in $pluginFiles) {
    $keys = Get-IniKeys -Path $file.FullName
    if ($file.BaseName -eq 'en-US') { $englishKeys = $keys; continue }
    if ($null -eq $englishKeys) { continue }
    foreach ($key in $keys) {
        if (-not $englishKeys.Contains($key)) { $problems.Add("$($file.Name) defines '$key' which en-US.ini does not.") }
    }
    foreach ($key in $englishKeys) {
        if (-not $keys.Contains($key)) { $problems.Add("$($file.Name) is missing key '$key' from en-US.ini.") }
    }
}
Write-Host "Plugin locale files checked: $(($pluginFiles | ForEach-Object Name) -join ', ')"

# --- result ---
if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Host "Localization check FAILED with $($problems.Count) problem(s):" -ForegroundColor Red
    foreach ($problem in $problems) { Write-Host "  - $problem" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host 'Localization check passed.' -ForegroundColor Green
