#Requires -Version 5.1
<#
.SYNOPSIS
    Windows entry point for dev.sh.
    On macOS / Linux run:  ./dev.sh
    On Windows       run:  .\dev.ps1   (from PowerShell — recommended)
                      or:  dev          (from cmd.exe — delegates here automatically)

.DESCRIPTION
    Bootstraps a brand-new Windows machine end-to-end:
      1. Installs Git for Windows via winget   (provides Git Bash as a fallback)
      2. Installs WSL2 + Ubuntu                (the Linux runtime, same role as
                                                Apple Hypervisor VM on macOS)
      3. Waits for Ubuntu first-boot to complete
      4. Installs dev tools inside Ubuntu      (Node.js, Podman, podman-compose,
                                                cloudflared, git, python3)
      5. Re-execs dev.sh inside WSL2 Ubuntu    (from here, the Linux path takes
                                                over completely — identical to macOS)

    All steps are idempotent — safe to re-run at any time.

    FILE MAINTENANCE FAST-PATH
      Project commands declared in backend/project.py also skip bootstrap.
      .\dev.ps1 sync                Skip the full bootstrap.  WSL2 Ubuntu must
                                    already be installed (run .\dev.ps1 once
                                    first).  Only curl + python3 are verified.
      .\dev.ps1 sync --dry-run      Show what would change, no writes.
      .\dev.ps1 sync --yes          Auto-accept all changes (CI mode).
      .\dev.ps1 sync push           Push template files back for review.
      .\dev.ps1 sync push --dir <p> Use a different local clone path.
#>

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$DevArgs
)

$ErrorActionPreference = 'Stop'

function Start-ProjectLanListener {
    # Called only after an explicit `lan on`; ordinary startup stays loopback-only.
    $profile = Get-NetConnectionProfile | Where-Object {
        $_.IPv4Connectivity -ne 'Disconnected' -and $_.NetworkCategory -in @('Private', 'DomainAuthenticated')
    } | Select-Object -First 1
    if (-not $profile) { throw 'LAN access requires a trusted Private or Domain network. It was not enabled.' }
    $address = Get-NetIPAddress -InterfaceIndex $profile.InterfaceIndex -AddressFamily IPv4 | Where-Object {
        $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notlike '127.*'
    } | Select-Object -First 1
    if (-not $address) { throw 'No IPv4 address is available on the trusted network.' }
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $python) { throw 'Install native Python 3 to advertise .local names on the Windows network.' }
    $pythonPath = $python.Source
    $lanAddress = $address.IPAddress
    $alias = $profile.InterfaceAlias.Replace("'", "''")
    $program = $pythonPath.Replace("'", "''")
    $rule = "Devtools-LAN-$($profile.InterfaceIndex)"
    $rules = @"
`$ErrorActionPreference = 'Stop'
Get-NetFirewallRule -Name '$rule-HTTPS', '$rule-mDNS' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -Name '$rule-HTTPS' -DisplayName 'Project LAN HTTPS' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443 -LocalAddress '$lanAddress' -RemoteAddress LocalSubnet -Profile Private,Domain -InterfaceAlias '$alias' -Program '$program' | Out-Null
New-NetFirewallRule -Name '$rule-mDNS' -DisplayName 'Project LAN discovery' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 5353 -RemoteAddress LocalSubnet -Profile Private,Domain -InterfaceAlias '$alias' -Program '$program' | Out-Null
"@
    $upstream = ((wsl.exe -d Ubuntu --cd / -- hostname -I) -split '\s+')[0]
    if (-not $upstream) { throw 'WSL is unavailable; LAN access was not enabled.' }
    $stateDirectory = '\\wsl.localhost\Ubuntu\tmp\traefik-dynamic'
    $stateRoot = Join-Path $env:LOCALAPPDATA 'ProjectDevelopment'
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $pidFile = Join-Path $stateRoot 'lan-listener.json'
    $networkId = "$($profile.InterfaceIndex)|$($profile.Name)|$lanAddress"
    $running = $null
    if (Test-Path -LiteralPath $pidFile) {
        $old = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
        $running = Get-CimInstance Win32_Process -Filter "ProcessId=$($old.pid)" -ErrorAction SilentlyContinue
        if ($running -and $running.CommandLine -like '*config*network.py*serve*') {
            if ($old.address -eq $lanAddress -and $old.upstream -eq $upstream -and $old.network -eq $networkId) { return }
            Stop-Process -Id $old.pid -ErrorAction SilentlyContinue
        }
    }
    $encodedRules = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rules))
    $setup = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList "-NoProfile -EncodedCommand $encodedRules"
    if ($setup.ExitCode -ne 0) { throw 'LAN firewall setup was not completed.' }
    # A new sharing session opts in only the requested project. Stale opt-ins
    # from a previous network/reboot must not silently follow this computer.
    $selectedHost = (Get-Item $ROOT_DIR).Name.ToLowerInvariant() + '.local'
    foreach ($state in Get-ChildItem -LiteralPath $stateDirectory -Filter '*-lan.state') {
        $entry = Get-Content -LiteralPath $state.FullName -Raw | ConvertFrom-Json
        if ($entry.host -ne $selectedHost) {
            Remove-Item -LiteralPath $state.FullName
            $route = [IO.Path]::ChangeExtension($state.FullName, '.yml')
            if (Test-Path -LiteralPath $route) { Remove-Item -LiteralPath $route }
        }
    }
    $helper = Join-Path $ROOT_DIR 'backend\config\network.py'
    $stdout = Join-Path $stateRoot 'lan.log'
    $stderr = Join-Path $stateRoot 'lan-error.log'
    $listener = Start-Process -FilePath $pythonPath -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ArgumentList @(
        "`"$helper`"", 'serve', '--directory', "`"$stateDirectory`"", '--address', $lanAddress,
        '--network', "$lanAddress/$($address.PrefixLength)", '--upstream', $upstream
    )
    @{pid=$listener.Id; address=$lanAddress; upstream=$upstream; network=$networkId} | ConvertTo-Json | Set-Content -LiteralPath $pidFile
    Start-Sleep -Milliseconds 700
    if ($listener.HasExited) { throw "LAN listener could not start. See $stderr" }
    Write-Host "LAN enabled on $($profile.InterfaceAlias): $lanAddress. Trust the public local CA certificate on your phone." -ForegroundColor Green
}
if ($DevArgs.Count -gt 0 -and ($DevArgs[0] -eq 'watchos' -or
    ($DevArgs.Count -gt 2 -and $DevArgs[0] -eq 'build' -and $DevArgs[2] -eq 'watchos'))) {
    Write-Error 'watchOS builds and simulators require macOS and full Xcode. Run these commands on your Mac.'
    exit 1
}
$ROOT_DIR = $PSScriptRoot
if (-not $ROOT_DIR -or $ROOT_DIR -eq '') {
    $ROOT_DIR = Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path)
}

