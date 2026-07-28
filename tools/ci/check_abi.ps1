<#
.SYNOPSIS
Checks the C ABI on Windows: header compilation under MSVC, both linkage modes,
and the exported symbol set.

.DESCRIPTION
The Windows counterpart of tools/ci/check_abi.sh. It exists separately rather
than as a branch inside that script because almost nothing is shared: the
compiler is cl.exe with different flags and diagnostics, the linkage artifacts
have different names, and PE exports are read with dumpbin rather than nm.

MSVC and dumpbin are used as preinstalled on the runner image; nothing is
downloaded or installed. See
docs/decisions/0014-public-header-and-toolchain-baseline.md.

.PARAMETER Prefix
A `zig build --prefix` output containing include/, lib/, and bin/.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Prefix
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Failures = 0

function Write-Section($Text) { Write-Host "`n== $Text" }
function Add-Failure($Text) {
    Write-Host "FAIL: $Text"
    $script:Failures++
}

$includeDirectory = Join-Path $Prefix 'include'
$libraryDirectory = Join-Path $Prefix 'lib'
$binaryDirectory = Join-Path $Prefix 'bin'

$header = Join-Path $includeDirectory 'phaser.h'
$staticLibrary = Join-Path $libraryDirectory 'phaser_static.lib'
$importLibrary = Join-Path $libraryDirectory 'phaser.lib'
$sharedLibrary = Join-Path $binaryDirectory 'phaser.dll'
$allowList = 'tools/ci/abi_public_symbols.txt'
$client = 'examples/c/abi_client.c'

foreach ($required in @($header, $staticLibrary, $importLibrary, $sharedLibrary, $allowList, $client)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "missing required file: $required"
    }
}

# ---------------------------------------------------------------------------
# Locate MSVC through vswhere, which ships with the installer and is at a fixed
# path on the runner image. This keeps the dependency to "invoke preinstalled
# compilers" rather than adding a setup action.
# ---------------------------------------------------------------------------

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "vswhere.exe not found at $vswhere"
}

$installation = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if ([string]::IsNullOrWhiteSpace($installation)) {
    throw 'no Visual Studio installation with the C++ toolset was found'
}

$devCmd = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $devCmd)) {
    throw "vcvars64.bat not found at $devCmd"
}

