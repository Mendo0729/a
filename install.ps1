# holos-agent installer for Windows Server 2012+ (x64)
#
# Mode 1 — PULSE token (recommended):
#   irm https://releases.holos.tech/install.ps1 | iex
#   (or with parameters:)
#   & ([scriptblock]::Create((irm https://releases.holos.tech/install.ps1))) -Token tok_Ax7kP...
#
# Mode 2 — direct parameters:
#   & ([scriptblock]::Create((irm https://releases.holos.tech/install.ps1))) `
#       -TenantId acme-prod -ApiKey sk-live-xxx
#
# Environments:
#   -Environment prod  (default) → collector.holos.tech        production pipeline
#   -Environment dev             → collector.dev.holos.tech    development / QA pipeline
#
# Override endpoint manually (takes precedence over -Environment):
#   ... -Endpoint https://my-collector.internal
#
# HTTP/HTTPS proxy (for servers without direct internet access):
#   ... -Proxy http://10.20.0.2:3128
#
# Once installed, detect services on this host with:
#   holos-agent discover
#
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Token          = $env:HOLOS_INSTALL_TOKEN,
    [string]$TenantId       = $env:HOLOS_TENANT_ID,
    [string]$ApiKey         = $env:HOLOS_API_KEY,
    [string]$CollectorToken = $env:HOLOS_COLLECTOR_TOKEN,
    [string]$Endpoint       = $env:HOLOS_ENDPOINT,
    [string]$Environment    = "prod",
    [string]$Site           = $env:HOLOS_SITE,
    [string]$Proxy          = $(if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $env:HTTP_PROXY } else { "" }),
    [string]$LocalBinary    = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── PowerShell version check ──────────────────────────────────────────────────
if ($PSVersionTable.PSVersion.Major -lt 4) {
    Write-Host "[error] PowerShell 4.0 or later is required." -ForegroundColor Red
    Write-Host "        Download WMF 5.1: https://www.microsoft.com/en-us/download/details.aspx?id=54616" -ForegroundColor Yellow
    exit 1
}

# ── Force TLS 1.2 (required on Windows Server 2012 / PowerShell 4) ───────────
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Constants ─────────────────────────────────────────────────────────────────
$ServiceName  = 'HolosAgent'
$DisplayName  = 'Holos Agent - PULSE telemetry collector'
$InstallDir   = 'C:\Program Files\Holos\Agent'
$ConfigDir    = 'C:\ProgramData\Holos\Agent'
$BinaryName   = 'holos-agent.exe'
$PulseApi     = if ($env:HOLOS_API_URL)     { $env:HOLOS_API_URL }     else { 'https://api.holos.tech' }
$ReleaseBase  = if ($env:HOLOS_RELEASE_URL) { $env:HOLOS_RELEASE_URL } else { 'https://releases.holos.tech' }
$EndpointProd = 'https://collector.holos.tech'
$EndpointDev  = 'https://collector.dev.holos.tech'
$BinaryUrl    = "$ReleaseBase/holos-agent-windows-amd64.exe"
$BinaryPath   = Join-Path $InstallDir $BinaryName
$ConfigPath   = Join-Path $ConfigDir  'config.yaml'
$EnvPath      = Join-Path $ConfigDir  'agent.env'