if ($DevArgs.Count -gt 0 -and $DevArgs[0] -eq 'lan' -and ($DevArgs.Count -eq 1 -or $DevArgs[1] -ne 'on')) {
    $nativePython = Get-Command python.exe -ErrorAction Stop
    $action = if ($DevArgs.Count -gt 1) { $DevArgs[1] } else { 'status' }
    if ($action -eq 'certificate') {
        $caRoot = (wsl.exe -d Ubuntu --cd / -- mkcert -CAROOT).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $caRoot.StartsWith('/')) { throw 'Start a project first to create its local HTTPS authority.' }
        $publicCA = '\\wsl.localhost\Ubuntu' + $caRoot.Replace('/', '\') + '\rootCA.pem'
        $destination = Join-Path $env:USERPROFILE 'Downloads\ProjectLocalCA.crt'
        Copy-Item -LiteralPath $publicCA -Destination $destination -Force
        Write-Host "Public CA certificate: $destination. Install and trust it on your phone; never share rootCA-key.pem."
        exit 0
    }
    & $nativePython.Source (Join-Path $ROOT_DIR 'backend\config\network.py') $action --root $ROOT_DIR --directory '\\wsl.localhost\Ubuntu\tmp\traefik-dynamic'
    exit $LASTEXITCODE
}

function _step { param($m) Write-Host "  >> $m" -ForegroundColor Cyan   }
function _ok   { param($m) Write-Host "  OK $m" -ForegroundColor Green  }
function _warn { param($m) Write-Host "  !! $m" -ForegroundColor Yellow }
function _fail { param($m) Write-Host "  XX $m" -ForegroundColor Red    }

# ── Helpers ───────────────────────────────────────────────────────────────────
function Test-UbuntuInstalled {
    try {
        $list = (wsl.exe --list --quiet 2>$null) -join '' -replace "`0", ''
        return $list -match 'Ubuntu'
    } catch { return $false }
}

