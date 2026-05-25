param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$PackageId = "com.nogut.avatar-recovery",
    [string]$OutputRoot = $PSScriptRoot,
    [string]$BaseUrl = ""
)

$ErrorActionPreference = "Stop"

function ConvertTo-FileUri {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return ([System.Uri]::new($fullPath)).AbsoluteUri
}

$packageRoot = Join-Path $ProjectRoot "Packages\$PackageId"
$packageJsonPath = Join-Path $packageRoot "package.json"

if (-not (Test-Path $packageJsonPath)) {
    throw "Package manifest was not found: $packageJsonPath"
}

$manifest = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
$version = $manifest.version

if ([string]::IsNullOrWhiteSpace($version)) {
    throw "Package version is empty in $packageJsonPath"
}

$packagesDir = Join-Path $OutputRoot "packages"
New-Item -ItemType Directory -Force -Path $packagesDir | Out-Null

$packageFileName = "$PackageId-$version.zip"
$zipPath = Join-Path $packagesDir $packageFileName
$indexPath = Join-Path $OutputRoot "index.json"

if (Test-Path $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("avatar-recovery-vpm-" + [System.Guid]::NewGuid().ToString("N"))
$stagingRoot = Join-Path $tempRoot "package"

try {
    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
    Copy-Item -Path (Join-Path $packageRoot "*") -Destination $stagingRoot -Recurse -Force

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        New-Item -ItemType File -Force -Path $zipPath | Out-Null
        $packageUrl = ConvertTo-FileUri $zipPath
        Remove-Item -LiteralPath $zipPath -Force
        $repoUrl = ConvertTo-FileUri $indexPath
    }
    else {
        $normalizedBaseUrl = $BaseUrl.TrimEnd("/")
        $packageUrl = "$normalizedBaseUrl/packages/$packageFileName"
        $repoUrl = "$normalizedBaseUrl/index.json"
    }

    $stagedManifestPath = Join-Path $stagingRoot "package.json"
    $stagedManifest = Get-Content -LiteralPath $stagedManifestPath -Raw | ConvertFrom-Json

    if ($null -eq $stagedManifest.PSObject.Properties["url"]) {
        $stagedManifest | Add-Member -MemberType NoteProperty -Name "url" -Value $packageUrl
    }
    else {
        $stagedManifest.url = $packageUrl
    }

    if ($null -eq $stagedManifest.PSObject.Properties["repo"]) {
        $stagedManifest | Add-Member -MemberType NoteProperty -Name "repo" -Value $repoUrl
    }
    else {
        $stagedManifest.repo = $repoUrl
    }

    $stagedManifest | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $stagedManifestPath -Encoding UTF8

    Compress-Archive -Path (Join-Path $stagingRoot "*") -DestinationPath $zipPath -Force
    $zipSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $repoManifest = Get-Content -LiteralPath $stagedManifestPath -Raw | ConvertFrom-Json

    if ($null -eq $repoManifest.PSObject.Properties["zipSHA256"]) {
        $repoManifest | Add-Member -MemberType NoteProperty -Name "zipSHA256" -Value $zipSha256
    }
    else {
        $repoManifest.zipSHA256 = $zipSha256
    }

    $versions = [ordered]@{}
    $versions[$version] = $repoManifest

    $packages = [ordered]@{}
    $packages[$PackageId] = [ordered]@{
        versions = $versions
    }

    $repo = [ordered]@{
        name = "Avatar Recovery Unity"
        id = "com.nogut.repos.avatar-recovery"
        url = $repoUrl
        author = "Nickel-JP"
        packages = $packages
    }

    $repo | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $indexPath -Encoding UTF8

    Write-Host "Created VPM package: $zipPath"
    Write-Host "Created VPM repository: $indexPath"
    Write-Host "Package URL: $packageUrl"
    Write-Host "SHA256: $zipSha256"
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