# ── Helpers ──────────────────────────────────────────────────────────────────
function Step { param($msg) Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok   { param($msg) Write-Host " v  $msg" -ForegroundColor Green }
function Warn { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Die  { param($msg) Write-Host "[error] $msg" -ForegroundColor Red; exit 1 }

# ── Argument validation ───────────────────────────────────────────────────────
if (-not $Token -and -not $TenantId) {
    Die "Either -Token or -TenantId is required. Example: ... -Token tok_Ax7kP..."
}
if ($TenantId -and -not $ApiKey) { Die "If you use -TenantId you must also provide -ApiKey." }

# Resolve endpoint: explicit -Endpoint wins, then -Environment, then prod default
if (-not $Endpoint) {
    switch ($Environment) {
        'dev'  { $Endpoint = $EndpointDev }
        'prod' { $Endpoint = $EndpointProd }
        default { Die "Unknown -Environment value: '$Environment'. Valid values: prod, dev" }
    }
}

# ── Fetch credentials from PULSE (-Token mode) ───────────────────────────────
if ($Token) {
    Step "Fetching credentials from PULSE..."
    try {
        $irmParams = @{ Uri = "$PulseApi/api/v1/install-credentials?token=$Token"; Method = 'Get'; TimeoutSec = 15 }
        if ($Proxy) { $irmParams['Proxy'] = $Proxy; $irmParams['ProxyUseDefaultCredentials'] = $false }
        $resp           = Invoke-RestMethod @irmParams
        $TenantId       = $resp.tenant_id
        $ApiKey         = $resp.api_key
        $Endpoint       = $resp.endpoint
        $CollectorToken = $resp.collector_token
    } catch {
        Die "Could not connect to the PULSE API ($PulseApi). Check your connection and token."
    }
    if (-not $TenantId) { Die "Invalid or expired token. Get a new token from the PULSE portal." }
    Ok "Credentials obtained for tenant: $TenantId"
}

if (-not $Site) { $Site = $env:COMPUTERNAME }

Write-Host ""
Write-Host "holos-agent installer" -ForegroundColor White
Write-Host "  Tenant  : $TenantId"
Write-Host "  Site    : $Site"
Write-Host "  Env     : $Environment"
Write-Host "  Endpoint: $Endpoint"
Write-Host ""

# ── Create directories ────────────────────────────────────────────────────────
Step "Setting up directories..."
foreach ($dir in @($InstallDir, $ConfigDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}
Ok "Directories ready: $InstallDir | $ConfigDir"

# ── Stop existing service (upgrade) ──────────────────────────────────────────
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService -and $existingService.Status -eq 'Running') {
    Step "Stopping existing service for upgrade..."
    Stop-Service -Name $ServiceName -Force
    Start-Sleep -Seconds 2
    Ok "Service stopped"
}

# ── Install binary ────────────────────────────────────────────────────────────
if ($LocalBinary) {
    Step "Installing local binary: $LocalBinary"
    if (-not (Test-Path $LocalBinary)) { Die "Binary not found: $LocalBinary" }
    Copy-Item -Path $LocalBinary -Destination $BinaryPath -Force
} else {
    Step "Downloading holos-agent (windows/amd64)..."
    try {
        $iwrParams = @{ Uri = $BinaryUrl; OutFile = "$BinaryPath.new"; UseBasicParsing = $true }
        if ($Proxy) { $iwrParams['Proxy'] = $Proxy; $iwrParams['ProxyUseDefaultCredentials'] = $false }
        Invoke-WebRequest @iwrParams
    } catch {
        Die "Error downloading binary from $BinaryUrl : $_"
    }
    Move-Item -Path "$BinaryPath.new" -Destination $BinaryPath -Force
}

try {
    $ver = & $BinaryPath version 2>&1
    Ok "Binary installed: $ver"
} catch {
    Die "The downloaded binary is not valid or cannot run on this system."
}

# ── Write agent.env ───────────────────────────────────────────────────────────
Step "Saving credentials..."
"HOLOS_API_KEY=$ApiKey" | Set-Content -Path $EnvPath -Encoding UTF8
if ($Proxy) {
    Add-Content -Path $EnvPath -Value "HTTPS_PROXY=$Proxy" -Encoding UTF8
    Add-Content -Path $EnvPath -Value "HTTP_PROXY=$Proxy"  -Encoding UTF8
}

# Restrict permissions: SYSTEM and Administrators only
$acl = Get-Acl $EnvPath
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    'BUILTIN\Administrators', 'FullControl', 'Allow')))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    'NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')))
Set-Acl -Path $EnvPath -AclObject $acl
Ok "Credentials saved to $EnvPath"

# ── Write config.yaml ─────────────────────────────────────────────────────────
Step "Generating configuration..."
$tlsInsecure = if ($Endpoint -like 'http://*') { 'true' } else { 'false' }