function Get-WslPath {
    param([string]$WinPath)
    if ($script:WindowsSourceBridge -and $WinPath.TrimEnd('\') -eq $ROOT_DIR.TrimEnd('\')) {
        return $script:WindowsSourceBridge
    }
    # Forward slashes survive native argument passing in Windows PowerShell.
    $WinPath = $WinPath -replace '\\', '/'
    $wslPath = $null
    try {
        $wslPath = ((wsl.exe -d Ubuntu --cd / -- wslpath -a "$WinPath" 2>$null) -join '' -replace "`r", '').Trim()
    } catch {}
    if (-not $wslPath -or $wslPath -eq '') {
        $drive = $WinPath.Substring(0, 1).ToLower()
        $rest  = $WinPath.Substring(2) -replace '\\', '/'
        $wslPath = "/mnt/$drive$rest"
    }
    return $wslPath
}

function Ensure-WslSourceAccess {
    if (-not (Test-UbuntuInstalled)) { return }
    if (-not (Test-Path -LiteralPath (Join-Path $ROOT_DIR 'dev.sh'))) {
        throw 'The selected Windows project folder is unavailable.'
    }
    if ($script:WindowsSourceBridge) { return }
    $sourcePath = Get-WslPath $ROOT_DIR
    # Reading file contents catches EIO even when mount metadata looks healthy.
    $probe = "/tmp/devtools-source-probe-$PID.py"
    $probeWin = "\\wsl.localhost\Ubuntu\tmp\devtools-source-probe-$PID.py"
    $probeCode = "import sys`nfrom pathlib import Path`ntry:`n    for name in sys.argv[1:]:`n        Path(name).read_bytes()`nexcept OSError:`n    sys.exit(1)`n"
    [IO.File]::WriteAllText($probeWin, $probeCode, (New-Object Text.UTF8Encoding $false))
    $probeFiles = @("$sourcePath/dev.sh")
    if (Test-Path -LiteralPath (Join-Path $ROOT_DIR '.env')) { $probeFiles += "$sourcePath/.env" }
    try {
        wsl.exe -d Ubuntu -u root --cd / -- python3 $probe @probeFiles
        $sourceReadable = $LASTEXITCODE -eq 0
    } finally { Remove-Item -LiteralPath $probeWin -ErrorAction SilentlyContinue }
    if ($sourceReadable -and $env:DEV_WINDOWS_SOURCE_BRIDGE -ne '1') { return }

    # Windows reads its own checkout and writes through WSL's filesystem share.
    # No Linux Windows-drive mount or drive repair is required for this bridge.
    $leaf = ((Get-Item -LiteralPath $ROOT_DIR).Name -replace '[^a-zA-Z0-9._-]', '-').ToLowerInvariant()
    $bridge = "/tmp/devtools-windows-source-$leaf"
    $bridgeWin = "\\wsl.localhost\Ubuntu\tmp\devtools-windows-source-$leaf"
    $workerWin = Join-Path $env:TEMP "devtools-windows-source-$leaf.ps1"
    $quotedRoot = $ROOT_DIR.Replace("'", "''")
    $quotedBridge = $bridgeWin.Replace("'", "''")
    $worker = @"
param([switch]`$Once)
`$ErrorActionPreference = 'Stop'
`$source = '$quotedRoot'
`$target = '$quotedBridge'
function Read-EnvValues([string]`$content) {
    `$values = @{}
    foreach (`$match in [regex]::Matches(`$content, '(?m)^[ \t]*(?:export[ \t]+)?([A-Za-z_]\w*)[ \t]*=(.*)`$')) {
        `$values[`$match.Groups[1].Value] = `$match.Groups[2].Value.TrimEnd("``r")
    }
    return `$values
}
function Sync-Environment {
    `$nativePath = Join-Path `$source '.env'
    `$stagePath = Join-Path `$target '.env'
    if (-not (Test-Path -LiteralPath `$nativePath)) { return }
    `$nativeText = [IO.File]::ReadAllText(`$nativePath)
    `$native = Read-EnvValues `$nativeText
    if (`$script:lastEnv -and (Test-Path -LiteralPath `$stagePath)) {
        `$staged = Read-EnvValues ([IO.File]::ReadAllText(`$stagePath))
        `$lines = New-Object 'System.Collections.Generic.List[string]'
        foreach (`$line in (`$nativeText -split "``r?``n")) { `$lines.Add(`$line) }
        foreach (`$key in `$staged.Keys) {
            # Runtime updates may change only keys not concurrently edited on Windows.
            if (`$staged[`$key] -ne `$script:lastEnv[`$key] -and `$native[`$key] -eq `$script:lastEnv[`$key]) {
                `$replacement = `$key + '=' + `$staged[`$key]
                `$found = `$false
                for (`$i=0; `$i -lt `$lines.Count; `$i++) {
                    if (`$lines[`$i] -match ('^[ \t]*(?:export[ \t]+)?' + [regex]::Escape(`$key) + '[ \t]*=')) {
                        `$lines[`$i] = `$replacement; `$found = `$true; break
                    }
                }
                if (-not `$found) { `$lines.Add(`$replacement) }
            }
        }
        `$merged = (`$lines -join "``n")
        if (`$merged -ne `$nativeText) {
            [IO.File]::WriteAllText(`$nativePath, `$merged, (New-Object Text.UTF8Encoding `$false))
            `$nativeText = `$merged
        }
    }
    if (-not (Test-Path -LiteralPath `$stagePath) -or [IO.File]::ReadAllText(`$stagePath) -ne `$nativeText) {
        [IO.File]::WriteAllText(`$stagePath, `$nativeText, (New-Object Text.UTF8Encoding `$false))
    }
    `$script:lastEnv = Read-EnvValues `$nativeText
}
function Copy-Checkout {
    & robocopy.exe `$source `$target /MIR /FFT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XJ /XD node_modules .next .expo .metro-cache .gradle .cxx Pods build dist .venv venv __pycache__ "`$source\backend\media" "`$source\backend\config\staticfiles" /XF "`$source\.env" *.pyc snapshot_*.tar* backup_*.sql* backup_*.tar* .backup-* .dev-sync.lock .dev-sync.pid | Out-Null
    if (`$LASTEXITCODE -ge 8) { throw 'Windows could not copy the checkout into WSL.' }
}
if (`$Once) { Copy-Checkout; Sync-Environment; exit 0 }
`$script:lastEnv = Read-EnvValues ([IO.File]::ReadAllText((Join-Path `$source '.env')))
`$mutex = New-Object System.Threading.Mutex(`$false, 'Local\DevToolsSourceBridge-$leaf')
if (-not `$mutex.WaitOne(0)) { exit 0 }
try {
    while (`$true) {
        try { Sync-Environment; Copy-Checkout } catch { Start-Sleep -Seconds 5 }
        Start-Sleep -Seconds 3
    }
} finally { `$mutex.ReleaseMutex(); `$mutex.Dispose() }
"@
    # Replace a running worker so it uses the current environment merge logic.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($workerWin) -and $_.CommandLine -notmatch '-Once') {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    [System.IO.File]::WriteAllText($workerWin, $worker, (New-Object System.Text.UTF8Encoding $true))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $workerWin -Once
    if ($LASTEXITCODE -ne 0) { throw 'Could not refresh the Windows-to-WSL source bridge. Runtime data was preserved.' }
    Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerWin`""
    ) | Out-Null
    $script:WindowsOriginalSource = $sourcePath
    $script:WindowsSourceBridge = $bridge
    Write-Host 'Using the Windows-to-WSL source bridge; no Windows-drive mount is needed.'
}

function Build-ArgStr {
    param([string[]]$ArgList)
    return ($ArgList | ForEach-Object {
        if ($_ -match '\s') { "'$_'" } else { $_ }
    }) -join ' '
}

function Find-ScrcpyExecutable {
    $wingetPackages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $wingetPackages) {
        # Do not recursively scan every winget package; that can take minutes.
        $scrcpyPackages = Get-ChildItem $wingetPackages -Directory -Filter 'Genymobile.scrcpy*' -ErrorAction SilentlyContinue
        foreach ($package in $scrcpyPackages) {
            $match = Get-ChildItem $package.FullName -Recurse -Filter 'scrcpy.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($match) { return $match.FullName }
        }
    }

    $localTools = Join-Path $env:LOCALAPPDATA 'DevTools\scrcpy'
    if (Test-Path $localTools) {
        $match = Get-ChildItem $localTools -Recurse -Filter 'scrcpy.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($match) { return $match.FullName }
    }

    $command = Get-Command scrcpy -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Ensure-WSLPortForwarding {
    # Fix WSL2 port forwarding to localhost - only runs if needed and has admin rights
    if (-not (Test-UbuntuInstalled)) { return }

    $testConnection = $true
    foreach ($webPort in @(80, 443)) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $connect = $client.ConnectAsync('127.0.0.1', $webPort)
            if (-not ($connect.Wait(1500) -and $client.Connected)) {
                $testConnection = $false
            }
        } catch {
            $testConnection = $false
        } finally {
            $client.Dispose()
        }
    }

    # A stale portproxy can accept TCP connections while forwarding them to a
    # previous WSL address. Check its destination before trusting the listener.
    $wslIP = ((wsl.exe -d Ubuntu --cd / -- hostname -I 2>$null) -split '\s+')[0]
    if ($wslIP) {
        $forwarding = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp' -ErrorAction SilentlyContinue
        foreach ($webPort in @(80, 443)) {
            foreach ($listenAddress in @('127.0.0.1', '0.0.0.0')) {
                $rule = if ($forwarding) { $forwarding.PSObject.Properties["$listenAddress/$webPort"] } else { $null }
                if ($rule -and $rule.Value -ne "$wslIP/$webPort") {
                    $testConnection = $false
                }
            }
        }
    }

    # Only the repository-derived canonical hostname is registered.
    $projectFolder = (Get-Item $ROOT_DIR).Name
    $projectHost = ($projectFolder -replace '[^a-zA-Z0-9.-]', '').ToLowerInvariant() + '.local'
    $hostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
    $hostsContent = Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue
    $missingHosts = @(@($projectHost) | Select-Object -Unique | Where-Object {
        $aliasPattern = '^\s*127\.0\.0\.1\s+[^#]*\b' + [regex]::Escape($_) + '(\s|$)'
        -not ($hostsContent -match $aliasPattern)
    })
    $hasHostsEntry = $missingHosts.Count -eq 0
    $hostsEntry = "127.0.0.1 $($missingHosts -join ' ')"
    if ($testConnection -and $hasHostsEntry) { return }

    # Check if we're already running as admin
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        if (-not $hasHostsEntry) {
            Add-Content -LiteralPath $hostsPath -Value "`n$hostsEntry"
            _ok "Mapped https://$projectHost"
        }
        if ($testConnection) { return }
        # We have admin rights - fix port forwarding silently
        try {
            $wslIP = (wsl.exe -d Ubuntu --cd / -- hostname -I 2>$null).Split()[0].Trim()
            if ($wslIP) {
                # Remove any existing rule first
                netsh interface portproxy delete v4tov4 listenport=80 listenaddress=0.0.0.0 2>$null | Out-Null
                # Add the new rule
                netsh interface portproxy delete v4tov4 listenport=80 listenaddress=127.0.0.1 2>$null | Out-Null
                netsh interface portproxy add v4tov4 listenport=80 listenaddress=127.0.0.1 connectport=80 connectaddress=$wslIP 2>$null | Out-Null

                # Also add port 443 for HTTPS
                netsh interface portproxy delete v4tov4 listenport=443 listenaddress=0.0.0.0 2>$null | Out-Null
                netsh interface portproxy delete v4tov4 listenport=443 listenaddress=127.0.0.1 2>$null | Out-Null
                netsh interface portproxy add v4tov4 listenport=443 listenaddress=127.0.0.1 connectport=443 connectaddress=$wslIP 2>$null | Out-Null
            }
        } catch { }
    } else {
        if (-not $hasHostsEntry) {
            # Ask once for the smallest possible elevation: add only this
            # project's loopback name, then continue starting normally.
            $elevatedScript = "`$hosts = '$hostsPath'; `$entry = '$hostsEntry'; if (-not (Select-String -LiteralPath `$hosts -SimpleMatch `$entry -Quiet -ErrorAction SilentlyContinue)) { Add-Content -LiteralPath `$hosts -Value ([Environment]::NewLine + `$entry) }"
            $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevatedScript))
            Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -EncodedCommand $encodedScript" -ErrorAction SilentlyContinue
            _warn "Approve the one-time UAC prompt to map $($missingHosts -join ", ") locally."
        }
        if ($testConnection) { return }
        # Not admin - check if forwarding is needed
        try {
            # Try to connect to WSL IP directly
            $wslIP = (wsl.exe -d Ubuntu --cd / -- hostname -I 2>$null).Split()[0].Trim()
            if ($wslIP) {
                $client = New-Object System.Net.Sockets.TcpClient
                try {
                    $connect = $client.ConnectAsync($wslIP, 80)
                    $wslTest = $connect.Wait(1500) -and $client.Connected
                } finally {
                    $client.Dispose()
                }
                if ($wslTest -and -not $testConnection) {
                    # WSL is reachable but localhost isn't - offer to fix
                    Write-Host ""
                    _warn "Local HTTP/HTTPS forwarding is missing or points to a previous WSL address"
                    Write-Host ""
                    $response = Read-Host "  Fix port forwarding permanently? (requires admin) [Y/n]"
                    if ($response -ne 'n' -and $response -ne 'N') {
                        # Re-run this script with admin rights
                        $scriptPath = $MyInvocation.MyCommand.Path
                        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" $($DevArgs -join ' ')" -Verb RunAs
                        exit 0
                    }
                }
            }
        } catch { }
    }
}

