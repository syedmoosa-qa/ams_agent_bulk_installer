# ==============================================================================
# Adamsbridge AMS Asset Discovery Agent
# ESET Bulk Deployment / Silent Installation Script
#
# Version : 1.4.14
#
# Supports:
#   - Fresh installation
#   - Upgrade from older versions
#   - Existing installation repair
#   - Device identity preservation
#   - Automatic enrollment
#   - Windows Service installation
#   - Automatic service recovery
#   - Silent ESET/SYSTEM execution
#
# ==============================================================================

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------
# TLS
# ------------------------------------------------------------------------------

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
catch {
    # Continue - Windows may already have TLS 1.2 enabled
}

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

$TargetVersion = "1.4.14"

$InstallDir = "C:\Program Files\Adamsbridge\AssetAgent"
$DataDir    = "C:\ProgramData\Adamsbridge\AssetAgent"

$ExePath    = Join-Path $InstallDir "abg-asset-agent.exe"
$EnvPath    = Join-Path $InstallDir "agent.env"
$ConfigPath = Join-Path $InstallDir "config.json"

$LogDir = Join-Path $DataDir "logs"
$IpcDir = Join-Path $DataDir "ipc"

$DeploymentLog = Join-Path $DataDir "ESET-Deployment.log"

$ServiceName = "AbgAssetAgent"
$DisplayName = "Adamsbridge Asset Discovery Agent"

$RunKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$RunValueName = "AdamsbridgeAssetAgentCompanion"

# ------------------------------------------------------------------------------
# AMS API
# ------------------------------------------------------------------------------

$ApiBaseUrl = "https://amsapi.adamsbridgestage.com/assetService/api/discovery"

$ApiUrl = "$ApiBaseUrl/sync"

$EnrollUrl = "$ApiBaseUrl/agent/enroll"

$BinaryDownloadUrl = `
    "https://amsapi.adamsbridgestage.com/assetService/public/downloads/abg-asset-agent-windows-amd64.exe"

# ------------------------------------------------------------------------------
# Company
# ------------------------------------------------------------------------------

$CompId = "69f05ac539a2b3169fac09d0"

# ------------------------------------------------------------------------------
# IMPORTANT
#
# Replace this value with the CURRENT enrollment token.
#
# Do not use the old token.
# ------------------------------------------------------------------------------

$EnrollmentToken = "<REPLACE_WITH_NEW_ENROLLMENT_TOKEN>"

# ------------------------------------------------------------------------------
# Service ACL
# ------------------------------------------------------------------------------

$DefaultSd = `
"D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)" +
"(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)" +
"(A;;CCLCSWLOCRRC;;;IU)" +
"(A;;CCLCSWLOCRRC;;;SU)" +
"S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)"

# ==============================================================================
# LOGGING
# ==============================================================================

function Write-Log {

    param(
        [string]$Message
    )

    try {

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        $line = "$timestamp [$env:COMPUTERNAME] $Message"

        Add-Content `
            -Path $DeploymentLog `
            -Value $line `
            -Encoding UTF8 `
            -ErrorAction SilentlyContinue
    }
    catch {
        # Never fail deployment because logging failed
    }
}

# ==============================================================================
# ADMIN CHECK
# ==============================================================================

