<#
.SYNOPSIS
    Builds the static NuGet feed for the Dime.Scheduler Business Central connector from this
    repository's GitHub releases.

.DESCRIPTION
    Every release in this repository carries the connector's per-major NuGet packages
    ({publisher}.{name}.BC{major}.{appId}) as assets. This script downloads them all and lays
    out a NuGet v3 feed as plain files for GitHub Pages, in the shape the AL VS Code extension
    hardcodes (the Azure DevOps Artifacts layout):

        nuget/v3/index.json                         service index
        nuget/v3/search.json                        every package id with all its versions
        nuget/v3/flat2/{id}/index.json              version list per package id
        nuget/v3/flat2/{id}/{version}/{id}.{version}.nupkg

    The AL extension filters search results by app id on its side and GitHub Pages ignores the
    query string, so one static search file answers every query. The extension takes the first
    id that contains the app id and ignores the project's BC version, so package ids are listed
    newest BC major first. BcContainerHelper and AL-Go read the same search file and pick the
    major that fits the target platform through each package's Microsoft.Application range.

    For VS Code projects on an older major, the same feed is also written per BC major under
    bc{major}/ (e.g. {base}/bc28), each listing only that major's package. A project points
    al.nugetFeeds at the sub-feed matching its platform.

    Ids are lowercased because the extension lowercases them in the download URL. Versions are
    the release tags without the leading 'v' (four-part), so an app.json dependency version
    matches exactly. The site is rebuilt from scratch on every run.

    Requires the GitHub CLI (gh) authenticated for this repository.

.EXAMPLE
    ./scripts/Build-Feed.ps1 -SiteRoot site -BaseUrl https://dime-scheduler.github.io/bc-packages -Repo dime-scheduler/bc-packages
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SiteRoot,
    [Parameter(Mandatory)][string]$BaseUrl,
    [Parameter(Mandatory)][string]$Repo
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$BaseUrl = $BaseUrl.TrimEnd('/')
if (Test-Path $SiteRoot) { Remove-Item $SiteRoot -Recurse -Force }
New-Item -ItemType Directory -Path $SiteRoot -Force | Out-Null
# Release assets are staged here, then laid out once for the root feed and once per BC major.
$staging = Join-Path ([System.IO.Path]::GetTempPath()) "bcfeed_$([guid]::NewGuid().ToString('N'))"

function Read-NuspecId {
    param([string]$Path)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -like '*.nuspec' } | Select-Object -First 1
        if (-not $entry) { throw "No nuspec found in '$Path'." }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { ([xml]$reader.ReadToEnd()).package.metadata.id } finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }
}

$releases = gh release list --repo $Repo --limit 200 --json tagName,isDraft,isPrerelease | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'gh release list failed.' }
$download = Join-Path $staging '_releases'
$packages = @{}
try {
    foreach ($release in $releases | Where-Object { -not $_.isDraft }) {
        if ($release.tagName -notmatch '^v(\d+\.\d+\.\d+\.\d+)$') {
            Write-Warning "Skipping release '$($release.tagName)': tag is not v<major>.<minor>.<build>.<revision>."
            continue
        }
        $version = $Matches[1]
        $dir = Join-Path $download $release.tagName
        gh release download $release.tagName --repo $Repo --pattern '*.nupkg' --dir $dir
        if ($LASTEXITCODE -ne 0) { throw "gh release download failed for $($release.tagName)." }
        foreach ($nupkg in Get-ChildItem $dir -Filter '*.nupkg') {
            $id = (Read-NuspecId $nupkg.FullName).ToLowerInvariant()
            $target = Join-Path $staging "$id/$version"
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Copy-Item $nupkg.FullName -Destination (Join-Path $target "$id.$version.nupkg")
            if (-not $packages.ContainsKey($id)) { $packages[$id] = @() }
            $packages[$id] += [version]$version
            Write-Host "$id $version"
        }
    }
}
finally {
    Remove-Item $download -Recurse -Force -ErrorAction SilentlyContinue
}
if ($packages.Count -eq 0) { throw "No packages found in releases of $Repo." }

# Newest BC major first; ids without a BC tag sort last.
function Get-BcMajor { param([string]$Id) if ($Id -match '\.bc(\d+)\.') { [int]$Matches[1] } else { -1 } }

