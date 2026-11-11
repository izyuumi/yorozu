# Builds, tests and installs the Windows app (spec section 10.3). Run on Windows:
#   pwsh apps/windows/ci/app.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Set-Location (Join-Path $PSScriptRoot '..')

# Runs a native command and fails the script when it exits non-zero.
function Invoke-Native([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "failed with exit code ${LASTEXITCODE}: $Command"
    }
}

# Starts the app with --smoke and requires exit code 0 and "ready 0.1.0" in the file.
function Test-Smoke([string]$Exe, [string]$File) {
    Remove-Item $File -ErrorAction SilentlyContinue
    $p = Start-Process $Exe -ArgumentList '--smoke', $File -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        throw "$Exe --smoke exited with code $($p.ExitCode)"
    }
    $text = (Get-Content -Raw $File).Trim()
    if ($text -ne 'ready 0.1.0') {
        throw "$Exe --smoke wrote '$text', not 'ready 0.1.0'"
    }
}

$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$setup = 'target\release\bundle\nsis\Yorozu_0.1.0_x64-setup.exe'

Write-Host '== 1. UI'
Push-Location app
Invoke-Native { pnpm install --frozen-lockfile }
Invoke-Native { pnpm build }
Pop-Location

Write-Host '== 2. tests'
Invoke-Native { cargo test --workspace --exclude yorozu-probe }

Write-Host '== 3. no plaintext key store in the app'
$tree = cargo tree -p yorozu-windows -e features | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "cargo tree failed with exit code $LASTEXITCODE"
}
if ($tree.Contains('insecure-plaintext-store')) {
    throw 'yorozu-windows depends on the insecure-plaintext-store feature; it must not'
}

Write-Host '== 4. installer'
Push-Location app
Invoke-Native { pnpm tauri build }
Pop-Location

Write-Host '== 5. the installer exists'
if (-not (Test-Path $setup -PathType Leaf)) {
    Get-ChildItem 'target\release\bundle' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host $_.FullName }
    throw "$setup was not built"
}

Write-Host '== 6. smoke run of the built app'
Test-Smoke 'target\release\yorozu.exe' (Join-Path $temp 'smoke.txt')

Write-Host '== 7. install, then smoke run of the installed app'
$p = Start-Process $setup -ArgumentList '/S' -Wait -PassThru
if ($p.ExitCode -ne 0) {
    throw "the installer exited with code $($p.ExitCode)"
}
$installed = Join-Path $env:LOCALAPPDATA 'Yorozu\yorozu.exe'
if (-not (Test-Path $installed -PathType Leaf)) {
    Get-ChildItem "$env:LOCALAPPDATA\Yorozu*", "$env:LOCALAPPDATA\Programs\*Yorozu*" -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host $_.FullName }
    throw "$installed was not installed"
}
Test-Smoke $installed (Join-Path $temp 'smoke-installed.txt')

Write-Host '== ok'