function Test-IsAdministrator {

    try {

        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

        $principal = New-Object `
            Security.Principal.WindowsPrincipal($identity)

        return $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    }
    catch {

        return $false
    }
}

# ==============================================================================
# PROCESS FUNCTIONS
# ==============================================================================

function Get-AgentProcess {

    return Get-CimInstance `
        Win32_Process `
        -Filter "Name='abg-asset-agent.exe'" `
        -ErrorAction SilentlyContinue
}

function Get-AgentServiceProcess {

    $processes = Get-AgentProcess

    if (-not $processes) {
        return $null
    }

    foreach ($process in $processes) {

        if (
            $process.CommandLine -and
            $process.CommandLine -match "--service"
        ) {

            return $process
        }
    }

    return $null
}

function Get-AgentCompanionProcess {

    $processes = Get-AgentProcess

    if (-not $processes) {
        return $null
    }

    foreach ($process in $processes) {

        if (
            $process.CommandLine -and
            $process.CommandLine -match "--companion"
        ) {

            return $process
        }
    }

    return $null
}

# ==============================================================================
# ENVIRONMENT FUNCTIONS
# ==============================================================================

function Get-EnvValue {

    param(
        [string]$Name,
        [string]$Content
    )

    if (-not $Content) {
        return $null
    }

    $pattern = "(?m)^" + [regex]::Escape($Name) + "=(.*)$"

    $match = [regex]::Match(
        $Content,
        $pattern
    )

    if ($match.Success) {

        return $match.Groups[1].Value.Trim()
    }

    return $null
}

function Set-EnvFile {

    param(
        [string]$Path,
        [hashtable]$Values
    )

    $lines = @()

    foreach ($key in $Values.Keys) {

        $value = $Values[$key]

        if (
            $null -ne $value -and
            "$value" -ne ""
        ) {

            $lines += "$key=$value"
        }
    }

    Set-Content `
        -Path $Path `
        -Value ($lines -join "`r`n") `
        -Encoding ASCII
}

function Get-ExistingEnvironment {

    if (-not (Test-Path $EnvPath)) {

        return @{}
    }

    try {

        $rawEnv = Get-Content `
            $EnvPath `
            -Raw `
            -ErrorAction Stop

        if (-not $rawEnv) {

            return @{}
        }

        return @{
            ApiUrl           = Get-EnvValue "AMS_API_URL" $rawEnv
            CompId           = Get-EnvValue "AMS_COMP_ID" $rawEnv
            DeviceId         = Get-EnvValue "AMS_DEVICE_ID" $rawEnv
            DeviceCredential = Get-EnvValue "AMS_DEVICE_CREDENTIAL" $rawEnv
            AssetHash        = Get-EnvValue "AMS_ASSET_HASH" $rawEnv
            EnrollmentToken  = Get-EnvValue "AMS_ENROLLMENT_TOKEN" $rawEnv
        }
    }
    catch {

        Write-Log "Unable to read existing agent.env: $($_.Exception.Message)"

        return @{}
    }
}

# ==============================================================================
# HARDWARE IDENTITY
# ==============================================================================

function Get-HardwareIdentity {

    Write-Log "Collecting hardware identity."

    $bios = Get-CimInstance `
        Win32_BIOS `
        -ErrorAction SilentlyContinue

    $board = Get-CimInstance `
        Win32_BaseBoard `
        -ErrorAction SilentlyContinue

    $systemProduct = Get-CimInstance `
        Win32_ComputerSystemProduct `
        -ErrorAction SilentlyContinue

    $serial = $null

    if ($bios) {

        $serial = $bios.SerialNumber
    }

    if (
        -not $serial -or
        $serial -match "To be filled|Default|Unknown|None"
    ) {

        if ($board) {

            $serial = $board.SerialNumber
        }
    }

    if (-not $serial) {

        $serial = "UNKNOWN-SERIAL"
    }

    $uuid = $null

    if ($systemProduct) {

        $uuid = $systemProduct.UUID
    }

    if (-not $uuid) {

        $uuid = "UNKNOWN-UUID"
    }

    $serial = $serial.Trim()
    $uuid   = $uuid.Trim()

    $rawId = "$serial|$uuid"

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($rawId)

        $hashBytes = $sha.ComputeHash($bytes)

        $assetHash = (
            $hashBytes |
            ForEach-Object {
                "{0:x2}" -f $_
            }
        ) -join ""

    }
    finally {

        $sha.Dispose()
    }

    return @{
        Serial    = $serial
        UUID      = $uuid
        AssetHash = $assetHash
    }
}

# ==============================================================================
# API CONNECTIVITY
# ==============================================================================