function Install-Scrcpy {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        _step 'Installing scrcpy with winget...'
        & $winget.Source install --id Genymobile.scrcpy --silent --accept-package-agreements --accept-source-agreements
        $installed = Find-ScrcpyExecutable
        if ($installed) { return $installed }
        _warn 'winget did not make scrcpy available; trying the official release package.'
    } else {
        _warn 'winget is not installed; using the official scrcpy release package.'
    }

    $installRoot = Join-Path $env:LOCALAPPDATA 'DevTools\scrcpy'
    $zipPath = Join-Path $env:TEMP ("devtools-scrcpy-{0}.zip" -f $PID)

    try {
        _step 'Downloading scrcpy from the official Genymobile GitHub release...'
        $headers = @{ 'User-Agent' = 'DevTools-Script' }
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Genymobile/scrcpy/releases/latest' -Headers $headers
        $assetPattern = if ($env:PROCESSOR_ARCHITECTURE -match '^(ARM64|AMD64)$') {
            '^scrcpy-win64-v.*\.zip$'
        } else {
            '^scrcpy-win32-v.*\.zip$'
        }
        $asset = $release.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
        if (-not $asset) { throw 'No compatible Windows scrcpy package was found in the latest release.' }

        if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $zipPath -UseBasicParsing
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $installRoot -Force

        $installed = Find-ScrcpyExecutable
        if (-not $installed) { throw 'The downloaded package did not contain scrcpy.exe.' }
        _ok "scrcpy installed: $installed"
        return $installed
    } catch {
        _warn "Could not install scrcpy automatically: $($_.Exception.Message)"
        return $null
    } finally {
        if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
    }
}

# ── file maintenance fast-path ─────────────────────────────────────────────────────────────
# Sync and declared project commands skip the full tool bootstrap (podman, cloudflared,
# etc.) and goes directly to WSL2 with only the minimal tools sync needs
# (curl, python3, git, bash — all pre-installed in Ubuntu).
# This makes `.\dev.ps1 sync` as fast as possible: no package manager installs,
# no Podman machine startup, just WSL2 → bash dev.sh sync.
$isProjectCommand = $false
Ensure-WslSourceAccess

# Template sync must edit the actual Windows Git checkout, never a staging copy.
if ($script:WindowsSourceBridge -and $DevArgs.Count -gt 0 -and $DevArgs[0] -eq 'sync') {
    $nativePython = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $nativePython) { throw 'Template sync without a drive mount requires Windows Python 3.' }
    & $nativePython.Source (Join-Path $ROOT_DIR 'backend/config/project_config.py') $ROOT_DIR @DevArgs
    exit $LASTEXITCODE
}

