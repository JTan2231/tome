#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-ZigExecutable($Version, $ToolRoot) {
    foreach ($command in Get-Command zig.exe -CommandType Application -All -ErrorAction SilentlyContinue) {
        $installedVersion = & $command.Source version
        if ($LASTEXITCODE -eq 0 -and $installedVersion -eq $Version) {
            return $command.Source
        }
    }

    $architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        'X64'   { 'x86_64' }
        'Arm64' { 'aarch64' }
        'X86'   { 'x86' }
        default { throw "No Windows Zig download for this architecture. Install Zig $Version and rerun." }
    }

    # SHA-256 values for the Windows archives at https://ziglang.org/download/index.json.
    if ($Version -ne '0.15.2') {
        throw "No verified download configured for Zig $Version. Install that version on PATH and rerun."
    }
    $checksums = @{
        x86_64  = '3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c'
        aarch64 = 'b926465f8872bf983422257cd9ec248bb2b270996fbe8d57872cca13b56fc370'
        x86     = '7a6dfc00f4cc09ec46d3e10eb06f42538e92b6285e34debea7462edaf371da98'
    }

    $archiveName = "zig-$architecture-windows-$Version"
    $ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
    $toolDir = Join-Path $ToolRoot $archiveName
    $zig = Join-Path $toolDir 'zig.exe'
    if (!(Test-Path -LiteralPath $toolDir)) {
        $staging = [IO.Directory]::CreateDirectory((Join-Path $ToolRoot ([guid]::NewGuid().ToString('N')))).FullName
        if ((Split-Path -Parent $staging) -ne $ToolRoot) {
            throw "Temporary directory is outside the Zig cache: $staging"
        }
        try {
            $zip = Join-Path $staging "$archiveName.zip"
            Write-Host "Downloading Zig $Version ($architecture)..."
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri "https://ziglang.org/download/$Version/$archiveName.zip" -OutFile $zip
            if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $checksums[$architecture]) {
                throw "The downloaded Zig $Version archive failed SHA-256 verification."
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($zip, $staging)
            try {
                [IO.Directory]::Move((Join-Path $staging $archiveName), $toolDir)
            } catch [IO.IOException] {
                # A concurrent install may have published the same verified compiler.
                if (!(Test-Path -LiteralPath $zig -PathType Leaf)) { throw }
            }
        } finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $zig -PathType Leaf) {
        $installedVersion = & $zig version
        if ($LASTEXITCODE -eq 0 -and $installedVersion -eq $Version) {
            return $zig
        }
    }
    throw "The cache at '$toolDir' does not contain Zig $Version. Remove that directory and rerun."
}

function Test-PathEntry($PathValue, $Directory) {
    foreach ($entry in ($PathValue -split ';')) {
        if ($entry.Trim().Trim('"').Replace('/', '\').TrimEnd('\') -eq $Directory) {
            return $true
        }
    }
    return $false
}

function Add-TomeToPath($Directory) {
    $environment = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $userPath = $environment.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = if ($null -eq $userPath) { [Microsoft.Win32.RegistryValueKind]::String } else { $environment.GetValueKind('Path') }
        $expandedPath = if ($kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
            [Environment]::ExpandEnvironmentVariables($userPath)
        } else {
            $userPath
        }
        if (!(Test-PathEntry $expandedPath $Directory)) {
            if (!('TomeInstaller.EnvironmentChange' -as [type])) {
                Add-Type -Namespace TomeInstaller -Name EnvironmentChange -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr window, uint message, System.UIntPtr wParam, string lParam,
    uint flags, uint timeout, out System.UIntPtr result);
'@
            }
            $newPath = if ($userPath) { "$Directory;$userPath" } else { $Directory }
            $environment.SetValue('Path', $newPath, $kind)
            $result = [UIntPtr]::Zero
            $null = [TomeInstaller.EnvironmentChange]::SendMessageTimeout(
                [IntPtr]0xffff, 0x001a, [UIntPtr]::Zero, 'Environment', 0x0002, 1000, [ref]$result)
        }
    } finally {
        $environment.Dispose()
    }

    if (!(Test-PathEntry $env:Path $Directory)) {
        $env:Path = if ($env:Path) { "$Directory;$env:Path" } else { $Directory }
    }
}

$prefix = Join-Path $env:LOCALAPPDATA 'Programs\Tome'
$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '.zigversion') -Raw).Trim()
$zig = Get-ZigExecutable $version (Join-Path $prefix 'tools')

Push-Location -LiteralPath $PSScriptRoot
try {
    & $zig build install-tome -Doptimize=ReleaseSafe --prefix $prefix
    if ($LASTEXITCODE -ne 0) { throw "Tome build or installation failed (Zig exit code $LASTEXITCODE)." }
} finally {
    Pop-Location
}

$binDir = Join-Path $prefix 'bin'
Add-TomeToPath $binDir
Write-Host "Installed $(Join-Path $binDir 'tome.exe')"
