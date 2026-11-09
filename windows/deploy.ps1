# deploy.ps1 - install claude-tools into C:\Program Files\claude-tools (ELEVATED).
#
#   Right-click PowerShell -> Run as administrator, then:
#   & "<repo>\windows\deploy.ps1"
#
# Why Program Files: the installed copies inherit its ACL (Administrators/SYSTEM
# full, Users read+execute), so the unelevated user - and Claude running as that
# user - can run the tools but cannot change, replace or delete them. Changes go
# through the repo: edit, review, commit, then run this again (that's also how
# upgrades work). Refuses to deploy uncommitted changes, and records the commit
# it deployed in VERSION.
#
# Layout:  <dst>\bin\     claude-secret, claude-secret.cmd, claude-secret.py, claude-tools.env, VERSION
#          <dst>\scripts\ tandoor-get.sh, tandoor-refresh-cache.sh
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated (Run as administrator) PowerShell.' }

$src  = $PSScriptRoot
$repo = Split-Path $src -Parent
$dst  = Join-Path $env:ProgramFiles 'claude-tools'
$conf = Join-Path $src 'claude-tools.env'
if (-not (Test-Path $conf)) { throw "Missing $conf - copy claude-tools.env.example and fill it in." }

# Only deploy committed code (the config file is gitignored, so it doesn't count)
$dirty = & git -C $repo status --porcelain -- windows
if ($LASTEXITCODE -ne 0) { throw 'git failed - is git on PATH in this elevated shell?' }
if ($dirty) { throw "Uncommitted changes under windows\ - commit (or stash) first:`n$($dirty -join "`n")" }
$version = (& git -C $repo log -1 --format='%h %cs %s') -join ''

$bin     = Join-Path $dst 'bin'
$scripts = Join-Path $dst 'scripts'
New-Item -ItemType Directory -Force $bin, $scripts | Out-Null

foreach ($f in 'claude-secret', 'claude-secret.cmd', 'claude-secret.py') {
    Copy-Item (Join-Path $src $f) $bin -Force
}
Copy-Item $conf $bin -Force
foreach ($f in 'tandoor-get.sh', 'tandoor-refresh-cache.sh') {
    Copy-Item (Join-Path $src $f) $scripts -Force
}
Set-Content -Path (Join-Path $bin 'VERSION') -Value $version -Encoding ascii

# Make sure nothing carries an explicit ACL: everything inherits Program Files'.
& icacls $dst /reset /T /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'icacls /reset failed' }

Write-Host "Deployed $version -> $dst"
Write-Host ''
Write-Host 'Access on the installed files (expect Users = read & execute only):'
(Get-Acl (Join-Path $bin 'claude-secret.py')).Access |
    Select-Object IdentityReference, FileSystemRights | Format-Table -AutoSize