# Import the MSVC environment into this session. `set` after the batch file runs
# is the supported way to capture what it exported.
Write-Section 'MSVC environment'
& cmd.exe /c "call `"$devCmd`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
        Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue
    }
}
& cl.exe 2>&1 | Select-Object -First 2 | ForEach-Object { Write-Host "-- $_" }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $work | Out-Null

try {
    # -----------------------------------------------------------------------
    # 1. The header compiles standalone, as C11 and as C++17.
    #
    #    /W4 /WX is the MSVC equivalent of -Wall -Wextra -Werror. It is the part
    #    of this check that Zig's bundled clang cannot perform: MSVC's warnings
    #    about structure packing and language conformance are its own.
    # -----------------------------------------------------------------------

    $probeC = Join-Path $work 'probe.c'
    $probeCpp = Join-Path $work 'probe.cpp'
    Set-Content -LiteralPath $probeC -Encoding ascii -Value @(
        '#include "phaser.h"',
        'int main(void) { return (int)phaser_abi_version(); }'
    )
    Set-Content -LiteralPath $probeCpp -Encoding ascii -Value @(
        '#include "phaser.h"',
        'int main() { return (int)phaser_abi_version(); }'
    )

    Write-Section 'Header compiles as C11'
    & cl.exe /nologo /c /W4 /WX /std:c11 "/I$includeDirectory" $probeC "/Fo$work\probe_c.obj"
    if ($LASTEXITCODE -ne 0) { Add-Failure 'cl.exe could not compile phaser.h as C11' }

    Write-Section 'Header compiles as C++17'
    & cl.exe /nologo /c /W4 /WX /std:c++17 "/I$includeDirectory" $probeCpp "/Fo$work\probe_cpp.obj"
    if ($LASTEXITCODE -ne 0) { Add-Failure 'cl.exe could not compile phaser.h as C++17' }

    # -----------------------------------------------------------------------
    # 2. The C client builds and runs against both linkage modes.
    # -----------------------------------------------------------------------

    # -----------------------------------------------------------------------
    # The static library is linked with lld-link rather than link.exe.
    #
    # MSVC's linker cannot consume the archive today, and neither available
    # path fixes it. With Zig's compiler_rt bundled, link.exe rejects
    # compiler_rt.obj outright: "LNK1143: invalid or corrupt file: no symbol
    # for COMDAT section". Without it, __divti3 and __udivti3 are undefined --
    # Phaser's own object references them and the Microsoft CRT has no
    # 128-bit division helpers to supply.
    #
    # cl.exe still compiles both the header and this client, which is what the
    # independent-compiler requirement of Language and Interoperability
    # section 11 actually asks for: a front end that is not Zig's reading the
    # header. Only the final link differs. The residual gap -- link.exe itself
    # consuming the archive -- is recorded as a known limitation in
    # Language and Interoperability section 4, because a Windows consumer
    # linking statically has to know about it.
    #
    # The object cl.exe emits carries its own /DEFAULTLIB directives, so
    # lld-link resolves the C runtime from the environment vcvars64 set up
    # without being told which libraries to use. ntdll.lib is named explicitly
    # because nothing carries a directive for it: the Zig standard library
    # calls the NT native API directly for files, memory sections, and timing,
    # and those twenty-odd Ldr/Nt/Rtl symbols live only in ntdll. Zig adds this
    # itself when it performs the link; a consumer's toolchain does not, which
    # is why Language and Interoperability section 4.1 tells Windows callers to
    # link it.
    # -----------------------------------------------------------------------

    Write-Section 'C client links and runs against the static library'
    $lldLink = $null
    $candidates = @(
        (Get-Command lld-link.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        (Join-Path $env:ProgramFiles 'LLVM\bin\lld-link.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $lldLink = $candidate; break }
    }
    if (-not $lldLink) {
        Add-Failure 'lld-link.exe not found; cannot link the static library on Windows'
    } else {
        Write-Host "-- linker: $lldLink"
        $staticObject = Join-Path $work 'client_static.obj'
        $staticClient = Join-Path $work 'client_static.exe'
        & cl.exe /nologo /c /W4 /WX /std:c11 "/I$includeDirectory" $client "/Fo$staticObject"
        if ($LASTEXITCODE -ne 0) {
            Add-Failure 'C client did not compile for the static link'
        } else {
            & $lldLink /nologo "/OUT:$staticClient" $staticObject $staticLibrary ntdll.lib
            if ($LASTEXITCODE -ne 0) {
                Add-Failure 'C client did not link against the static library'
            } else {
                & $staticClient
                if ($LASTEXITCODE -ne 0) {
                    Add-Failure 'C client failed against the static library'
                }
            }
        }
    }

    Write-Section 'C client links and runs against the shared library'
    $sharedClient = Join-Path $work 'client_shared.exe'
    & cl.exe /nologo /W4 /WX /std:c11 /DPHASER_SHARED "/I$includeDirectory" $client `
        "/Fo$work\client_shared.obj" "/Fe$sharedClient" /link $importLibrary
    if ($LASTEXITCODE -ne 0) {
        Add-Failure 'C client did not build against the shared library'
    } else {
        # The loader finds phaser.dll beside the executable.
        Copy-Item -LiteralPath $sharedLibrary -Destination $work
        & $sharedClient
        if ($LASTEXITCODE -ne 0) { Add-Failure 'C client failed against the shared library' }
    }

    # -----------------------------------------------------------------------
    # 3. The DLL exports exactly the documented public symbol set.
    #
    #    PE exports carry no underscore decoration on x64, so the names come out
    #    as written. dumpbin's table has a header and a footer around the rows.
    # -----------------------------------------------------------------------

    Write-Section 'Exported symbols match the allow-list'
    $dumpbin = & dumpbin.exe /nologo /exports $sharedLibrary
    $exported = @()
    foreach ($line in $dumpbin) {
        # Rows look like: "    1    0 00001000 phaser_abi_version"
        if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)$') {
            $exported += $Matches[1]
        }
    }
    $exported = $exported | Sort-Object -Unique

    $allowed = Get-Content -LiteralPath $allowList |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' } |
        ForEach-Object { $_.Trim() } |
        Sort-Object -Unique

    $missing = $allowed | Where-Object { $exported -notcontains $_ }
    $extra = $exported | Where-Object { $allowed -notcontains $_ }

    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        Write-Host "exported symbols do not match $allowList"
        foreach ($symbol in $missing) { Write-Host "  documented but not exported: $symbol" }
        foreach ($symbol in $extra) { Write-Host "  exported but not documented: $symbol" }
        Add-Failure 'symbol allow-list mismatch'
    } else {
        Write-Host "exports exactly $($allowed.Count) documented symbols"
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) ABI check(s) failed"
    exit 1
}

Write-Host "`nall ABI checks passed"