if ($DevArgs.Count -gt 0 -and $DevArgs[0] -ne 'sync' -and (Test-UbuntuInstalled)) {
    $commandRoot = Get-WslPath $ROOT_DIR
    wsl.exe -d Ubuntu --cd / -- python3 "$commandRoot/backend/config/project_config.py" "$commandRoot" has-dev-command $DevArgs[0]
    $isProjectCommand = $LASTEXITCODE -eq 0
}
if ($DevArgs.Count -gt 0 -and ($DevArgs[0] -eq 'sync' -or $isProjectCommand)) {
    # 1. Verify WSL2 Ubuntu is ready
    if (-not (Test-UbuntuInstalled)) {
        _fail "WSL2 Ubuntu is not installed."
        _fail "Run  .\dev.ps1  first to do the one-time setup, then re-run  .\dev.ps1 $($DevArgs[0])"
        exit 1
    }

    # 2. Quick readiness check
    try {
        $out = (wsl.exe -d Ubuntu --cd / -- bash -c 'echo ready' 2>$null) -join ''
        if ($out -notmatch 'ready') { throw "not ready" }
    } catch {
        _fail "WSL2 Ubuntu is installed but not responding."
        _fail "Try:  wsl -d Ubuntu  to diagnose, then re-run  .\dev.ps1 $($DevArgs[0])"
        exit 1
    }

    # 3. Ensure minimal tools (curl + python3) are present — idempotent, fast
    $prereqScript = @'
command -v curl    &>/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq curl;    }
command -v python3 &>/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq python3; }
echo "  OK curl $(curl --version 2>/dev/null | head -1 | awk '{print $2}')"
echo "  OK python3 $(python3 --version 2>/dev/null)"
'@
    $tmpPrereq = "/tmp/devtools-prereq-$PID.sh"
    $tmpPrereqWin = "\\wsl.localhost\Ubuntu\tmp\devtools-prereq-$PID.sh"
    $prereqScriptUnix = $prereqScript -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($tmpPrereqWin, $prereqScriptUnix, (New-Object System.Text.UTF8Encoding $false))
    wsl.exe -d Ubuntu --cd / -- chmod +x $tmpPrereq
    wsl.exe -d Ubuntu --cd / -- bash $tmpPrereq
    $prereqExit = $LASTEXITCODE
    wsl.exe -d Ubuntu --cd / -- rm -f $tmpPrereq 2>$null | Out-Null
    if ($prereqExit -ne 0) {
        _warn "Prerequisite check had warnings (non-fatal, continuing...)"
    }

    # 4. Run file maintenance on the original checkout inside WSL2
    $wslRoot2 = Get-WslPath $ROOT_DIR
    $argStr2  = Build-ArgStr $DevArgs
    $tmpScript2    = "/tmp/devtools-sync-$PID.sh"
    $tmpScript2Win = "\\wsl.localhost\Ubuntu\tmp\devtools-sync-$PID.sh"
    $syncContent = "#!/bin/bash`nexport PATH=`"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:`$HOME/.local/bin`"`ncd '$wslRoot2'`nsed -i 's/\r//' dev.sh`nexec bash dev.sh $argStr2`n"
    [System.IO.File]::WriteAllText($tmpScript2Win, $syncContent, (New-Object System.Text.UTF8Encoding $false))
    wsl.exe -d Ubuntu --cd / -- chmod +x $tmpScript2
    wsl.exe -d Ubuntu --cd / -- bash $tmpScript2
    $syncExit = $LASTEXITCODE
    wsl.exe -d Ubuntu --cd / -- rm -f $tmpScript2 2>$null | Out-Null
    exit $syncExit
}

# ── full bootstrap (all other commands) ───────────────────────────────────────

# Quick check: if WSL2 Ubuntu is already working, skip the verbose bootstrap
$needsBootstrap = $false
$wslOk = Test-UbuntuInstalled

if (-not $wslOk) {
    $needsBootstrap = $true
} else {
    # Test if Ubuntu responds quickly
    try {
        $out = (wsl.exe -d Ubuntu --cd / -- bash -c 'echo ready' 2>$null) -join ''
        if ($out -notmatch 'ready') { $needsBootstrap = $true }
    } catch {
        $needsBootstrap = $true
    }
}

if ($needsBootstrap) {
    # Get project name dynamically from folder
    $PROJECT_NAME = (Get-Item $ROOT_DIR).Name
    Write-Host ""
    Write-Host "  $PROJECT_NAME Windows Bootstrap" -ForegroundColor Blue
    Write-Host ("  " + ("═" * ($PROJECT_NAME.Length + 20))) -ForegroundColor Blue
    Write-Host ""

    # ── 1. Git for Windows ────────────────────────────────────────────────────────
    # Git Bash is used as a fallback if someone runs bash dev.sh directly.
    # The main path (WSL2) doesn't need it, but it's a useful tool to have.
    $BASH = $null
    foreach ($p in @(
        "$env:PROGRAMFILES\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
        "C:\Program Files\Git\bin\bash.exe"
    )) { if (Test-Path $p) { $BASH = $p; break } }

    if (-not $BASH) {
        $fc = Get-Command bash.exe -ErrorAction SilentlyContinue
        if ($fc -and $fc.Source -notmatch 'System32') { $BASH = $fc.Source }
    }

    if (-not $BASH) {
        _step "Git for Windows not found — installing via winget..."

        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            _fail "winget not found. Install App Installer from the Microsoft Store,"
            _fail "then re-run:  .\dev.ps1"
            exit 1
        }

        winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements --scope machine 2>&1 | Out-Null

        # Refresh PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('PATH', 'User')

        foreach ($p in @(
            "$env:PROGRAMFILES\Git\bin\bash.exe",
            "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
            "C:\Program Files\Git\bin\bash.exe"
        )) { if (Test-Path $p) { $BASH = $p; break } }

        if ($BASH) { _ok "Git for Windows installed  ($BASH)" }
        else {
            _warn "Git installed but bash.exe not found in PATH yet."
            _warn "This is fine — WSL2 is the primary runtime. Continuing..."
        }
    } else {
        _ok "Git Bash: $BASH"
    }

    # ── 2. WSL2 + Ubuntu ─────────────────────────────────────────────────────────
    _step "Checking WSL2 + Ubuntu..."

    if (-not $wslOk) {
        _step "WSL2 + Ubuntu not found — installing (one-time, ~3-5 min)..."
        _step "A UAC prompt may appear — please accept it."
        Write-Host ""

        # Try without elevation first (works on Win11 22H2+ and Win10 builds with WSL2 pre-enabled)
        try {
            Start-Process wsl.exe -ArgumentList '--install -d Ubuntu --no-launch' -PassThru -Wait -WindowStyle Normal | Out-Null
        } catch {}

        # Wait up to 2 min
        $w = 0
        while ($w -lt 120) {
            Start-Sleep 5; $w += 5
            if (Test-UbuntuInstalled) { $wslOk = $true; break }
            if ($w % 30 -eq 0) { _step "  Still installing WSL2... ($w s)" }
        }

        # Retry with elevation if still not registered
        if (-not $wslOk) {
            _step "Retrying with elevated privileges..."
            try {
                Start-Process powershell.exe `
                    -ArgumentList '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "wsl --install -d Ubuntu --no-launch"' `
                    -Verb RunAs -PassThru -Wait -WindowStyle Normal | Out-Null
            } catch {
                _warn "UAC was denied. Run this in an Administrator PowerShell, then restart your PC:"
                _warn "   wsl --install -d Ubuntu"
                _warn "After restart, re-run:  .\dev.ps1"
                exit 1
            }
            $w = 0
            while ($w -lt 180) {
                Start-Sleep 5; $w += 5
                if (Test-UbuntuInstalled) { $wslOk = $true; break }
                if ($w % 30 -eq 0) { _step "  Still waiting for Ubuntu... ($w s)" }
            }
        }

        if (-not $wslOk) {
            _warn "Ubuntu did not appear after install. A reboot may be needed."
            _warn "Restart your PC, then re-run:  .\dev.ps1"
            exit 1
        }
        _ok "WSL2 + Ubuntu installed"
    } else {
        _ok "WSL2 Ubuntu ready"
    }

    # ── 3. Ubuntu first-boot ──────────────────────────────────────────────────────
    # A freshly installed distro may still be extracting its rootfs (~30 s).
    _step "Waiting for Ubuntu to respond..."
    $ready = $false; $w = 0
    while ($w -lt 240) {
        try {
            $out = (wsl.exe -d Ubuntu --cd / -- bash -c 'echo ready' 2>$null) -join ''
            if ($out -match 'ready') { $ready = $true; break }
        } catch {}
        Start-Sleep 5; $w += 5
        if ($w % 30 -eq 0) { _step "  Still initialising Ubuntu... ($w s)" }
    }

    if (-not $ready) {
        # Ubuntu may be waiting on an interactive first-launch password dialog.
        # Set root as default user so it runs unattended.
        _step "Setting Ubuntu default user to root (unattended mode)..."
        try { ubuntu.exe config --default-user root 2>$null } catch {}
        wsl.exe --terminate Ubuntu 2>$null | Out-Null
        Start-Sleep 3
        try {
            $out = (wsl.exe -d Ubuntu --cd / -- bash -c 'echo ready' 2>$null) -join ''
            $ready = $out -match 'ready'
        } catch {}
    }

    if (-not $ready) {
        _fail "Ubuntu is installed but won't respond."
        _fail "Open a terminal and run:  wsl -d Ubuntu"
        _fail "Complete the first-launch setup, then re-run:  .\dev.ps1"
        exit 1
    }
    _ok "Ubuntu ready"

    # ── 4. Bootstrap tools inside Ubuntu (idempotent) ────────────────────────────
    _step "Checking/installing dev tools inside Ubuntu..."
    Write-Host ""