if (Test-Path $ConfigPath) {
    Warn "config.yaml already exists - not overwriting. The agent will use the existing configuration."
} else {
    $queuePath = $ConfigDir.Replace('\', '/') + '/queue.ndjson'
    $configLines = @(
        'agent:',
        "  tenant_id:   `"$TenantId`"",
        '  environment: "prod"',
        "  site:        `"$Site`"",
        '  log_level:   "info"',
        '',
        'transport:',
        "  endpoint: `"$Endpoint`"",
        "  heartbeat_endpoint: `"$Endpoint/api/v1/agents/heartbeat`"",
        '  tls:',
        "    insecure: $tlsInsecure",
        '  queue:',
        '    enabled: true',
        "    path: `"$queuePath`"",
        '    max_size_mb: 500',
        '',
        'collection:',
        '  interval: "30s"',
        '',
        'plugins: []'
    )
    # collector_token line: only add when a token was provided by PULSE
    if ($CollectorToken) {
        $ctLine = "  collector_token: `"$CollectorToken`""
        $configLines = $configLines[0..7] + $ctLine + $configLines[8..($configLines.Length-1)]
    }
    ($configLines -join "`r`n") | Set-Content -Path $ConfigPath -Encoding UTF8
    Ok "config.yaml generated at $ConfigPath"
}

# ── Install Windows service ───────────────────────────────────────────────────
Step "Installing Windows service..."
$startArgs       = "start --config `"$ConfigPath`""
$binPathWithArgs = "`"$BinaryPath`" $startArgs"

$existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingSvc) {
    sc.exe config $ServiceName binPath= $binPathWithArgs | Out-Null
    Ok "Service updated"
} else {
    New-Service `
        -Name           $ServiceName `
        -DisplayName    $DisplayName `
        -Description    'Collects OS and database metrics and sends them to the Holos platform.' `
        -BinaryPathName $binPathWithArgs `
        -StartupType    Automatic | Out-Null
    Ok "Service '$ServiceName' registered"
}

# Automatic recovery on failure
sc.exe failure $ServiceName reset= 86400 actions= restart/10000/restart/30000/restart/60000 | Out-Null

# ── Grant Event Log Readers access ───────────────────────────────────────────
# SYSTEM already has full Event Log access (including Security channel).
# If the service runs under a custom account, add it to Event Log Readers so
# the Security channel can be monitored without running as SYSTEM.
Step "Checking Event Log access..."
try {
    $svcAccount = (Get-WmiObject Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop).StartName
    $isSystem = $svcAccount -match '^(LocalSystem|NT AUTHORITY\\SYSTEM|\.\\SYSTEM)$'
    if ($isSystem -or -not $svcAccount) {
        Ok "Running as SYSTEM — Security log access is automatic"
    } else {
        try {
            Add-LocalGroupMember -Group "Event Log Readers" -Member $svcAccount -ErrorAction Stop
            Ok "Added '$svcAccount' to 'Event Log Readers' (enables Security channel)"
        } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
            Ok "'$svcAccount' is already in 'Event Log Readers'"
        } catch {
            Warn "Could not add '$svcAccount' to 'Event Log Readers': $_"
            Warn "Security Event Log may not be readable. Add manually if needed:"
            Warn "  Add-LocalGroupMember -Group 'Event Log Readers' -Member '$svcAccount'"
        }
    }
} catch {
    Warn "Could not determine service account: $_"
}

# Inject environment variables directly into the service registry entry.
# The SCM loads these before starting the process — no need to read the .env at runtime.
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
$regEnv  = @("HOLOS_API_KEY=$ApiKey")
if ($CollectorToken) { $regEnv += "HOLOS_COLLECTOR_TOKEN=$CollectorToken" }
if ($Proxy) {
    $regEnv += "HTTPS_PROXY=$Proxy"
    $regEnv += "HTTP_PROXY=$Proxy"
}
Set-ItemProperty -Path $regPath -Name 'Environment' -Value $regEnv -Type MultiString

# ── Add to system PATH ────────────────────────────────────────────────────────
Step "Adding to system PATH..."
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($machinePath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$InstallDir", "Machine")
    $env:Path += ";$InstallDir"
    Ok "PATH updated — 'holos-agent' available in new sessions"
} else {
    Ok "Already in PATH"
}

# ── Start the service ─────────────────────────────────────────────────────────
Step "Starting holos-agent..."
Start-Service -Name $ServiceName
Start-Sleep -Seconds 2

$svc = Get-Service -Name $ServiceName
if ($svc.Status -eq 'Running') {
    Ok "holos-agent running"
} else {
    Warn "Service did not start. Check: Get-EventLog -LogName Application -Source HolosAgent -Newest 20"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   holos-agent installed successfully   v      ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Tenant  : $TenantId"
Write-Host "  Site    : $Site"
Write-Host "  Config  : $ConfigPath"
if ($Proxy) { Write-Host "  Proxy   : $Proxy" }
Write-Host "  Logs    : Get-EventLog -LogName Application -Source HolosAgent -Newest 50"
Write-Host "  Status  : Get-Service $ServiceName"
Write-Host ""
Write-Host "Next steps - configure monitoring plugins:" -ForegroundColor White
Write-Host ""
Write-Host "  1. Detect services on this host:"
Write-Host "     holos-agent discover" -ForegroundColor Yellow
Write-Host ""
Write-Host "  2. Add a plugin manually:"
Write-Host "     holos-agent plugin add sqlserver --host localhost --username holos_monitor" -ForegroundColor Yellow
Write-Host ""
Write-Host "  3. Verify plugin connectivity:"
Write-Host "     holos-agent plugin test sqlserver" -ForegroundColor Yellow
Write-Host ""
Write-Host "  4. Restart after adding plugins:"
Write-Host "     Restart-Service $ServiceName" -ForegroundColor Yellow
Write-Host ""
