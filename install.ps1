# Native Windows installer. Example: & .\install.ps1 -Version 1.1.4
[CmdletBinding()]
param(
    [string]$Version = '1.1.4',
    [string]$InstallDirectory = (Join-Path $env:USERPROFILE '.crux\bin'),
    [switch]$NoModifyPath
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This installer requires Windows. Use install.sh on macOS or Linux.' }
$architecture = $env:PROCESSOR_ARCHITEW6432
if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
if ($architecture -ne 'AMD64') { throw "No native Windows release is available for $architecture. This installer supports Windows x64." }
$Version = $Version -replace '^v', ''
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'Version must be a release number, for example 1.0.0.' }
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
$destination = Join-Path $InstallDirectory 'crux.exe'
$work = Join-Path ([IO.Path]::GetTempPath()) ('crux-install-' + [guid]::NewGuid().ToString('N'))
$pending = $null
# GitHub requires TLS 1.2; Windows PowerShell 5.1 may default to older protocols.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

try {
    $alreadyInstalled = $false
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $installedVersion = & $destination --version
        $alreadyInstalled = ($LASTEXITCODE -eq 0 -and "$installedVersion".Trim() -eq "v$Version")
    }
    if (-not $alreadyInstalled) {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $archive = Join-Path $work 'crux-windows-x64.zip'
        $url = "https://github.com/marsup-space/crux/releases/download/v$Version/crux-windows-x64.zip"
        Write-Host "Downloading Crux v$Version for Windows x64..."
        try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive }
        catch { throw "Could not download $url. Check that this release is publicly accessible and your network is connected. $($_.Exception.Message)" }
        Expand-Archive -LiteralPath $archive -DestinationPath $work
        $bundle = Join-Path $work 'crux-windows-x64'
        $binary = Join-Path $bundle 'bin\crux.exe'
        if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { $binary = Join-Path $bundle 'crux.exe' }
        if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'The release archive does not contain crux.exe.' }
        foreach ($resource in @('providers', 'themes', 'third_party')) {
            if (-not (Test-Path -LiteralPath (Join-Path $bundle $resource) -PathType Container)) {
                throw "The release archive is missing $resource."
            }
        }
        # plugins/ joined the bundle later than the three required
        # resources above — older archives don't carry it, so it is
        # copied when present instead of required.
        $bundledPlugins = Join-Path $bundle 'plugins'
        New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
        $pending = Join-Path $InstallDirectory ('crux.exe.tmp.' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $binary -Destination $pending
        Move-Item -LiteralPath $pending -Destination $destination -Force
        $pending = $null
        foreach ($resource in @('providers', 'themes', 'third_party')) {
            Copy-Item -LiteralPath (Join-Path $bundle $resource) -Destination $InstallDirectory -Recurse -Force
        }
        if (Test-Path -LiteralPath $bundledPlugins -PathType Container) {
            Copy-Item -LiteralPath $bundledPlugins -Destination $InstallDirectory -Recurse -Force
        }
        $installedVersion = & $destination --version
        if ($LASTEXITCODE -ne 0 -or "$installedVersion".Trim() -ne "v$Version") { throw 'Crux was copied, but its version check failed.' }
    }
    if (-not $NoModifyPath) {
        # Update only the user PATH, preserving the machine PATH and other entries.
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $entries = @($userPath -split ';' | Where-Object { $_ })
        $normalized = @($entries | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') })
        if ($normalized -notcontains $InstallDirectory.TrimEnd('\')) {
            [Environment]::SetEnvironmentVariable('Path', (($entries + $InstallDirectory) -join ';'), 'User')
        }
        if (($env:Path -split ';') -notcontains $InstallDirectory) { $env:Path = "$InstallDirectory;$env:Path" }
    }
    Write-Host "Crux v$Version is installed at $destination"
    Write-Host 'Run crux to start Setup. Open a new terminal if needed.'
} finally {
    if ($pending -and (Test-Path -LiteralPath $pending)) { Remove-Item -LiteralPath $pending -Force }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
