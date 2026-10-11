#requires -Version 5.1
# build-native: builds the native HEIC decoding libraries of the product from pinned upstream sources (ADR-002 B1,
# HANDOFF-002 section 2-1): libde265 (HEVC decoder) and libheif (HEIF container), DECODING ONLY - no HEVC encoder and no
# other codec is compiled in, plugin loading is off.
#   What is built is written in store\native-libs.json: repository, tag, commit, CMake options and the SHA-256 of the two
#   resulting files. The script takes everything from there; nothing is pinned a second time in this file.
#   Result: native\win-x64\libde265.dll and native\win-x64\libheif.dll (not in Git). MSVC builds libheif as heif.dll; it is
#   stored under the name LibHeifSharp imports. The solution copies both files beside the executable and the tests;
#   scripts\build.ps1 refuses to build without them.
# Needs: Visual Studio 2026 with "Desktop development with C++" (MSVC x64, CMake and Ninja of Visual Studio), Git, and
#   access to github.com for the first run (the sources are cloned once into the work folder and reused afterwards).
# Steps:
#   1. find Visual Studio, load the x64 compiler environment into a PATH that holds Windows, Git and nothing else
#   2. clone each library at its tag and check that the tag still is the pinned commit
#   3. configure + build + install with CMake / Ninja, Release, dynamic C runtime, /Brepro (no time stamps in the files)
#   4. check the result: imported libraries, no encoder inside, SHA-256 against store\native-libs.json
#   5. copy the two files to native\win-x64
# Switches:
#   -Clean           delete the work folder first (sources are cloned again)
#   -UpdatePins      after a version or option change: write the new SHA-256 / size / tool versions into store\native-libs.json
#   -VerifyOnly      build nothing: compare native\win-x64 with the pins (exit code 1 when a file is missing or differs)
#   -WorkDirectory   where sources and build trees go (default build\native); a second folder shows that the result does
#                    not depend on the place it was built in
#   -NoCopy          build and check, but leave native\win-x64 as it is
#   -PinsPath        another pin file of the same form, to try a different version without touching the product's pins;
#                    such a build is never copied to native\win-x64
# Exit codes: 0 = done and identical to the pins; 1 = failed (the reason is printed).
[CmdletBinding()]
param(
    [switch] $Clean,
    [switch] $UpdatePins,
    [switch] $VerifyOnly,
    [string] $WorkDirectory,
    [switch] $NoCopy,
    [string] $PinsPath
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$productPinsPath = Join-Path $root 'store\native-libs.json'
if ($PinsPath) { $pinsPath = [System.IO.Path]::GetFullPath($PinsPath) } else { $pinsPath = $productPinsPath }
$isProductPins = $pinsPath -eq $productPinsPath
$outputDirectory = Join-Path $root 'native\win-x64'
if (-not $WorkDirectory) { $WorkDirectory = Join-Path $root 'build\native' }
$WorkDirectory = [System.IO.Path]::GetFullPath($WorkDirectory)

function Fail([string] $message) {
    Write-Host "BUILD-NATIVE FAILED: $message" -ForegroundColor Red
    exit 1
}

function Get-Sha256([string] $path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$pins = Get-Content -LiteralPath $pinsPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($pins.platform -ne 'win-x64') { Fail "store\native-libs.json is for '$($pins.platform)'; this script builds win-x64." }

# ---- -VerifyOnly: the files that are there against the pins ----
function Test-AgainstPins([string] $directory) {
    $ok = $true
    foreach ($file in $pins.files) {
        $path = Join-Path $directory $file.fileName
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Host ("  {0,-14} MISSING" -f $file.fileName) -ForegroundColor Red
            $ok = $false
            continue
        }
        $hash = Get-Sha256 $path
        $bytes = (Get-Item -LiteralPath $path).Length
        if ($hash -eq $file.sha256 -and $bytes -eq $file.bytes) {
            Write-Host ("  {0,-14} {1} bytes  sha256 {2}  = pinned" -f $file.fileName, $bytes, $hash)
        }
        else {
            Write-Host ("  {0,-14} {1} bytes  sha256 {2}  DIFFERS from the pin ({3} bytes, {4})" -f $file.fileName, $bytes, $hash, $file.bytes, $file.sha256) -ForegroundColor Red
            $ok = $false
        }
    }
    return $ok
}

if ($VerifyOnly) {
    Write-Host "native\win-x64 against store\native-libs.json:"
    if (Test-AgainstPins $outputDirectory) { exit 0 }
    Write-Host 'Run scripts\build-native.ps1 to build the libraries.' -ForegroundColor Yellow
    exit 1
}

# ---- 1. tools ----
$git = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
if (-not $git) { Fail 'git.exe is not on the PATH.' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { Fail 'Visual Studio Installer (vswhere.exe) not found. Install Visual Studio 2026 with "Desktop development with C++".' }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
if (-not $vs) { Fail 'No Visual Studio with the MSVC x64 build tools found. In Visual Studio Installer: Modify -> "Desktop development with C++".' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$cmake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$ninja = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
foreach ($tool in @($vcvars, $cmake, $ninja)) {
    if (-not (Test-Path -LiteralPath $tool)) { Fail "Not found: $tool (Visual Studio component 'C++ CMake tools for Windows' / 'MSVC build tools')." }
}

if ($Clean -and (Test-Path -LiteralPath $WorkDirectory)) {
    # -Clean deletes a whole folder: only one below build\ of this repository is accepted
    $buildRoot = (Join-Path $root 'build') + '\'
    if (-not $WorkDirectory.StartsWith($buildRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "-Clean only deletes a work folder below $buildRoot; '$WorkDirectory' is somewhere else. Delete it yourself if that is what you want."
    }
    Write-Host "Deleting the work folder $WorkDirectory"
    Remove-Item -LiteralPath $WorkDirectory -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null
$logDirectory = Join-Path $WorkDirectory 'logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

# The compiler environment is loaded into a PATH that holds Windows and Git only: nothing that happens to be installed
# on this machine (other compilers, package managers, their libraries and headers) can be found by the build.
$system32 = Join-Path $env:SystemRoot 'System32'
$env:PATH = @($system32, $env:SystemRoot, (Join-Path $system32 'Wbem'), (Join-Path $system32 'WindowsPowerShell\v1.0'), (Split-Path $git)) -join ';'
foreach ($name in @('CL', '_CL_', 'LINK', '_LINK_', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'CMAKE_PREFIX_PATH', 'CMAKE_INCLUDE_PATH', 'CMAKE_LIBRARY_PATH',
        'CMAKE_GENERATOR', 'CMAKE_TOOLCHAIN_FILE', 'PKG_CONFIG_PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'VCPKG_ROOT', 'CONDA_PREFIX')) {
    Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
}
$environmentScript = Join-Path $WorkDirectory 'load-msvc-environment.cmd'
Set-Content -LiteralPath $environmentScript -Encoding ASCII -Value @(
    '@echo off',
    "call `"$vcvars`" >nul 2>&1",
    'if errorlevel 1 exit /b 1',
    'set')
$environment = & cmd.exe /d /c $environmentScript
if ($LASTEXITCODE -ne 0) { Fail "vcvars64.bat failed ($vcvars)." }
foreach ($line in $environment) {
    $separator = $line.IndexOf('=')
    if ($separator -gt 0) { Set-Item -Path ("Env:" + $line.Substring(0, $separator)) -Value $line.Substring($separator + 1) }
}
$cl = (Get-Command cl.exe -ErrorAction SilentlyContinue).Source
if (-not $cl) { Fail 'cl.exe is not available after vcvars64.bat.' }

# Runs a tool, keeps everything it prints in a log file, and stops on a non-zero exit code.
# (stderr of a native tool must not become a terminating error: the preference is lowered for the call only.)
function Invoke-Tool([string] $logName, [string] $exe, [string[]] $arguments, [string] $workingDirectory) {
    $log = Join-Path $logDirectory $logName
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $workingDirectory
    try {
        & $exe @arguments 2>&1 | ForEach-Object { "$_" } | Set-Content -LiteralPath $log -Encoding UTF8
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) {
        Get-Content -LiteralPath $log -Tail 40 | Write-Host
        Fail "$([System.IO.Path]::GetFileName($exe)) ended with exit code $code (log: $log)."
    }
    return $log
}

function Get-ToolOutput([string] $exe, [string[]] $arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $exe @arguments 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $previous }
}

$clBanner = (Get-ToolOutput $cl @()) | Where-Object { $_ -match '\d+\.\d+\.\d+' } | Select-Object -First 1
$clVersion = if ($clBanner -match '(\d+\.\d+\.\d+(\.\d+)?)') { $Matches[1] } else { 'unknown' }
$cmakeVersion = ((Get-ToolOutput $cmake @('--version')) | Select-Object -First 1) -replace '^cmake version\s+', ''
$ninjaVersion = (Get-ToolOutput $ninja @('--version')) | Select-Object -First 1
$toolchain = "MSVC toolset $($env:VCToolsVersion) (cl $clVersion), Windows SDK $($env:WindowsSDKVersion.TrimEnd('\')), CMake $cmakeVersion, Ninja $ninjaVersion"
Write-Host "Toolchain: $toolchain"

# ---- 2. sources ----
function Get-Source($library) {
    $directory = Join-Path $WorkDirectory ("src\{0}-{1}" -f $library.name, $library.version)
    # "patches" (optional, paths relative to the pin file): changes to the upstream sources. A patched source folder is
    # never reused - it is cloned and patched again on every run, so what is built is always tag + exactly these patches.
    $patches = @()
    if ($library.PSObject.Properties.Name -contains 'patches') { $patches = @($library.patches) }
    if ($patches.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $directory '.git'))) {
        $head = (Get-ToolOutput $git @('-C', $directory, 'rev-parse', 'HEAD')) | Select-Object -First 1
        $dirty = Get-ToolOutput $git @('-C', $directory, 'status', '--porcelain', '--untracked-files=no')
        if ($head -eq $library.commit -and -not $dirty) {
            Write-Host ("  {0} {1}: source present at {2}" -f $library.name, $library.version, $library.commit)
            return $directory
        }
        Write-Host ("  {0}: the source folder is not the pinned commit or was changed - cloning again" -f $library.name)
    }
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $directory) | Out-Null
    # autocrlf off: the bytes of the sources are the bytes of the repository on every machine
    [void](Invoke-Tool ("clone-{0}.log" -f $library.name) $git @('-c', 'core.autocrlf=false', '-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1', '--branch', $library.tag, $library.repository, $directory) $WorkDirectory)
    $head = (Get-ToolOutput $git @('-C', $directory, 'rev-parse', 'HEAD')) | Select-Object -First 1
    if ($head -ne $library.commit) {
        Fail ("{0}: tag {1} is commit {2}, but {3} is pinned. The tag was moved upstream, or the pin is wrong - nothing was built." -f $library.name, $library.tag, $head, $library.commit)
    }
    Write-Host ("  {0} {1}: cloned {2} at {3}" -f $library.name, $library.version, $library.tag, $head)
    foreach ($patch in $patches) {
        $patchPath = Join-Path (Split-Path $pinsPath) $patch
        if (-not (Test-Path -LiteralPath $patchPath)) { Fail "$($library.name): patch file not found: $patchPath" }
        [void](Invoke-Tool ("patch-{0}.log" -f $library.name) $git @('-C', $directory, '-c', 'core.autocrlf=false', 'apply', '--whitespace=nowarn', $patchPath) $WorkDirectory)
        Write-Host ("  {0} {1}: PATCHED with {2} (sha256 {3})" -f $library.name, $library.version, $patch, (Get-Sha256 $patchPath)) -ForegroundColor Yellow
    }
    return $directory
}

# ---- 3. build ----
$installDirectory = Join-Path $WorkDirectory 'install'
if (Test-Path -LiteralPath $installDirectory) { Remove-Item -LiteralPath $installDirectory -Recurse -Force }

function Build-Library($library, [string] $source) {
    $build = Join-Path $WorkDirectory ("bld\{0}-{1}" -f $library.name, $library.version)
    if (Test-Path -LiteralPath $build) { Remove-Item -LiteralPath $build -Recurse -Force }
    $arguments = @(
        '-S', $source, '-B', $build, '-G', 'Ninja',
        "-DCMAKE_MAKE_PROGRAM=$ninja",
        '-DCMAKE_BUILD_TYPE=Release',
        "-DCMAKE_INSTALL_PREFIX=$installDirectory",
        "-DCMAKE_PREFIX_PATH=$installDirectory",
        '-DCMAKE_C_COMPILER=cl.exe', '-DCMAKE_CXX_COMPILER=cl.exe',
        # /Brepro: the compiler and the linker write no time stamps - the same sources give the same bytes
        '-DCMAKE_C_FLAGS_INIT=/Brepro', '-DCMAKE_CXX_FLAGS_INIT=/Brepro',
        '-DCMAKE_SHARED_LINKER_FLAGS_INIT=/Brepro', '-DCMAKE_EXE_LINKER_FLAGS_INIT=/Brepro', '-DCMAKE_MODULE_LINKER_FLAGS_INIT=/Brepro',
        '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL',
        '-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF', '-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF',
        '-DCMAKE_EXPORT_COMPILE_COMMANDS=OFF'
    ) + @($library.cmakeOptions)
    Write-Host ("  {0} {1}: configure" -f $library.name, $library.version)
    $configureLog = Invoke-Tool ("configure-{0}.log" -f $library.name) $cmake $arguments $WorkDirectory
    Write-Host ("  {0} {1}: build + install" -f $library.name, $library.version)
    [void](Invoke-Tool ("build-{0}.log" -f $library.name) $cmake @('--build', $build, '--target', 'install') $WorkDirectory)
    return $configureLog
}

Write-Host 'Sources:'
$sources = @{}
foreach ($library in $pins.libraries) { $sources[$library.name] = Get-Source $library }
Write-Host 'Build:'
$configureLogs = @{}
foreach ($library in $pins.libraries) { $configureLogs[$library.name] = Build-Library $library $sources[$library.name] }

# ---- 4. checks ----
$built = @{}
foreach ($file in $pins.files) {
    # builtAs: the name the upstream build gives the file (MSVC builds libheif as heif.dll); fileName: the name it is stored under
    $path = Join-Path $installDirectory (Join-Path 'bin' $file.builtAs)
    if (-not (Test-Path -LiteralPath $path)) { Fail "The build did not produce $($file.builtAs) (looked in $installDirectory\bin)." }
    $built[$file.fileName] = $path
}

$dumpbin = (Get-Command dumpbin.exe -ErrorAction SilentlyContinue).Source
if (-not $dumpbin) { Fail 'dumpbin.exe is not available after vcvars64.bat.' }

# 4a. imports: Windows, the Visual C++ runtime (it travels with the package, store\vc-runtime.json) and each other - nothing else
$runtimeFiles = @((Get-Content -LiteralPath (Join-Path $root 'store\vc-runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json).files | ForEach-Object { $_.fileName.ToLowerInvariant() })
$ownFiles = @($pins.files | ForEach-Object { $_.fileName.ToLowerInvariant() })
Write-Host 'Imported libraries:'
foreach ($name in $built.Keys | Sort-Object) {
    $imports = @((Get-ToolOutput $dumpbin @('/nologo', '/dependents', $built[$name])) | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[A-Za-z0-9_.\-]+\.dll$' } | ForEach-Object { $_.ToLowerInvariant() })
    $unexpected = @($imports | Where-Object { $_ -ne 'kernel32.dll' -and $_ -notlike 'api-ms-win-*' -and $runtimeFiles -notcontains $_ -and $ownFiles -notcontains $_ })
    Write-Host ("  {0,-14} {1}" -f $name, ($imports -join ', '))
    if ($unexpected.Count -gt 0) {
        Fail ("{0} imports {1}: not Windows, not a Visual C++ runtime file of store\vc-runtime.json and not one of the libraries built here." -f $name, ($unexpected -join ', '))
    }
    if (-not ($imports | Where-Object { $_ -like 'vcruntime140*' })) { Fail "$name does not import the Visual C++ runtime: it was not built with the dynamic C runtime." }
}

# 4b. decoding only: no encoder library inside the files (their names appear in the text of a library that was built
#     with them), no encoder interface exported by libde265. libheif always exports its own heif_encoder_* functions - they
#     are part of its interface and find no encoder to work with; Imaging.Tests asks the loaded library for that.
$encoderMarkers = @('x265', 'kvazaar', 'x264', 'uvg266', 'vvenc', 'svt-av1', 'svtav1', 'rav1e', 'libaom', 'openjph')
foreach ($name in $built.Keys | Sort-Object) {
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($built[$name]))
    $found = @($encoderMarkers | Where-Object { $text.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($found.Count -gt 0) { Fail ("{0} contains the text of an encoder library: {1}." -f $name, ($found -join ', ')) }
    $exports = @((Get-ToolOutput $dumpbin @('/nologo', '/exports', $built[$name])) | ForEach-Object { if ($_ -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)') { $Matches[1] } })
    $encoderExports = @($exports | Where-Object { $_ -like 'en265_*' -or $_ -like 'x265_*' })
    if ($encoderExports.Count -gt 0) {
        $examples = @($encoderExports | Select-Object -First 3) -join ', '
        Fail ("{0} exports an encoder interface: {1} ..." -f $name, $examples)
    }
    Write-Host ("  {0,-14} {1} exported functions, no encoder library text, no encoder interface" -f $name, $exports.Count)
}
$summaryLines = @()
if ($configureLogs.ContainsKey('libheif')) {
    $summaryLines = @(Get-Content -LiteralPath $configureLogs['libheif'] | Where-Object { $_ -match '^(libde265 HEVC decoder|x265 HEVC encoder|HEIC|AVIF|JPEG|AVC|VVC|Uncompressed)\s' -or $_ -match '^\s*HEIC\s' })
}
if ($summaryLines.Count -gt 0) {
    Write-Host 'libheif configuration (from its configure log):'
    $summaryLines | ForEach-Object { Write-Host "  $_" }
}

# 4c. the bytes
$results = @()
foreach ($file in $pins.files) {
    $path = $built[$file.fileName]
    $results += [pscustomobject]@{ FileName = $file.fileName; BuiltAs = $file.builtAs; Path = $path; Sha256 = Get-Sha256 $path; Bytes = (Get-Item -LiteralPath $path).Length; Pinned = $file.sha256; PinnedBytes = $file.bytes }
}

if ($UpdatePins) {
    $text = Get-Content -LiteralPath $pinsPath -Raw -Encoding UTF8
    foreach ($r in $results) {
        $pattern = '\{\s*"fileName":\s*"' + [regex]::Escape($r.FileName) + '",\s*"builtAs":\s*"[^"]*",\s*"sha256":\s*"[^"]*",\s*"bytes":\s*\d+\s*\}'
        $line = '{ "fileName": "' + $r.FileName + '", "builtAs": "' + $r.BuiltAs + '", "sha256": "' + $r.Sha256 + '", "bytes": ' + $r.Bytes + ' }'
        if (-not [regex]::IsMatch($text, $pattern)) { Fail "store\native-libs.json has no 'files' line for $($r.FileName) in the expected form." }
        $text = [regex]::Replace($text, $pattern, $line)
    }
    $text = [regex]::Replace($text, '"toolchain":\s*"[^"]*"', ('"toolchain": "' + $toolchain.Replace('\', '\\').Replace('"', '\"') + '"'))
    [System.IO.File]::WriteAllText($pinsPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'store\native-libs.json: SHA-256, size and toolchain updated (-UpdatePins).' -ForegroundColor Yellow
}
else {
    $differs = @($results | Where-Object { $_.Sha256 -ne $_.Pinned -or $_.Bytes -ne $_.PinnedBytes })
    if ($differs.Count -gt 0) {
        foreach ($r in $differs) {
            Write-Host ("  {0}: built {1} bytes sha256 {2}; pinned {3} bytes sha256 {4}" -f $r.FileName, $r.Bytes, $r.Sha256, $r.PinnedBytes, $r.Pinned) -ForegroundColor Red
        }
        Write-Host "  this toolchain:   $toolchain"
        Write-Host "  pinned toolchain: $($pins.build.toolchain)"
        Fail 'The built files differ from store\native-libs.json. Nothing was copied. A different compiler version gives different bytes: use the pinned toolchain, or re-pin on purpose with -UpdatePins and run every test.'
    }
}

# ---- 5. copy ----
if (-not $isProductPins) { $NoCopy = $true }
if (-not $NoCopy) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    foreach ($r in $results) { Copy-Item -LiteralPath $r.Path -Destination (Join-Path $outputDirectory $r.FileName) -Force }
}
Write-Host 'Result:'
foreach ($r in $results) { Write-Host ("  {0,-14} {1} bytes  sha256 {2}" -f $r.FileName, $r.Bytes, $r.Sha256) }
if ($NoCopy) { Write-Host "Built in $installDirectory\bin (native\win-x64 left as it is)." } else { Write-Host "Copied to $outputDirectory" }
exit 0