function Write-Feed {
    param([string]$Root, [string]$Url, [hashtable]$Packages)
    $v3 = Join-Path $Root 'nuget/v3'
    $flat2 = Join-Path $v3 'flat2'
    New-Item -ItemType Directory -Path $flat2 -Force | Out-Null
    $data = @(foreach ($id in $Packages.Keys | Sort-Object { Get-BcMajor $_ } -Descending) {
        $versions = @($Packages[$id] | Sort-Object -Unique -Descending)
        foreach ($version in $versions) {
            $target = Join-Path $flat2 "$id/$version"
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Copy-Item (Join-Path $staging "$id/$version/$id.$version.nupkg") -Destination (Join-Path $target "$id.$version.nupkg")
        }
        Set-Content -Path (Join-Path $flat2 "$id/index.json") -Encoding utf8NoBOM `
            -Value ([ordered]@{ versions = @($versions | ForEach-Object { $_.ToString() }) } | ConvertTo-Json -Depth 5)
        [ordered]@{
            id       = $id
            version  = $versions[0].ToString()
            versions = @($versions | ForEach-Object {
                [ordered]@{ version = $_.ToString(); '@id' = "$Url/nuget/v3/flat2/$id/$_/$id.$_.nupkg" }
            })
        }
    })
    $search = [ordered]@{ totalHits = $data.Count; data = $data }
    $index = [ordered]@{
        version   = '3.0.0'
        resources = @(
            [ordered]@{ '@id' = "$Url/nuget/v3/search.json"; '@type' = 'SearchQueryService' },
            [ordered]@{ '@id' = "$Url/nuget/v3/search.json"; '@type' = 'SearchQueryService/3.0.0-beta' },
            [ordered]@{ '@id' = "$Url/nuget/v3/flat2/"; '@type' = 'PackageBaseAddress/3.0.0' }
        )
    }
    Set-Content -Path (Join-Path $v3 'search.json') -Value ($search | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
    Set-Content -Path (Join-Path $v3 'index.json') -Value ($index | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
    $data
}

$majors = @($packages.Keys | ForEach-Object { Get-BcMajor $_ } | Where-Object { $_ -ge 0 } | Sort-Object -Unique -Descending)
$data = Write-Feed -Root $SiteRoot -Url $BaseUrl -Packages $packages
foreach ($major in $majors) {
    $subset = @{}
    foreach ($id in $packages.Keys | Where-Object { (Get-BcMajor $_) -eq $major }) { $subset[$id] = $packages[$id] }
    Write-Feed -Root (Join-Path $SiteRoot "bc$major") -Url "$BaseUrl/bc$major" -Packages $subset | Out-Null
}
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
# Without this, GitHub Pages runs Jekyll over the site, which is pointless for plain files.
Set-Content -Path (Join-Path $SiteRoot '.nojekyll') -Value '' -Encoding utf8NoBOM

$rows = @($data | ForEach-Object {
    $links = @($_.versions | ForEach-Object { "<a href=""$($_.'@id')"">$($_.version)</a>" }) -join ', '
    "<tr><td><code>$($_.id)</code></td><td>$links</td></tr>"
}) -join "`n"
$subFeeds = @($majors | ForEach-Object { "<li>BC$($_): <code>$BaseUrl/bc$_</code></li>" }) -join "`n"
$html = @"
<!doctype html>
<meta charset="utf-8">
<title>Dime.Scheduler Business Central packages</title>
<style>body{font-family:system-ui,sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem}td{padding:.25rem .75rem;vertical-align:top}</style>
<h1>Dime.Scheduler Business Central packages</h1>
<p>NuGet feed for the <a href="https://github.com/dime-scheduler/bc-connector">Dime.Scheduler connector</a>, one package per
Business Central major. Feed URL: <code>$BaseUrl</code>. BcContainerHelper and AL-Go pick the major matching the target platform.
The AL VS Code extension always takes the first package listed, the newest major; for another major use its sub-feed:</p>
<ul>
$subFeeds
</ul>
<table>
<tr><th>Package</th><th>Versions</th></tr>
$rows
</table>
"@
Set-Content -Path (Join-Path $SiteRoot 'index.html') -Value $html -Encoding utf8NoBOM
Write-Host "Feed written to $SiteRoot ($($data.Count) package id(s); sub-feeds: $(($majors | ForEach-Object { "bc$_" }) -join ', '))" -ForegroundColor Green
