$ErrorActionPreference = "Stop"

$Repo = "chrisbirster/zim"
$InstallDir = if ($env:ZIM_INSTALL_DIR) { $env:ZIM_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "Zim\bin" }
$Version = if ($env:ZIM_VERSION) { $env:ZIM_VERSION } else { "latest" }
$Arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if ($Arch -eq "x64") { $Arch = "x86_64" }
elseif ($Arch -eq "arm64") { $Arch = "aarch64" }
else { throw "zim: unsupported architecture: $Arch" }

$Asset = "zim-windows-$Arch.zip"
if ($Version -eq "latest") {
    $BaseUrl = "https://github.com/$Repo/releases/latest/download"
} else {
    $Tag = if ($Version.StartsWith("v")) { $Version } else { "v$Version" }
    $BaseUrl = "https://github.com/$Repo/releases/download/$Tag"
}
$Url = "$BaseUrl/$Asset"
$ChecksumUrl = "$BaseUrl/SHA256SUMS.txt"

$Temp = Join-Path ([System.IO.Path]::GetTempPath()) ("zim-install-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $Temp | Out-Null
try {
    $Archive = Join-Path $Temp $Asset
    $ChecksumFile = Join-Path $Temp "SHA256SUMS.txt"
    Write-Host "Installing Zim from $Url"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Archive
    Invoke-WebRequest -UseBasicParsing -Uri $ChecksumUrl -OutFile $ChecksumFile

    $ChecksumLine = Get-Content $ChecksumFile | Where-Object { $_ -match "^[0-9a-fA-F]{64}\s+$([regex]::Escape($Asset))$" } | Select-Object -First 1
    if (-not $ChecksumLine) { throw "zim: checksum for $Asset not found in release" }
    $Expected = ($ChecksumLine -split '\s+')[0].ToLowerInvariant()
    $Actual = (Get-FileHash -Algorithm SHA256 -Path $Archive).Hash.ToLowerInvariant()
    if ($Expected -ne $Actual) { throw "zim: SHA-256 verification failed for $Asset" }

    Expand-Archive -Path $Archive -DestinationPath $Temp -Force
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item (Join-Path $Temp "zim-windows-$Arch\zim.exe") (Join-Path $InstallDir "zim.exe") -Force
    & (Join-Path $InstallDir "zim.exe") --version
    Write-Host "Installed $(Join-Path $InstallDir 'zim.exe')"
    Write-Host "Add $InstallDir to PATH if it is not already present."
} finally {
    Remove-Item -Recurse -Force $Temp -ErrorAction SilentlyContinue
}