$bootstrapScript = @'
set -e
export DEBIAN_FRONTEND=noninteractive

_need() {
  local MISSING=""
  for pkg in "$@"; do
    dpkg -s "$pkg" &>/dev/null || MISSING="$MISSING $pkg"
  done
  [ -z "$MISSING" ] && return 0
  sudo apt-get update -qq
  sudo apt-get install -y -qq $MISSING
}

# Core utilities
_need curl ca-certificates gnupg git python3 rsync

# Node.js LTS (via NodeSource)
if ! command -v node &>/dev/null; then
  echo "  >> Installing Node.js LTS..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - 2>/dev/null
  sudo apt-get install -y -qq nodejs
  echo "  OK Node.js $(node --version)"
else
  echo "  OK Node.js $(node --version)"
fi

# Podman
if ! command -v podman &>/dev/null; then
  echo "  >> Installing Podman..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq podman 2>/dev/null || {
    curl -fsSL https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/unstable/xUbuntu_22.04/Release.key \
      | sudo gpg --dearmor -o /usr/share/keyrings/podman.gpg
    echo "deb [signed-by=/usr/share/keyrings/podman.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/unstable/xUbuntu_22.04 /" \
      | sudo tee /etc/apt/sources.list.d/podman.list
    sudo apt-get update -qq && sudo apt-get install -y -qq podman
  }
  echo "  OK Podman $(podman --version)"
else
  echo "  OK Podman $(podman --version)"
fi

# podman-compose
if ! command -v podman-compose &>/dev/null; then
  echo "  >> Installing podman-compose..."
  # Ubuntu 24.04+ uses PEP 668 — pip install requires --break-system-packages
  # or pipx. We try pipx first (cleanest), fall back to pip with the flag.
  if ! command -v pipx &>/dev/null; then
    sudo apt-get install -y -qq pipx 2>/dev/null || true
  fi
  if command -v pipx &>/dev/null; then
    pipx install podman-compose 2>/dev/null && export PATH="$HOME/.local/bin:$PATH" || true
  fi
  if ! command -v podman-compose &>/dev/null; then
    pip3 install --user --break-system-packages -q podman-compose 2>/dev/null \
      || pip3 install --user -q podman-compose 2>/dev/null || true
  fi
  export PATH="$HOME/.local/bin:$PATH"
  echo "  OK podman-compose installed"
else
  echo "  OK podman-compose ready"
fi

# Podman: add Docker Hub as default unqualified search registry
# Without this, short image names like "postgres:17" or "redis:7-alpine" fail
# with "did not resolve to an alias and no unqualified-search registries defined"
sudo mkdir -p /etc/containers/registries.conf.d
if ! grep -q 'docker.io' /etc/containers/registries.conf.d/docker.conf 2>/dev/null; then
  echo 'unqualified-search-registries = ["docker.io"]' \
    | sudo tee /etc/containers/registries.conf.d/docker.conf >/dev/null
  echo "  OK Podman registry configured (docker.io)"
fi

# cloudflared
if ! command -v cloudflared &>/dev/null; then
  echo "  >> Installing cloudflared..."
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared jammy main" \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq cloudflared 2>/dev/null || true
  echo "  OK cloudflared installed"
else
  echo "  OK cloudflared ready"
fi

echo ""
echo "  OK All tools ready inside Ubuntu"
'@

    # Write bootstrap script to temp file with Unix line endings to avoid bash parse errors
    $tmpBootstrap = "/tmp/devtools-bootstrap-$PID.sh"
    $tmpBootstrapWin = "\\wsl.localhost\Ubuntu\tmp\devtools-bootstrap-$PID.sh"
    # Convert CRLF to LF before writing
    $bootstrapScriptUnix = $bootstrapScript -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($tmpBootstrapWin, $bootstrapScriptUnix, (New-Object System.Text.UTF8Encoding $false))
    wsl.exe -d Ubuntu --cd / -- chmod +x $tmpBootstrap
    wsl.exe -d Ubuntu --cd / -- bash $tmpBootstrap
    $bootstrapExit = $LASTEXITCODE
    wsl.exe -d Ubuntu --cd / -- rm -f $tmpBootstrap 2>$null | Out-Null
    if ($bootstrapExit -ne 0) {
        _warn "Tool bootstrap had errors (non-fatal — will retry next run)"
    }

    Write-Host ""
}