function Test-ApiConnectivity {

    param(
        [string]$Url
    )

    try {

        Write-Log "Testing API connectivity: $Url"

        $request = [System.Net.WebRequest]::Create($Url)

        $request.Method = "GET"

        $request.Timeout = 10000

        $response = $request.GetResponse()

        $statusCode = [int]$response.StatusCode

        $response.Close()

        Write-Log "API reachable. HTTP status: $statusCode"

        return $true
    }
    catch {

        Write-Log `
            "API connectivity test failed: $($_.Exception.Message)"

        return $false
    }
}

# ==============================================================================
# ENROLLMENT
# ==============================================================================

function Enroll-Agent {

    Write-Log "Starting device enrollment."

    if (
        -not $EnrollmentToken -or
        $EnrollmentToken -eq "<REPLACE_WITH_NEW_ENROLLMENT_TOKEN>"
    ) {

        throw "Enrollment token is not configured."
    }

    $identity = Get-HardwareIdentity

    $bodyObject = @{
        assetHash = $identity.AssetHash
        hostname  = $env:COMPUTERNAME
        os        = "windows"
    }

    $body = $bodyObject | ConvertTo-Json

    try {

        $headers = @{
            Authorization = "Bearer $EnrollmentToken"
            "X-Comp-Id"   = $CompId
        }

        $response = Invoke-RestMethod `
            -Uri $EnrollUrl `
            -Method Post `
            -Headers $headers `
            -ContentType "application/json" `
            -Body $body `
            -TimeoutSec 30

        if (-not $response.data) {

            throw "Enrollment API returned no data."
        }

        $deviceId = $response.data.deviceId

        $deviceCredential = $response.data.deviceCredential

        if (-not $deviceId) {

            throw "Enrollment response does not contain deviceId."
        }

        if (-not $deviceCredential) {

            throw "Enrollment response does not contain deviceCredential."
        }

        Write-Log "Enrollment successful. Device ID: $deviceId"

        return @{
            DeviceId         = $deviceId
            DeviceCredential = $deviceCredential
            AssetHash        = $identity.AssetHash
        }
    }
    catch {

        throw "Enrollment failed: $($_.Exception.Message)"
    }
}

# ==============================================================================
# DOWNLOAD AGENT
# ==============================================================================

function Download-Agent {

    Write-Log "Downloading ABG Agent version $TargetVersion."

    $downloadSuccess = $false

    try {

        Invoke-WebRequest `
            -Uri $BinaryDownloadUrl `
            -OutFile $ExePath `
            -UseBasicParsing `
            -TimeoutSec 120 `
            -ErrorAction Stop

        $downloadSuccess = $true

        Write-Log "Agent download completed using Invoke-WebRequest."
    }
    catch {

        Write-Log `
            "Invoke-WebRequest failed: $($_.Exception.Message)"
    }

    if (-not $downloadSuccess) {

        try {

            $webClient = New-Object System.Net.WebClient

            $webClient.DownloadFile(
                $BinaryDownloadUrl,
                $ExePath
            )

            $webClient.Dispose()

            $downloadSuccess = $true

            Write-Log "Agent download completed using WebClient."
        }
        catch {

            throw `
                "Unable to download ABG Agent: $($_.Exception.Message)"
        }
    }

    if (-not (Test-Path $ExePath)) {

        throw "Agent binary was not found after download."
    }

    Unblock-File `
        -Path $ExePath `
        -ErrorAction SilentlyContinue

    Write-Log "Agent binary downloaded successfully."
}

# ==============================================================================
# STOP ONLY SERVICE FOR UPGRADE
# ==============================================================================

function Stop-AgentServiceForUpgrade {

    $svc = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $svc) {

        return
    }

    if ($svc.Status -eq "Stopped") {

        return
    }

    Write-Log "Stopping ABG Agent service for upgrade."

    try {

        Stop-Service `
            -Name $ServiceName `
            -Force `
            -ErrorAction Stop
    }
    catch {

        Write-Log `
            "Stop-Service failed. Trying SC."

        & sc.exe stop $ServiceName | Out-Null
    }

    Start-Sleep -Seconds 2

    $serviceProcess = Get-AgentServiceProcess

    if ($serviceProcess) {

        Write-Log `
            "Service process still running. PID: $($serviceProcess.ProcessId)"

        Stop-Process `
            -Id $serviceProcess.ProcessId `
            -Force `
            -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 2
    }
}

# ==============================================================================
# SERVICE CONFIGURATION
# ==============================================================================

