# deploy.ps1 - install claude-tools into C:\Program Files\claude-tools (ELEVATED).
#
#   First install, elevated PowerShell:   & "<repo>\windows\deploy.ps1"
#   Upgrades, elevated PowerShell:        & "C:\Program Files\claude-tools\deploy.ps1"
#
# Why Program Files: the installed copies inherit its ACL (Administrators/SYSTEM
# full, Users read+execute), so the unelevated user - and Claude running as that
# user - can run the tools but cannot change, replace or delete them.
#
# The repo itself IS writable by that user (and by Claude), so this script trusts
# only what you review here:
#  - upgrades run the INSTALLED deploy.ps1, which Claude can't edit; it finds the
#    repo via the admin-owned REPO file written at first install
#  - it shows the commits and diffstat since the installed VERSION and asks first
#  - it installs the committed tree (git archive HEAD), not the working tree
#  - git runs with fsmonitor/hooks/pager/external diff disabled, so repo config
#    can't run code elevated
#
# Layout:  <dst>\deploy.ps1, REPO
#          <dst>\bin\     claude-secret, claude-secret.cmd, claude-secret.py, claude-tools.env, VERSION
#          <dst>\scripts\ tandoor-get.sh, tandoor-refresh-cache.sh
param([string]$Repo)
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated (Run as administrator) PowerShell.' }

$dst      = Join-Path $env:ProgramFiles 'claude-tools'
$bin      = Join-Path $dst 'bin'
$scripts  = Join-Path $dst 'scripts'
$repoFile = Join-Path $dst 'REPO'
$verFile  = Join-Path $bin 'VERSION'

if (-not $Repo) {
    $parent = Split-Path $PSScriptRoot -Parent
    if (Test-Path (Join-Path $parent '.git')) {
        $Repo = $parent
        if (Test-Path $repoFile) {
            Write-Warning "Running the REPO copy of deploy.ps1. For upgrades run '$dst\deploy.ps1' instead - this copy is user-writable."
        }
    } elseif (Test-Path $repoFile) {
        $Repo = (Get-Content $repoFile -TotalCount 1).Trim()
    } else {
        throw 'Cannot find the repo - pass -Repo <path>.'
    }
}
if (-not (Test-Path (Join-Path $Repo '.git'))) { throw "$Repo is not a git checkout." }
$conf = Join-Path $Repo 'windows\claude-tools.env'
if (-not (Test-Path $conf)) { throw "Missing $conf - copy claude-tools.env.example and fill it in." }

function G {
    & git -C $Repo -c core.fsmonitor=false -c core.hooksPath=NUL -c core.pager=cat --no-pager @args
    if ($LASTEXITCODE -ne 0) { throw "git $args failed" }
}

# Only deploy committed code (the config file is gitignored, so it doesn't count)
$dirty = G status --porcelain -- windows
if ($dirty) { throw "Uncommitted changes under windows\ - commit (or stash) first:`n$($dirty -join "`n")" }
$version = (G log -1 --format='%h %cs %s') -join ''

Write-Host "Repo:        $Repo"
Write-Host "Installing:  $version"
$old = if (Test-Path $verFile) { ((Get-Content $verFile -TotalCount 1) -split ' ')[0] } else { '' }
$known = $false
if ($old) {   # --quiet: no stderr (PS 5.1 + Stop turns native stderr into a terminating error)
    $null = & git -C $Repo -c core.fsmonitor=false rev-parse --verify --quiet "$old^{commit}"
    $known = ($LASTEXITCODE -eq 0)
}
if ($known) {
    Write-Host "Installed:   $(Get-Content $verFile -TotalCount 1)"
    Write-Host 'Changes to windows\ since then:'
    G log --oneline "$old..HEAD" -- windows | ForEach-Object { "  $_" }
    G diff --no-ext-diff --no-textconv --stat $old HEAD -- windows | ForEach-Object { "  $_" }
} else {
    Write-Host "Installed:   $(if ($old) { $old } else { 'nothing recorded' }) (no diff available)"
}
$installedConf = Join-Path $bin 'claude-tools.env'
if ((Test-Path $installedConf) -and
    (Get-FileHash $installedConf).Hash -ne (Get-FileHash $conf).Hash) {
    Write-Host 'claude-tools.env changed:'
    Compare-Object (Get-Content $installedConf) (Get-Content $conf) |
        ForEach-Object { '  {0} {1}' -f $(if ($_.SideIndicator -eq '=>') { '+' } else { '-' }), $_.InputObject }
}
if ((Read-Host 'Deploy? [y/N]') -notmatch '^(y|yes)$') { throw 'Not deployed.' }

# Stage the committed tree (not the working tree) in an admin-only folder
$stage = Join-Path $dst '.staging'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage, $bin, $scripts | Out-Null
$zip = Join-Path $stage 'tree.zip'
G archive --format=zip -o $zip HEAD windows
Expand-Archive $zip -DestinationPath $stage
$w = Join-Path $stage 'windows'

foreach ($f in 'claude-secret', 'claude-secret.cmd', 'claude-secret.py') {
    Copy-Item (Join-Path $w $f) $bin -Force
}
foreach ($f in 'tandoor-get.sh', 'tandoor-refresh-cache.sh') {
    Copy-Item (Join-Path $w $f) $scripts -Force
}
Copy-Item (Join-Path $w 'deploy.ps1') $dst -Force
Copy-Item $conf $bin -Force
Remove-Item $stage -Recurse -Force
Set-Content -Path $verFile  -Value $version -Encoding ascii
Set-Content -Path $repoFile -Value (Resolve-Path $Repo).Path -Encoding ascii

# Make sure nothing carries an explicit ACL: everything inherits Program Files'.
& icacls $dst /reset /T /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'icacls /reset failed' }

Write-Host "Deployed $version -> $dst"
Write-Host ''
Write-Host 'Access on the installed files (expect Users = read & execute only):'
(Get-Acl (Join-Path $bin 'claude-secret.py')).Access |
    Select-Object IdentityReference, FileSystemRights | Format-Table -AutoSize