# Cloud builds need the original Git checkout for EAS's project archive.
# The container mirror intentionally excludes .git; it is for local services.
if ($DevArgs.Count -gt 1 -and $DevArgs[0] -eq 'build' -and $DevArgs -notcontains 'local') {
    $cloudRoot = Get-WslPath $ROOT_DIR
    $cloudArgs = Build-ArgStr $DevArgs
    $cloudScript = "/tmp/devtools-cloud-build-$PID.sh"
    $cloudScriptWin = "\\wsl.localhost\Ubuntu\tmp\devtools-cloud-build-$PID.sh"
    $cloudContent = "#!/bin/bash`nexport PATH=`"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:`$HOME/.local/bin`"`ncd '$cloudRoot'`nsed -i 's/\r//' dev.sh`nexec bash dev.sh $cloudArgs`n"
    [System.IO.File]::WriteAllText($cloudScriptWin, $cloudContent, (New-Object System.Text.UTF8Encoding $false))
    try {
        wsl.exe -d Ubuntu --cd / -- bash $cloudScript
        $cloudExit = $LASTEXITCODE
    } finally {
        wsl.exe -d Ubuntu --cd / -- rm -f $cloudScript 2>$null | Out-Null
    }
    exit $cloudExit
}

Ensure-WslSourceAccess

# ── Fix WSL2 port forwarding if needed ────────────────────────────────────────
Ensure-WSLPortForwarding

# Trust the existing local authority before the long-running terminal monitor.
$caRoot = (wsl.exe -d Ubuntu --cd / -- mkcert -CAROOT 2>$null).Trim()
if ($caRoot -and $caRoot.StartsWith('/')) {
    $publicCA = '\\wsl.localhost\Ubuntu' + $caRoot.Replace('/', '\') + '\rootCA.pem'
    if (Test-Path -LiteralPath $publicCA) {
        Import-Certificate -FilePath $publicCA -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    }
}

# ── 5. Mirror the Windows workspace into WSL and hand off ───────────────────
# Podman running inside WSL cannot reliably bind-mount files from C:\.  The
# failure presents as EIO scandir/stat errors in Next and Django, leaving both
# frontend and backend dead.  Run containers from a native WSL mirror instead,
# and keep that mirror refreshed in the background while the launcher runs.
$wslRoot = Get-WslPath $ROOT_DIR
$sourceIdentity = if ($script:WindowsOriginalSource) { $script:WindowsOriginalSource } else { $wslRoot }
$workspaceLeaf = ((Get-Item $ROOT_DIR).Name -replace '[^a-zA-Z0-9._-]', '-').ToLowerInvariant()
$wslWorkspace = "/root/.codex-workspaces/$workspaceLeaf"
$argStr = Build-ArgStr $DevArgs

# Write the command to a temp script to avoid PowerShell quoting issues.
# Use [IO.File]::WriteAllText with explicit LF endings — piping through
# PowerShell adds CRLF which bash misparsed, mangling the argument list.
$tmpScript = "/tmp/devtools-run-$PID.sh"
$tmpScriptWin = "\\wsl.localhost\Ubuntu\tmp\devtools-run-$PID.sh"
$bashContent = @"
#!/bin/bash
set -e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:`$HOME/.local/bin"
SOURCE_DIR='$wslRoot'
WORKSPACE_DIR='$wslWorkspace'
export DEV_SOURCE_DIR='$wslRoot'
export DEV_CHECKOUT_DIR='$sourceIdentity'
SYNC_PID_FILE="/tmp/devtools-sync-$workspaceLeaf.pid"
mkdir -p "`$WORKSPACE_DIR"

sync_runtime_env() {
  local source="`$1"
  local target="`$2"
  [[ ! -f "`$source" ]] && return
  python3 -c '
import re, sys
from pathlib import Path

def merge(source, runtime):
    values = dict(line.split("=", 1) for line in runtime.splitlines()
                  if "=" in line and not line.startswith("#"))
    source_values = dict(line.split("=", 1) for line in source.splitlines()
                         if "=" in line and not line.startswith("#"))
    if source_values.get("CLOUDFLARE_TUNNEL_TOKEN", "").strip():
        return source
    retained = {key: value for key, value in values.items()
                if re.fullmatch(r"CLOUDFLARE_TUNNEL_URL|METRO_TUNNEL_URL_\d+", key)
                and re.fullmatch(r"https://[a-z0-9-]+\.trycloudflare\.com/?", value)}
    lines = []
    for line in source.splitlines():
        key = line.partition("=")[0]
        lines.append(f"{key}={retained.pop(key)}" if key in retained else line)
    lines.extend(f"{key}={value}" for key, value in retained.items())
    return "\n".join(lines) + "\n"

source, target = map(Path, sys.argv[1:])
if source.exists():
    target.write_text(merge(source.read_text(), target.read_text() if target.exists() else ""))
' "`$source" "`$target"
}

sync_workspace() {
  local keep_runtime_env="`$1"
  if [[ "`$keep_runtime_env" != "live" ]]; then
    sync_runtime_env "`$SOURCE_DIR/.env" "`$WORKSPACE_DIR/.env"
  fi
  rsync -a --delete \
    --exclude '.git/' --exclude 'node_modules/' --exclude '.next/' \
    --exclude '.expo/' --exclude '.metro-cache/' --exclude '.gradle/' \
    --exclude '.cxx/' --exclude 'Pods/' --exclude 'build/' --exclude 'dist/' \
    --exclude '.venv/' --exclude 'venv/' --exclude '__pycache__/' --exclude '*.pyc' \
    --exclude 'backend/media/' --exclude 'backend/config/staticfiles/' \
    --exclude 'backend/backup/snapshot_*' --exclude 'backend/backup/backup_*' \
    --exclude 'backend/backup/.backup-*' --exclude 'backend/backup/*.log' \
    --exclude '/.env' --exclude '/.dev-sync.lock' --exclude '/.dev-sync.pid' \
    "`$SOURCE_DIR/" "`$WORKSPACE_DIR/"
}

if [[ "`${1:-}" == "_sync-only" ]]; then
  # Stop the live copier before the initial rsync; concurrent --delete passes
  # can remove each other's temporary files. Restart it after preparation.
  WORKER_PID="`$(cat "`$WORKSPACE_DIR/.dev-sync.pid" 2>/dev/null || true)"
  if [[ "`$WORKER_PID" =~ ^[0-9]+`$ ]] && [[ "`$(ps -p "`$WORKER_PID" -o args=)" == *"_workspace-sync"*"`$WORKSPACE_DIR"* ]]; then
    kill -TERM "`$WORKER_PID" 2>/dev/null || true
    for attempt in {1..50}; do
      kill -0 "`$WORKER_PID" 2>/dev/null || break
      sleep 0.1
    done
  fi
  sync_workspace
  sed -i 's/\r//' "`$WORKSPACE_DIR/dev.sh"
  exit 0