function Install-Or-Configure-Service {

    $serviceCmd = "`"$ExePath`" --service"

    $svc = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $svc) {

        Write-Log "Creating Windows Service."

        try {

            New-Service `
                -Name $ServiceName `
                -BinaryPathName $serviceCmd `
                -DisplayName $DisplayName `
                -Description `
                    "Collects hardware and software telemetry and reports to the Adamsbridge AMS backend." `
                -StartupType Automatic `
                -ErrorAction Stop |
                Out-Null

            Write-Log "Windows Service created."
        }
        catch {

            Write-Log "New-Service failed. Trying SC."

            & sc.exe create `
                $ServiceName `
                binPath= "`"$ExePath`" --service" `
                start= auto `
                DisplayName= "$DisplayName"

            if ($LASTEXITCODE -ne 0) {

                throw "Unable to create Windows Service."
            }
        }
    }
    else {

        Write-Log "Existing Windows Service found."
    }

    # --------------------------------------------------------------------------
    # Make sure startup is Automatic
    # --------------------------------------------------------------------------

    try {

        Set-Service `
            -Name $ServiceName `
            -StartupType Automatic `
            -ErrorAction SilentlyContinue
    }
    catch {
    }

    # --------------------------------------------------------------------------
    # Service description
    # --------------------------------------------------------------------------

    & sc.exe description `
        $ServiceName `
        "Collects hardware and software telemetry and reports to the Adamsbridge AMS backend." |
        Out-Null

    # --------------------------------------------------------------------------
    # Automatic recovery
    # --------------------------------------------------------------------------

    & sc.exe failure `
        $ServiceName `
        reset= 86400 `
        actions= restart/10000/restart/10000/restart/10000 |
        Out-Null

    # --------------------------------------------------------------------------
    # Service ACL
    # --------------------------------------------------------------------------

    & sc.exe sdset `
        $ServiceName `
        $DefaultSd |
        Out-Null

    Write-Log "Windows Service configuration completed."
}

# ==============================================================================
# START SERVICE
# ==============================================================================

function Start-AgentService {

    $svc = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (-not $svc) {

        throw "ABG Agent service does not exist."
    }

    if ($svc.Status -eq "Running") {

        Write-Log "ABG Agent service is already running."

        return
    }

    Write-Log "Starting ABG Agent service."

    Start-Service `
        -Name $ServiceName `
        -ErrorAction Stop

    Start-Sleep -Seconds 5

    $svc = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    if (
        -not $svc -or
        $svc.Status -ne "Running"
    ) {

        throw "ABG Agent service failed to start."
    }

    Write-Log "ABG Agent service is RUNNING."
}

# ==============================================================================
# CONFIGURE TRAY COMPANION
# ==============================================================================

function Configure-TrayCompanion {

    try {

        $companionCmd = "`"$ExePath`" --companion"

        New-ItemProperty `
            -Path $RunKey `
            -Name $RunValueName `
            -Value $companionCmd `
            -PropertyType String `
            -Force |
            Out-Null

        Write-Log "Tray companion startup configured."

        # ----------------------------------------------------------------------
        # IMPORTANT
        #
        # Do NOT use:
        #
        # Stop-Process -Name "abg-asset-agent"
        #
        # because service and companion use the same executable.
        # ----------------------------------------------------------------------

        $existingCompanion = Get-AgentCompanionProcess

        if ($existingCompanion) {

            Write-Log "Tray companion is already running."

            return
        }

        # Under ESET/SYSTEM there may be no interactive desktop.
        # Therefore, do not force-start the companion during SYSTEM deployment.
        #
        # It will start automatically when the user logs in.

        Write-Log `
            "Tray companion configured for user logon."
    }
    catch {

        Write-Log `
            "Tray companion configuration failed: $($_.Exception.Message)"
    }
}

# ==============================================================================
# MAIN
# ==============================================================================

$ExitCode = 0

try {

    # --------------------------------------------------------------------------
    # Create base directories first so logging works.
    # --------------------------------------------------------------------------

    New-Item `
        -ItemType Directory `
        -Path $InstallDir `
        -Force |
        Out-Null

    New-Item `
        -ItemType Directory `
        -Path $DataDir `
        -Force |
        Out-Null

    New-Item `
        -ItemType Directory `
        -Path $LogDir `
        -Force |
        Out-Null

    New-Item `
        -ItemType Directory `
        -Path $IpcDir `
        -Force |
        Out-Null

    Write-Log "============================================================"
    Write-Log "ABG AMS Agent ESET deployment started."
    Write-Log "Target Version: $TargetVersion"
    Write-Log "Computer: $env:COMPUTERNAME"
    Write-Log "============================================================"

    # --------------------------------------------------------------------------
    # Administrator
    # --------------------------------------------------------------------------

    if (-not (Test-IsAdministrator)) {

        throw "Script is not running with Administrator/SYSTEM privileges."
    }

    Write-Log "Administrator/SYSTEM privilege confirmed."

    # --------------------------------------------------------------------------
    # Existing environment
    # --------------------------------------------------------------------------

    $existingEnv = Get-ExistingEnvironment

    $existingDeviceId = $existingEnv.DeviceId

    $existingCredential = $existingEnv.DeviceCredential

    $existingAssetHash = $existingEnv.AssetHash

    # --------------------------------------------------------------------------
    # Check existing binary
    # --------------------------------------------------------------------------

    $needsBinaryUpdate = $false

    $installedVersion = $null

    if (-not (Test-Path $ExePath)) {

        Write-Log "ABG Agent binary not found."

        $needsBinaryUpdate = $true
    }
    else {

        try {

            $statusOutput = & $ExePath --status 2>$null

            if ($statusOutput) {

                $statusRaw = $statusOutput |
                    ConvertFrom-Json

                $installedVersion = $statusRaw.version
            }

            if (-not $installedVersion) {

                Write-Log `
                    "Unable to determine installed version."

                $needsBinaryUpdate = $true
            }
            elseif (
                $installedVersion -ne $TargetVersion
            ) {

                Write-Log `
                    "Installed version: $installedVersion"

                Write-Log `
                    "Target version: $TargetVersion"

                Write-Log `
                    "Agent upgrade required."

                $needsBinaryUpdate = $true
            }
            else {

                Write-Log `
                    "Latest agent version already installed: $installedVersion"
            }
        }
        catch {

            Write-Log `
                "Agent status check failed: $($_.Exception.Message)"

            $needsBinaryUpdate = $true
        }
    }

    # --------------------------------------------------------------------------
    # Install / Upgrade binary
    # --------------------------------------------------------------------------

    if ($needsBinaryUpdate) {

        Write-Log "Binary installation/upgrade required."

        # Only stop service when binary replacement is actually required.
        Stop-AgentServiceForUpgrade

        Download-Agent
    }
    else {

        Write-Log `
            "Binary is current. Existing running agent will not be stopped."
    }

    # --------------------------------------------------------------------------
    # Identity / Enrollment
    # --------------------------------------------------------------------------

    if (
        $existingDeviceId -and
        $existingCredential
    ) {

        Write-Log `
            "Existing Device ID detected. Preserving identity."

        $envValues = [ordered]@{

            AMS_API_URL = $ApiUrl

            AMS_COMP_ID = $CompId

            AMS_DEVICE_ID = $existingDeviceId

            AMS_DEVICE_CREDENTIAL = $existingCredential

            AMS_ASSET_HASH = $existingAssetHash
        }

        Set-EnvFile `
            -Path $EnvPath `
            -Values $envValues

        Write-Log `
            "Existing identity preserved."
    }
    else {

        Write-Log `
            "No complete existing identity found. Starting enrollment."

        try {

            $enrollment = Enroll-Agent

            $envValues = [ordered]@{

                AMS_API_URL = $ApiUrl

                AMS_COMP_ID = $CompId

                AMS_DEVICE_ID = $enrollment.DeviceId

                AMS_DEVICE_CREDENTIAL = $enrollment.DeviceCredential

                AMS_ASSET_HASH = $enrollment.AssetHash
            }

            Set-EnvFile `
                -Path $EnvPath `
                -Values $envValues

            Write-Log `
                "Device enrollment completed."
        }
        catch {

            Write-Log `
                "Direct enrollment failed: $($_.Exception.Message)"

            # ------------------------------------------------------------------
            # Fallback configuration
            # ------------------------------------------------------------------

            if (
                $EnrollmentToken -and
                $EnrollmentToken -ne "<REPLACE_WITH_NEW_ENROLLMENT_TOKEN>"
            ) {

                $envValues = [ordered]@{

                    AMS_API_URL = $ApiUrl

                    AMS_COMP_ID = $CompId

                    AMS_ENROLLMENT_TOKEN = $EnrollmentToken
                }

                Set-EnvFile `
                    -Path $EnvPath `
                    -Values $envValues

                Write-Log `
                    "Fallback enrollment configuration written."
            }
            else {

                throw
            }
        }
    }

    # --------------------------------------------------------------------------
    # Config JSON
    # --------------------------------------------------------------------------

    if (-not (Test-Path $ConfigPath)) {

        $cfgObject = @{
            apiUrl = $ApiUrl

            compId = $CompId

            fullSyncIntervalHours = 24

            heartbeatIntervalMinutes = 15

            heartbeat = @{
                includeMetrics = $true

                cpuSampleSeconds = 5
            }
        }

        $cfgJson = $cfgObject |
            ConvertTo-Json -Depth 5

        Set-Content `
            -Path $ConfigPath `
            -Value $cfgJson `
            -Encoding UTF8

        Write-Log "config.json created."
    }
    else {

        Write-Log `
            "Existing config.json found. Leaving it unchanged."
    }

    # --------------------------------------------------------------------------
    # Secure installation directory
    # --------------------------------------------------------------------------

    try {

        icacls `
            $InstallDir `
            /inheritance:r `
            /grant:r `
            "SYSTEM:(OI)(CI)(F)" `
            "Administrators:(OI)(CI)(F)" `
            "Users:(OI)(CI)(RX)" |
            Out-Null

        Write-Log `
            "Installation directory permissions configured."
    }
    catch {

        Write-Log `
            "Installation directory ACL configuration failed: $($_.Exception.Message)"
    }

    # --------------------------------------------------------------------------
    # Secure agent.env
    # --------------------------------------------------------------------------

    if (Test-Path $EnvPath) {

        try {

            icacls `
                $EnvPath `
                /inheritance:r `
                /grant:r `
                "SYSTEM:(F)" `
                "Administrators:(F)" |
                Out-Null

            Write-Log "agent.env permissions secured."
        }
        catch {

            Write-Log `
                "agent.env ACL configuration failed: $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------------------------------
    # Windows Service
    # --------------------------------------------------------------------------

    Install-Or-Configure-Service

    # --------------------------------------------------------------------------
    # Start / recover service
    # --------------------------------------------------------------------------

    Start-AgentService

    # --------------------------------------------------------------------------
    # Tray companion
    # --------------------------------------------------------------------------

    Configure-TrayCompanion

    # --------------------------------------------------------------------------
    # API connectivity
    # --------------------------------------------------------------------------

    Test-ApiConnectivity `
        -Url $ApiBaseUrl |
        Out-Null

    # --------------------------------------------------------------------------
    # Final status
    # --------------------------------------------------------------------------

    $finalService = Get-Service `
        -Name $ServiceName `
        -ErrorAction SilentlyContinue

    $serviceProcess = Get-AgentServiceProcess

    if (
        $finalService -and
        $finalService.Status -eq "Running" -and
        $serviceProcess
    ) {

        Write-Log `
            "RESULT: ABG AMS Agent installed and running successfully."

        Write-Log `
            "Service Status: $($finalService.Status)"

        Write-Log `
            "Service PID: $($serviceProcess.ProcessId)"

        Write-Log `
            "Installation completed successfully."

        $ExitCode = 0
    }
    else {

        Write-Log `
            "RESULT: ABG AMS Agent requires troubleshooting."

        $ExitCode = 1
    }
}
catch {

    Write-Log "============================================================"

    Write-Log `
        "INSTALLATION FAILED: $($_.Exception.Message)"

    Write-Log `
        "ERROR TYPE: $($_.Exception.GetType().FullName)"

    Write-Log "============================================================"

    $ExitCode = 1
}

# ==============================================================================
# FINAL
# ==============================================================================

Write-Log `
    "ESET deployment finished with exit code: $ExitCode"

exit $ExitCode