fi

cd "`$WORKSPACE_DIR"
exec bash dev.sh $argStr
"@
# Convert CRLF to LF before writing
$bashContentUnix = $bashContent -replace "`r`n", "`n" -replace "`r", "`n"
[System.IO.File]::WriteAllText($tmpScriptWin, $bashContentUnix, (New-Object System.Text.UTF8Encoding $false))
wsl.exe -d Ubuntu --cd / -- chmod +x $tmpScript
# A Linux-detached worker can outlive its wsl.exe bridge and retain a broken
# Windows drive mount (EIO). Keep its own Windows WSL invocation alive instead.
# The worker's flock prevents duplicates when the launcher is run again.
wsl.exe -d Ubuntu --cd / -- bash $tmpScript _sync-only
if ($LASTEXITCODE -ne 0) {
    Ensure-WslSourceAccess
    wsl.exe -d Ubuntu --cd / -- bash $tmpScript _sync-only
    if ($LASTEXITCODE -ne 0) { throw 'Could not refresh the WSL development workspace after source-drive recovery.' }
}
Start-Process -FilePath (Get-Command wsl.exe).Source -WindowStyle Hidden -ArgumentList @(
    '-d', 'Ubuntu', '--cd', '/', '--', 'bash', "`"$wslWorkspace/dev.sh`"", '_workspace-sync',
    "`"$wslRoot`"", "`"$wslWorkspace`""
) | Out-Null
# A local terminal link can enable LAN through this native host without asking
# WSL to access an unavailable Windows-drive mount. No sharing occurs at startup.
$lanControlProcess = $null
$lanControlDirectory = ''
$lanControlLinuxState = ''
$lanControlWindowsDirectory = ''
if ($DevArgs.Count -eq 0 -or $DevArgs[0] -in @('status', 'monitor', 'up', 'start', 'restart')) {
    $nativePython = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($nativePython) {
        $lanControlDirectory = ((wsl.exe -d Ubuntu --cd / -- mktemp -d /tmp/devtools-lan-control-XXXXXX) -join '').Trim()
        if ($LASTEXITCODE -eq 0 -and $lanControlDirectory -match '^/tmp/devtools-lan-control-[a-zA-Z0-9]+$') {
            $lanControlLinuxState = "$lanControlDirectory/control.json"
            $lanControlWindowsDirectory = '\\wsl.localhost\Ubuntu' + $lanControlDirectory.Replace('/', '\')
            $controlHelper = Join-Path $ROOT_DIR 'backend\config\network.py'
            $controlState = Join-Path $lanControlWindowsDirectory 'control.json'
            $lanControlProcess = Start-Process -FilePath $nativePython.Source -WindowStyle Hidden -PassThru -ArgumentList @(
                "`"$controlHelper`"", 'monitor', '--root', "`"$ROOT_DIR`"",
                '--directory', '"\\wsl.localhost\Ubuntu\tmp\traefik-dynamic"', '--control-state', "`"$controlState`""
            ) -RedirectStandardOutput (Join-Path $lanControlWindowsDirectory 'control.log') -RedirectStandardError (Join-Path $lanControlWindowsDirectory 'control-error.log')
            for ($attempt = 0; $attempt -lt 20 -and -not (Test-Path -LiteralPath $controlState); $attempt++) {
                Start-Sleep -Milliseconds 100
            }
        }
    }
}

try {
    wsl.exe -d Ubuntu --cd / -- env "DEV_LAN_CONTROL_STATE=$lanControlLinuxState" bash $tmpScript
    $devShExitCode = $LASTEXITCODE
} finally {
    if ($lanControlProcess -and -not $lanControlProcess.HasExited) {
        Stop-Process -Id $lanControlProcess.Id -ErrorAction SilentlyContinue
    }
    if ($lanControlWindowsDirectory) {
        foreach ($file in @('control.json', 'control.log', 'control-error.log')) {
            Remove-Item -LiteralPath (Join-Path $lanControlWindowsDirectory $file) -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $lanControlWindowsDirectory -ErrorAction SilentlyContinue
    }
}
wsl.exe -d Ubuntu --cd / -- rm -f $tmpScript 2>$null | Out-Null


if ($devShExitCode -eq 0 -and $DevArgs.Count -gt 1 -and $DevArgs[0] -eq 'lan' -and $DevArgs[1] -eq 'on') {
    try { Start-ProjectLanListener }
    catch {
        # Fail closed when discovery, firewall consent or listener setup fails.
        wsl.exe -d Ubuntu --cd / -- python3 "$wslWorkspace/backend/config/network.py" off --root $wslWorkspace
        throw
    }
}

# ── Android: open emulator screen via scrcpy ─────────────────────────────────
if ($DevArgs.Count -gt 0 -and $DevArgs[0] -eq 'android') {
    Write-Host ""
    Write-Host "  >> Opening emulator window..." -ForegroundColor Cyan

    # Derive the window label from this checkout; quote for the WSL shell.
    $emulatorTitle = (Get-Item -LiteralPath $ROOT_DIR).Name + ' Emulator'
    $quotedTitle = "'" + $emulatorTitle.Replace("'", "'\''") + "'"
    # Launch scrcpy from WSL using WSLg to display the emulator
    Start-Process wsl -ArgumentList "-d", "Ubuntu", "--", "bash", "-c", "export DISPLAY=:0; scrcpy --serial=emulator-5554 --max-size=1024 --window-title=$quotedTitle" -WindowStyle Hidden

    Start-Sleep 3

    Write-Host ""
    Write-Host "  =================================================================" -ForegroundColor Green
    Write-Host "  ✅ EMULATOR WINDOW IS OPENING!" -ForegroundColor Green
    Write-Host "  =================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Look for a window titled '$emulatorTitle'" -ForegroundColor Cyan
    Write-Host "  (It may take 10-15 seconds to appear)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  📱 The project apps are installed and ready!" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  📊 Connected to:" -ForegroundColor Yellow
    Write-Host "    • Metro bundler: http://10.0.2.2:8081" -ForegroundColor White
    Write-Host "    • Backend API: http://10.0.2.2:8000" -ForegroundColor White
    Write-Host ""
    Write-Host "  💡 Tip: Use your mouse and keyboard to interact with the emulator" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  🎉 Happy testing!" -ForegroundColor Green
    Write-Host ""
}

# Metro is managed once by dev.sh in containers.
exit $devShExitCode
