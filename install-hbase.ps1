#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated Apache HBase Installation Script for Windows

.DESCRIPTION
    This script automates the COMPLETE Apache HBase installation on Windows, including:
    1. Pre-flight checks (Java 8, Hadoop, HADOOP_HOME, JAVA_HOME validation)
    2. HBase 2.6.5 download and extraction (with SHA-512 verification)
    3. Environment variables configuration (HBASE_HOME, JAVA_HOME, PATH)
    4. hbase-env.cmd configuration (JAVA_HOME short path fix)
    5. hbase-site.xml configuration (standalone + HDFS-backed modes)
    6. Windows .cmd launcher shim generation (hbase.cmd, start-hbase.cmd, stop-hbase.cmd)
    7. HDFS directory creation (/hbase, /tmp/hbase) when HDFS is running
    8. Windows Firewall rules for HBase ports

.NOTES
    Author:  VANSH RANA
    Date:    2026-05-13
    Version: 1.0

    REQUIREMENTS:
    - Run as Administrator (right-click PowerShell > Run as Administrator)
    - Internet connection for downloads
    - Windows 10/11
    - Java 8 (Eclipse Temurin) already installed  [install-hadoop.ps1 does this]
    - Hadoop 3.x already installed and configured  [install-hadoop.ps1]

    USAGE:
    1. Right-click PowerShell and "Run as Administrator"
    2. Run:  Set-ExecutionPolicy Bypass -Scope Process -Force
    3. Run:  .\install-hbase.ps1
#>

# ============================================================================
#  CONFIGURATION - Modify these as needed before running
# ============================================================================

$HBASE_VERSION = "2.6.5"
$INSTALL_DIR = "C:\hbase"                            # Where HBase will be installed
$HBASE_DATA_DIR = "$env:USERPROFILE\hbase-data"         # Data/WAL/tmp directory (user-owned)

# ============================================================================
#  LOGGING - transcript started immediately so nothing is missed
# ============================================================================
$_logDir = "$env:TEMP\hbase-install"
$_logFile = "$_logDir\install-hbase-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
if (-not (Test-Path $_logDir)) { New-Item -ItemType Directory -Path $_logDir -Force | Out-Null }
Start-Transcript -Path $_logFile -Append | Out-Null
Write-Host "  [LOG] Transcript started -> $_logFile" -ForegroundColor DarkGray
Write-Host ""

# Exit helper - always flushes transcript before quitting
function Exit-Script {
    param([int]$Code = 0)
    Write-Host ""
    Write-Host "  [LOG] Install log saved to: $_logFile" -ForegroundColor DarkGray
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    exit $Code
}

# ---------------------------------------------------------------------------
# Auto-detect HADOOP_HOME from common install locations
# ---------------------------------------------------------------------------
$_hadoopCandidates = @(
    "C:\hadoop",
    "C:\hadoop\hadoop",
    "C:\hadoop\hadoop-3.4.3", "C:\hadoop\hadoop-3.4.2", "C:\hadoop\hadoop-3.4.1", "C:\hadoop\hadoop-3.4.0",
    "C:\hadoop\hadoop-3.3.6", "C:\hadoop\hadoop-3.3.5", "C:\hadoop\hadoop-3.2.4", "C:\hadoop\hadoop-3.1.3",
    "C:\hadoop\hadoop3.4.3", "C:\hadoop\hadoop3.4.2", "C:\hadoop\hadoop3.3.6", "C:\hadoop\hadoop3.1.3"
)
if ($env:HADOOP_HOME) { $_hadoopCandidates = @($env:HADOOP_HOME) + $_hadoopCandidates }

$HADOOP_HOME = $null
foreach ($_c in $_hadoopCandidates) {
    if (Test-Path "$_c\bin\hadoop.cmd") { $HADOOP_HOME = $_c; break }
}
if (-not $HADOOP_HOME) {
    Write-Host "  [..] Scanning C: for hadoop.cmd..." -ForegroundColor DarkYellow
    # Step 1: look inside any folder named hadoop/Hadoop/HADOOP at C:\ root
    foreach ($_fn in @("hadoop", "Hadoop", "HADOOP")) {
        if (Test-Path "C:\$_fn") {
            $found = Get-ChildItem "C:\$_fn" -Filter "hadoop.cmd" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $HADOOP_HOME = Split-Path $found.DirectoryName -Parent; break }
        }
    }
    # Step 2: walk 2 levels deep under C:\ (covers C:\tools\hadoop, C:\Program Files\Hadoop, etc.)
    if (-not $HADOOP_HOME) {
        $topDirs = Get-ChildItem -Path "C:\" -Directory -ErrorAction SilentlyContinue
        foreach ($_top in $topDirs) {
            $found = Get-ChildItem -Path $_top.FullName -Filter "hadoop.cmd" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $HADOOP_HOME = Split-Path $found.DirectoryName -Parent; break }
            $subDirs = Get-ChildItem -Path $_top.FullName -Directory -ErrorAction SilentlyContinue
            foreach ($_sub in $subDirs) {
                $found = Get-ChildItem -Path $_sub.FullName -Filter "hadoop.cmd" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) { $HADOOP_HOME = Split-Path $found.DirectoryName -Parent; break }
            }
            if ($HADOOP_HOME) { break }
        }
    }
    if ($HADOOP_HOME) { Write-Host "  [OK] Auto-detected Hadoop at: $HADOOP_HOME" -ForegroundColor Green }
}

$TEMP_DIR = "$env:TEMP\hbase-install"

# HBase download mirrors
$HBASE_URLS = @(
    "https://dlcdn.apache.org/hbase/$HBASE_VERSION/hbase-$HBASE_VERSION-bin.tar.gz",
    "https://downloads.apache.org/hbase/$HBASE_VERSION/hbase-$HBASE_VERSION-bin.tar.gz",
    "https://archive.apache.org/dist/hbase/$HBASE_VERSION/hbase-$HBASE_VERSION-bin.tar.gz"
)

$7ZIP_URLS = @(
    "https://www.7-zip.org/a/7z2409-x64.exe",
    "https://www.7-zip.org/a/7z2408-x64.exe",
    "https://www.7-zip.org/a/7z2407-x64.exe"
)

# ============================================================================
#  HELPER FUNCTIONS
# ============================================================================

function Write-Banner {
    param([string]$Text)
    $line = "=" * 70
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Text" -NoNewline -ForegroundColor Cyan
    $padding = 70 - $Text.Length - 19
    if ($padding -gt 0) { Write-Host (" " * $padding) -NoNewline }
    Write-Host "  by VANSH RANA" -ForegroundColor Magenta
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$StepNum, [string]$Text)
    Write-Host "  [$StepNum] " -ForegroundColor Yellow -NoNewline
    Write-Host $Text -ForegroundColor White
}

function Write-Success {
    param([string]$Text)
    Write-Host "  [OK] " -ForegroundColor Green -NoNewline
    Write-Host $Text
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  [!!] " -ForegroundColor DarkYellow -NoNewline
    Write-Host $Text -ForegroundColor DarkYellow
}

function Write-Err {
    param([string]$Text)
    Write-Host "  [ERROR] " -ForegroundColor Red -NoNewline
    Write-Host $Text -ForegroundColor Red
}

function Confirm-Continue {
    param([string]$Message)
    Write-Host ""
    $r = Read-Host "  $Message (Y/N)"
    if ($r -ne 'Y' -and $r -ne 'y') { Write-Host "  Skipped." -ForegroundColor DarkGray; return $false }
    return $true
}

function Get-ShortPath {
    param([string]$LongPath)
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        if (Test-Path $LongPath -PathType Container) { return $fso.GetFolder($LongPath).ShortPath }
        elseif (Test-Path $LongPath -PathType Leaf) { return $fso.GetFile($LongPath).ShortPath }
    }
    catch {}
    return $LongPath
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N0} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Download-WithProgress {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$DisplayName = "",
        [int]$TimeoutSec = 300
    )
    if (-not $DisplayName) { $DisplayName = [System.IO.Path]::GetFileName($OutFile) }
    $uri = New-Object System.Uri($Url)
    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Timeout = $TimeoutSec * 1000
    $request.UserAgent = "HBaseInstaller/1.0"
    $request.AllowAutoRedirect = $true
    try { $response = $request.GetResponse() }
    catch { throw "Download failed for ${Url}: $_" }

    $totalBytes = $response.ContentLength
    $responseStream = $response.GetResponseStream()
    $fileStream = $null
    try { $fileStream = [System.IO.File]::Create($OutFile) }
    catch { $response.Close(); $responseStream.Close(); throw "Cannot create '${OutFile}': $_" }

    $buffer = New-Object byte[] 65536
    $downloadedBytes = [long]0
    $startTime = Get-Date
    $lastUpdate = [DateTime]::MinValue
    try {
        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead
            $now = Get-Date
            if (($now - $lastUpdate).TotalMilliseconds -ge 250) {
                $lastUpdate = $now
                $elapsed = ($now - $startTime).TotalSeconds
                $speedBps = if ($elapsed -gt 0) { $downloadedBytes / $elapsed } else { 0 }
                $speedText = "$(Format-FileSize ([long]$speedBps))/s"
                $dlText = Format-FileSize $downloadedBytes
                if ($totalBytes -gt 0) {
                    $pct = [Math]::Round(($downloadedBytes / $totalBytes) * 100, 1)
                    $totTxt = Format-FileSize $totalBytes
                    $bw = 30
                    $filled = [int][Math]::Floor($bw * $pct / 100)
                    $bar = ("$([char]0x2588)" * $filled) + ("$([char]0x2591)" * ($bw - $filled))
                    $line = "`r    [$bar] $pct%  $dlText / $totTxt  ($speedText)   "
                }
                else {
                    $line = "`r    Downloading...  $dlText  ($speedText)   "
                }
                Write-Host $line -NoNewline -ForegroundColor DarkCyan
            }
        }
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        $avgSpeed = if ($elapsed -gt 0) { Format-FileSize ([long]($downloadedBytes / $elapsed)) } else { "?" }
        Write-Host "`r    Downloaded $(Format-FileSize $downloadedBytes) in $([Math]::Round($elapsed,1))s ($avgSpeed/s)                    " -ForegroundColor Green
    }
    finally {
        if ($fileStream) { $fileStream.Close() }
        $responseStream.Close()
        $response.Close()
    }
}

function Download-WithFallback {
    param([string[]]$Urls, [string]$OutFile, [string]$DisplayName, [int]$TimeoutSec = 300)
    foreach ($url in $Urls) {
        try {
            Write-Host "    Trying: $url" -ForegroundColor Gray
            Download-WithProgress -Url $url -OutFile $OutFile -DisplayName $DisplayName -TimeoutSec $TimeoutSec
            if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -eq 0) {
                Write-Warn "    File is 0 bytes (quarantined?) - trying next..."
                Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                continue
            }
            Write-Success "$DisplayName downloaded"
            return $true
        }
        catch {
            Write-Warn "    Failed ($($_.Exception.Message.Split([char]10)[0])) - trying next..."
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
        }
    }
    return $false
}

function Test-HBaseArchive {
    param([string]$ArchivePath, [string[]]$MirrorUrls)
    Write-Step "1.1b" "Verifying SHA-512 checksum..."
    foreach ($url in $MirrorUrls) {
        $sha512Url = $url + ".sha512"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $shaRaw = (Invoke-WebRequest -Uri $sha512Url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop).Content
            $expectedHash = (($shaRaw -split '[\s]+')[0]).ToUpper().Trim()
            if ($expectedHash.Length -ne 128) { continue }   # not a valid SHA-512
            $actualHash = (Get-FileHash $ArchivePath -Algorithm SHA512).Hash.ToUpper()
            if ($actualHash -eq $expectedHash) {
                Write-Success "SHA-512 verified ($($expectedHash.Substring(0,16))...)"
                return $true
            }
            else {
                Write-Err "SHA-512 MISMATCH - archive is corrupt or tampered. Deleting and aborting."
                Write-Host "  Expected : $expectedHash" -ForegroundColor Red
                Write-Host "  Actual   : $actualHash"   -ForegroundColor Red
                Remove-Item $ArchivePath -Force -ErrorAction SilentlyContinue
                Exit-Script 1
            }
        }
        catch {
            Write-Warn "Could not fetch .sha512 from $sha512Url"
        }
    }
    Write-Warn "SHA-512 verification skipped (no .sha512 reachable). Proceeding on size check only."
    return $false
}

# ============================================================================
#  PRE-FLIGHT CHECKS
# ============================================================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Banner "HBASE AUTOMATED INSTALLER FOR WINDOWS"
Write-Host "  HBase Version  : $HBASE_VERSION"
Write-Host "  Install Path   : $INSTALL_DIR"
Write-Host "  Hadoop Home    : $(if ($HADOOP_HOME) { $HADOOP_HOME } else { '(not found)' })"
Write-Host "  Data Dir       : $HBASE_DATA_DIR"
Write-Host "  Created by     : VANSH RANA" -ForegroundColor Magenta
Write-Host ""

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "This script must be run as Administrator!"
    Write-Host "  Right-click PowerShell > 'Run as Administrator', then re-run this script."
    Exit-Script 1
}
Write-Success "Running as Administrator"

# Java check
$existingJava = Get-Command java.exe -ErrorAction SilentlyContinue
if (-not $existingJava) {
    Write-Err "java.exe not found on PATH!"
    Write-Host "  HBase requires Java 8. Run install-hadoop.ps1 first."
    Exit-Script 1
}
$javaVerRaw = & "$($existingJava.Source)" -version 2>&1
$javaVerText = ($javaVerRaw | ForEach-Object { $_.ToString() }) -join " "
if ($javaVerText -match '1\.8\.0') {
    Write-Success "Java 8 detected - compatible with HBase $HBASE_VERSION"
}
else {
    Write-Warn "Detected Java: $javaVerText"
    Write-Warn "HBase 2.x officially supports Java 8 and Java 11."
    if (-not (Confirm-Continue "Continue with this JVM?")) { Exit-Script 1 }
}

# Resolve JAVA_HOME
$javaHome = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
if (-not $javaHome -or -not (Test-Path "$javaHome\bin\java.exe")) {
    $javaHome = Split-Path (Split-Path $existingJava.Source -Parent) -Parent
}
Write-Success "JAVA_HOME resolved: $javaHome"

# Short path for JAVA_HOME (critical when path contains spaces)
$javaHomeShort = $javaHome
if ($javaHome -match '\s') {
    $javaHomeShort = Get-ShortPath $javaHome
    if ($javaHomeShort -ne $javaHome) {
        Write-Success "JAVA_HOME short path: $javaHomeShort"
    }
    else {
        Write-Warn "Could not shorten JAVA_HOME. Consider moving Java to a path without spaces."
    }
}

# Hadoop check
if ($HADOOP_HOME -and (Test-Path "$HADOOP_HOME\bin\hadoop.cmd")) {
    Write-Success "Hadoop found at: $HADOOP_HOME"
    $hadoopVerRaw = & "$HADOOP_HOME\bin\hadoop.cmd" version 2>$null
    $hadoopVerLine = ($hadoopVerRaw | Where-Object { $_ -match '^Hadoop\s+\d' } | Select-Object -First 1)
    if ($hadoopVerLine) { Write-Success "Hadoop version: $hadoopVerLine" }
}
else {
    Write-Warn "Hadoop not found. HBase will run in STANDALONE (local filesystem) mode."
    Write-Warn "For HDFS-backed HBase, install Hadoop first with install-hadoop.ps1"
    $HADOOP_HOME = $null
}

# Create temp/data directories
foreach ($d in @($TEMP_DIR, $HBASE_DATA_DIR, "$HBASE_DATA_DIR\logs", "$HBASE_DATA_DIR\tmp", "$HBASE_DATA_DIR\root", "$HBASE_DATA_DIR\zookeeper")) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ============================================================================
#  STEP 1: DOWNLOAD AND EXTRACT HBASE
# ============================================================================

Write-Banner "STEP 1: Apache HBase $HBASE_VERSION Download & Extraction"

$doDownload = $false
if (Test-Path "$INSTALL_DIR\bin\hbase") {
    Write-Warn "HBase already exists at $INSTALL_DIR"
    if (-not (Confirm-Continue "Existing HBase found. OVERWRITE with HBase $HBASE_VERSION?")) {
        Write-Success "Keeping existing HBase installation"
        $doDownload = $false
    }
    else {
        $backupDir = "$TEMP_DIR\hbase-conf-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        if (Test-Path "$INSTALL_DIR\conf") {
            Copy-Item "$INSTALL_DIR\conf" $backupDir -Recurse -Force
            Write-Success "Conf backed up to: $backupDir"
        }
        Remove-Item "$INSTALL_DIR\*" -Recurse -Force -ErrorAction SilentlyContinue
        $doDownload = $true
    }
}
else {
    $doDownload = $true
}

if ($doDownload) {
    Write-Step "1.1" "Downloading Apache HBase $HBASE_VERSION (~300 MB)..."
    $hbaseTarGz = "$TEMP_DIR\hbase-$HBASE_VERSION-bin.tar.gz"
    $minHBaseBytes = 200MB
    $archiveVerified = $false

    if (Test-Path $hbaseTarGz) {
        $archiveSize = (Get-Item $hbaseTarGz).Length
        if ($archiveSize -ge $minHBaseBytes) {
            Write-Warn "Archive already downloaded ($(Format-FileSize $archiveSize)), reusing."
            $archiveVerified = Test-HBaseArchive -ArchivePath $hbaseTarGz -MirrorUrls $HBASE_URLS
        }
        else {
            Write-Warn "Cached archive is $(Format-FileSize $archiveSize) - likely corrupt. Re-downloading..."
            Remove-Item $hbaseTarGz -Force
        }
    }

    if (-not (Test-Path $hbaseTarGz)) {
        $downloaded = Download-WithFallback -Urls $HBASE_URLS -OutFile $hbaseTarGz -DisplayName "Apache HBase $HBASE_VERSION" -TimeoutSec 600
        if (-not $downloaded) {
            Write-Err "All mirrors failed."
            $HBASE_URLS | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            Write-Host "  Save to: $hbaseTarGz" -ForegroundColor Yellow
            Read-Host "  Press Enter after downloading manually"
        }
    }

    if (-not (Test-Path $hbaseTarGz)) { Write-Err "Archive not found. Cannot continue."; Exit-Script 1 }
    if (-not $archiveVerified) { Test-HBaseArchive -ArchivePath $hbaseTarGz -MirrorUrls $HBASE_URLS | Out-Null }

    Write-Step "1.2" "Extracting HBase (this may take a minute)..."
    if (-not (Test-Path $INSTALL_DIR)) { New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null }

    $extractTemp = "$TEMP_DIR\hbase-extract"
    if (Test-Path $extractTemp) { cmd /c rmdir /s /q "$extractTemp" }
    New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null
    $extracted = $false

    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        Write-Host "    Using built-in tar.exe..." -ForegroundColor Gray
        & tar.exe -xzf "$hbaseTarGz" -C "$extractTemp" 2>$null
        $tarExit = $LASTEXITCODE
        $chkFolder = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "hbase-*" } | Select-Object -First 1
        if (-not $chkFolder) { $chkFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
        if ($tarExit -eq 0 -and $chkFolder -and (Test-Path "$($chkFolder.FullName)\bin\hbase")) {
            $extracted = $true; Write-Success "Extracted using tar.exe"
        }
        else {
            Write-Warn "tar.exe incomplete (exit $tarExit). Trying 7-Zip..."
            cmd /c rmdir /s /q "$extractTemp" 2>$null
            New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null
        }
    }

    if (-not $extracted) {
        $7zInstaller = "$TEMP_DIR\7z_installer.exe"
        $7zDir = "$TEMP_DIR\7z-extract"
        $7zDownloaded = $false
        foreach ($zUrl in $7ZIP_URLS) {
            try {
                Download-WithProgress -Url $zUrl -OutFile $7zInstaller -DisplayName "7-Zip Installer"
                if ((Test-Path $7zInstaller) -and (Get-Item $7zInstaller).Length -gt 0) { $7zDownloaded = $true; break }
                Remove-Item $7zInstaller -Force -ErrorAction SilentlyContinue
            }
            catch { Write-Warn "7-Zip mirror failed, trying next..." }
        }
        if ($7zDownloaded) {
            Start-Process -FilePath $7zInstaller -ArgumentList @("/S", "/D=$7zDir") -Wait -NoNewWindow
            $7zExe = "$7zDir\7z.exe"
            if (Test-Path $7zExe) {
                & $7zExe x "$hbaseTarGz" -o"$extractTemp" -y | Out-Null
                $tarFile = Get-ChildItem $extractTemp -Filter "*.tar" -File | Select-Object -First 1
                if ($tarFile) {
                    & $7zExe x "$($tarFile.FullName)" -o"$extractTemp" -y | Out-Null
                    Remove-Item $tarFile.FullName -Force -ErrorAction SilentlyContinue
                }
                else {
                    Write-Warn "    No .tar file found after gzip extraction. Archive may be corrupt."
                }
                $chkFolder = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "hbase-*" } | Select-Object -First 1
                if (-not $chkFolder) { $chkFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
                if ($chkFolder -and (Test-Path "$($chkFolder.FullName)\bin\hbase")) {
                    $extracted = $true; Write-Success "Extracted using 7-Zip fallback"
                }
            }
        }
    }

    if ($extracted) {
        $ef = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "hbase-*" } | Select-Object -First 1
        if (-not $ef) { $ef = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
        robocopy "$($ef.FullName)" "$INSTALL_DIR" /E /MOVE /NFL /NDL /NJH /NJS /NC /NS /NP 2>&1 | Out-Null
        $rcExit = $LASTEXITCODE
        cmd /c rmdir /s /q "$extractTemp" 2>$null
        if ($rcExit -le 7) { Write-Success "HBase extracted to $INSTALL_DIR" }
        else { Write-Warn "robocopy exit $rcExit - files may still be OK."; Write-Success "HBase extracted (with warnings)" }
    }
    else {
        Write-Err "Extraction failed. Please extract $hbaseTarGz to $INSTALL_DIR manually."
        Read-Host "Press Enter after extracting manually"
        if (-not (Test-Path "$INSTALL_DIR\bin\hbase")) { Write-Err "HBase not found. Cannot continue."; Exit-Script 1 }
    }

    if (Test-Path "$TEMP_DIR\7z-extract") { Remove-Item "$TEMP_DIR\7z-extract" -Recurse -Force -ErrorAction SilentlyContinue }
}


Write-Success "HBase binaries ready at: $INSTALL_DIR"

# ============================================================================
#  STEP 2: ENVIRONMENT VARIABLES
# ============================================================================

Write-Banner "STEP 2: Environment Variables (HBASE_HOME, PATH)"

Write-Step "2.1" "Setting HBASE_HOME system environment variable..."
[System.Environment]::SetEnvironmentVariable("HBASE_HOME", $INSTALL_DIR, "Machine")
$env:HBASE_HOME = $INSTALL_DIR
Write-Success "HBASE_HOME = $INSTALL_DIR"

Write-Step "2.2" "Setting JAVA_HOME system environment variable..."
[System.Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "Machine")
$env:JAVA_HOME = $javaHome
Write-Success "JAVA_HOME = $javaHome"

Write-Step "2.3" "Adding $INSTALL_DIR\bin to system PATH..."
$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
if (-not $machinePath) { $machinePath = "" }
$hbaseBin = "$INSTALL_DIR\bin"
$machineEntries = ($machinePath -split ';') | ForEach-Object { $_.Trim() }
if ($machineEntries -notcontains $hbaseBin) {
    [System.Environment]::SetEnvironmentVariable("Path", "$machinePath;$hbaseBin", "Machine")
    $env:Path = "$env:Path;$hbaseBin"
    Write-Success "Added $hbaseBin to system PATH"
}
else {
    Write-Success "$hbaseBin is already in system PATH"
}

Write-Step "2.4" "Updating user-level PATH (for non-admin terminals)..."
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath) { $userPath = "" }
$userEntries = ($userPath -split ';') | ForEach-Object { $_.Trim() }
if ($userEntries -notcontains $hbaseBin) {
    if ($userPath) { $userPath = "$userPath;$hbaseBin" } else { $userPath = $hbaseBin }
    [System.Environment]::SetEnvironmentVariable("Path", $userPath, "User")
    Write-Success "Added $hbaseBin to user PATH"
}
else {
    Write-Success "$hbaseBin is already in user PATH"
}

if ($HADOOP_HOME) {
    Write-Step "2.5" "Setting HADOOP_HOME environment variable..."
    [System.Environment]::SetEnvironmentVariable("HADOOP_HOME", $HADOOP_HOME, "Machine")
    $env:HADOOP_HOME = $HADOOP_HOME
    Write-Success "HADOOP_HOME = $HADOOP_HOME"
}

# Refresh session PATH
$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = if ($userPath) { "$machinePath;$userPath" } else { $machinePath }

# ============================================================================
#  STEP 3: hbase-env.cmd CONFIGURATION
# ============================================================================

Write-Banner "STEP 3: hbase-env.cmd Configuration"

$hbaseEnvFile = "$INSTALL_DIR\conf\hbase-env.cmd"
if (-not (Test-Path "$INSTALL_DIR\conf")) {
    New-Item -ItemType Directory -Path "$INSTALL_DIR\conf" -Force | Out-Null
}

Write-Step "3.1" "Writing hbase-env.cmd..."

$hadoopHomeEnvLine = ""
if ($HADOOP_HOME) {
    $hadoopHomeEnvLine = "set HADOOP_HOME=$HADOOP_HOME"
}

$hbaseEnvContent = @"
@rem Licensed to the Apache Software Foundation (ASF)
@rem hbase-env.cmd - HBase environment configuration for Windows
@rem Generated by install-hbase.ps1 (VANSH RANA)

@rem ---- Java Home ----
@rem Using 8.3 short path to avoid spaces in "Program Files" breaking HBase scripts
set JAVA_HOME=$javaHomeShort

@rem ---- HBase Home ----
set HBASE_HOME=$INSTALL_DIR

@rem ---- Hadoop Home (required for HDFS-backed mode) ----
$hadoopHomeEnvLine

@rem ---- HBase Heap ----
set JAVA_HEAP_MAX=-Xmx1024m

@rem ---- HBase Log Directory ----
set HBASE_LOG_DIR=$HBASE_DATA_DIR\logs

@rem ---- HBase PID Directory ----
set HBASE_PID_DIR=$HBASE_DATA_DIR\tmp

@rem ---- Disable IPv6 preference (common Windows issue) ----
set HBASE_OPTS=%HBASE_OPTS% -Djava.net.preferIPv4Stack=true

@rem ---- Disable DNS caching issues ----
set HBASE_OPTS=%HBASE_OPTS% -Dsun.net.inetaddr.ttl=0

@rem ---- Fix Windows path separator issues in HBase scripts ----
set HBASE_OPTS=%HBASE_OPTS% -Dhbase.rootdir.perms=777
"@

# Write WITHOUT BOM - cmd.exe chokes on UTF-8 BOM (shows as garbage ∩╗┐)
$noBomUtf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($hbaseEnvFile, $hbaseEnvContent, $noBomUtf8)
Write-Success "hbase-env.cmd written to: $hbaseEnvFile"

# ============================================================================
#  STEP 4: hbase-site.xml CONFIGURATION
# ============================================================================

Write-Banner "STEP 4: hbase-site.xml Configuration"

$hbaseSiteFile = "$INSTALL_DIR\conf\hbase-site.xml"

# Choose mode based on whether Hadoop is present
if ($HADOOP_HOME) {
    Write-Step "4.1" "Configuring hbase-site.xml for HDFS-backed (pseudo-distributed) mode..."
    # Use forward slashes in XML URIs - required by HBase URI parser
    $hdfsRootDir = "hdfs://localhost:9000/hbase"
    $hbaseSiteContent = @"
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<!--
  hbase-site.xml  -  HBase $HBASE_VERSION  (HDFS-backed pseudo-distributed)
  Generated by install-hbase.ps1  |  Author: VANSH RANA
-->
<configuration>

  <!-- HBase root directory on HDFS -->
  <property>
    <name>hbase.rootdir</name>
    <value>$hdfsRootDir</value>
    <description>HBase root directory on HDFS. Must match Hadoop NameNode port.</description>
  </property>

  <!-- Pseudo-distributed: each daemon in its own JVM, data on HDFS -->
  <property>
    <name>hbase.cluster.distributed</name>
    <value>true</value>
  </property>

  <!-- Temporary working directory -->
  <property>
    <name>hbase.tmp.dir</name>
    <value>$($HBASE_DATA_DIR.Replace('\','/'))/tmp</value>
  </property>

  <!-- ZooKeeper data directory -->
  <property>
    <name>hbase.zookeeper.property.dataDir</name>
    <value>$($HBASE_DATA_DIR.Replace('\','/'))/zookeeper</value>
  </property>

  <!-- Disable stream capability enforcement (required on Windows) -->
  <property>
    <name>hbase.unsafe.stream.capability.enforce</name>
    <value>false</value>
  </property>

  <!-- Short-circuit reads - disable on Windows (not supported) -->
  <property>
    <name>dfs.client.read.shortcircuit</name>
    <value>false</value>
  </property>

  <!-- HMaster web UI port -->
  <property>
    <name>hbase.master.info.port</name>
    <value>16010</value>
  </property>

  <!-- RegionServer web UI port -->
  <property>
    <name>hbase.regionserver.info.port</name>
    <value>16030</value>
  </property>

</configuration>
"@
}
else {
    Write-Step "4.1" "Configuring hbase-site.xml for STANDALONE (local filesystem) mode..."
    $hbaseRootDir = $HBASE_DATA_DIR.Replace('\', '/') + "/root"
    $hbaseSiteContent = @"
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<!--
  hbase-site.xml  -  HBase $HBASE_VERSION  (Standalone / Local FS mode)
  Generated by install-hbase.ps1  |  Author: VANSH RANA
-->
<configuration>

  <!-- HBase root directory on LOCAL filesystem -->
  <property>
    <name>hbase.rootdir</name>
    <value>file:///$hbaseRootDir</value>
    <description>Local filesystem path for HBase data (standalone mode).</description>
  </property>

  <!-- Standalone mode: single JVM, local storage, built-in ZooKeeper -->
  <property>
    <name>hbase.cluster.distributed</name>
    <value>false</value>
  </property>

  <!-- Temporary working directory -->
  <property>
    <name>hbase.tmp.dir</name>
    <value>$($HBASE_DATA_DIR.Replace('\','/'))/tmp</value>
  </property>

  <!-- ZooKeeper data directory -->
  <property>
    <name>hbase.zookeeper.property.dataDir</name>
    <value>$($HBASE_DATA_DIR.Replace('\','/'))/zookeeper</value>
  </property>

  <!-- Disable stream capability enforcement (required on Windows) -->
  <property>
    <name>hbase.unsafe.stream.capability.enforce</name>
    <value>false</value>
  </property>

  <!-- HMaster web UI port -->
  <property>
    <name>hbase.master.info.port</name>
    <value>16010</value>
  </property>

  <!-- RegionServer web UI port -->
  <property>
    <name>hbase.regionserver.info.port</name>
    <value>16030</value>
  </property>

</configuration>
"@
}

$noBomUtf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($hbaseSiteFile, $hbaseSiteContent, $noBomUtf8)
Write-Success "hbase-site.xml written to: $hbaseSiteFile"

# ============================================================================
#  STEP 5: WINDOWS LAUNCHER SHIMS
#  HBase ships only Unix shell scripts (.sh). We create Windows .cmd wrappers.
# ============================================================================

Write-Banner "STEP 5: Windows Launcher Shims (.cmd wrappers)"

# hbase.cmd - main CLI + shell launcher
$hbaseCmdContent = @"
@echo off
@rem HBase Windows launcher shim
@rem Generated by install-hbase.ps1  |  Author: VANSH RANA
@rem IMPORTANT: disabledelayedexpansion prevents cmd.exe from eating the '!'
@rem in "jar:file:hbase-shell.jar!/jar-bootstrap.rb" which breaks the shell
setlocal disabledelayedexpansion

if not defined HBASE_HOME set HBASE_HOME=$INSTALL_DIR
if not defined JAVA_HOME  set JAVA_HOME=$javaHomeShort

set HBASE_CONF_DIR=%HBASE_HOME%\conf
set HBASE_LIB_DIR=%HBASE_HOME%\lib

@rem Source hbase-env.cmd first (sets JAVA_HOME, JAVA_HEAP_MAX, base HBASE_OPTS etc.)
if exist "%HBASE_CONF_DIR%\hbase-env.cmd" call "%HBASE_CONF_DIR%\hbase-env.cmd"

@rem Shell classpath: client-facing-thirdparty FIRST so correct JLine wins
@rem zkcli EXCLUDED - contains old jline-2.11.jar which crashes irb/completion
set HBASE_SHELL_CP=%HBASE_CONF_DIR%;%HBASE_LIB_DIR%\client-facing-thirdparty\*;%HBASE_LIB_DIR%\*;%HBASE_LIB_DIR%\shaded-clients\*;%HBASE_LIB_DIR%\trace\*;%HBASE_LIB_DIR%\ruby\*

@rem Full classpath for master/regionserver (includes zkcli for ZooKeeper CLI)
set HBASE_FULL_CP=%HBASE_CONF_DIR%;%HBASE_LIB_DIR%\client-facing-thirdparty\*;%HBASE_LIB_DIR%\*;%HBASE_LIB_DIR%\shaded-clients\*;%HBASE_LIB_DIR%\zkcli\*;%HBASE_LIB_DIR%\trace\*;%HBASE_LIB_DIR%\ruby\*

@rem Apply heap from hbase-env.cmd (JAVA_HEAP_MAX=-Xmx1024m) then append log/identity opts
@rem NOTE: use %HBASE_OPTS% (append) not a bare = (reset) so env.cmd opts are preserved
set HBASE_OPTS=%HBASE_OPTS% %JAVA_HEAP_MAX%
set HBASE_OPTS=%HBASE_OPTS% -Dhbase.log.dir=%HBASE_HOME%\logs
set HBASE_OPTS=%HBASE_OPTS% -Dhbase.log.file=hbase.log
set HBASE_OPTS=%HBASE_OPTS% -Dhbase.home.dir=%HBASE_HOME%
set HBASE_OPTS=%HBASE_OPTS% -Dhbase.id.str=%USERNAME%
set HBASE_OPTS=%HBASE_OPTS% -Dhbase.root.logger=WARN,console

@rem Windows compatibility: disable Jansi native DLL (UnsatisfiedLinkError fix)
@rem and disable JLine terminal features that conflict on Windows
set HBASE_OPTS=%HBASE_OPTS% -Djansi.passthrough=true
set HBASE_OPTS=%HBASE_OPTS% -Djansi.disable=true
set HBASE_OPTS=%HBASE_OPTS% -Djline.terminal=jline.UnsupportedTerminal
set HBASE_OPTS=%HBASE_OPTS% -Dorg.jline.terminal.provider=dumb

if not exist "%HBASE_HOME%\logs" mkdir "%HBASE_HOME%\logs"

@rem Dispatch sub-commands
set COMMAND=%1
if "%COMMAND%"=="shell"        goto :do_shell
if "%COMMAND%"=="master"       goto :do_master
if "%COMMAND%"=="regionserver" goto :do_regionserver
if "%COMMAND%"=="version"      goto :do_version
if "%COMMAND%"=="classpath"    goto :do_classpath
goto :do_shell

:do_shell
set HBASE_SHELL_JAR=
for %%j in (%HBASE_LIB_DIR%\hbase-shell-*.jar) do set HBASE_SHELL_JAR=%%j
if not defined HBASE_SHELL_JAR (
    echo [ERROR] hbase-shell-*.jar not found in %HBASE_LIB_DIR%
    echo         Is HBase installed at %HBASE_HOME% ?
    exit /b 1
)
"%JAVA_HOME%\bin\java" -cp "%HBASE_SHELL_CP%" %HBASE_OPTS% -Xmx512m ^
  org.jruby.Main -X+O "jar:file:%HBASE_SHELL_JAR%!/jar-bootstrap.rb" %2 %3 %4 %5
goto :eof

:do_master
"%JAVA_HOME%\bin\java" -cp "%HBASE_FULL_CP%" %HBASE_OPTS% org.apache.hadoop.hbase.master.HMaster start %2 %3 %4 %5
goto :eof

:do_regionserver
"%JAVA_HOME%\bin\java" -cp "%HBASE_FULL_CP%" %HBASE_OPTS% org.apache.hadoop.hbase.regionserver.HRegionServer start %2 %3 %4 %5
goto :eof

:do_version
"%JAVA_HOME%\bin\java" -cp "%HBASE_FULL_CP%" %HBASE_OPTS% org.apache.hadoop.hbase.util.VersionInfo
goto :eof

:do_classpath
echo %HBASE_SHELL_CP%
goto :eof
"@

# start-hbase.cmd
$startHBaseCmdContent = @"
@echo off
@rem Start HBase Master (and embedded ZooKeeper) on Windows
@rem Generated by install-hbase.ps1  |  Author: VANSH RANA
setlocal

if not defined HBASE_HOME set HBASE_HOME=$INSTALL_DIR
if not defined JAVA_HOME  set JAVA_HOME=$javaHomeShort

if exist "%HBASE_HOME%\conf\hbase-env.cmd" call "%HBASE_HOME%\conf\hbase-env.cmd"

set HBASE_LIB_DIR=%HBASE_HOME%\lib
set HBASE_CONF_DIR=%HBASE_HOME%\conf

@rem Full classpath including ALL lib subdirs - lib\* alone misses slf4j
@rem which lives in lib\client-facing-thirdparty\ in HBase 2.x
set HBASE_CLASSPATH=%HBASE_CONF_DIR%;%HBASE_LIB_DIR%\*;%HBASE_LIB_DIR%\client-facing-thirdparty\*;%HBASE_LIB_DIR%\shaded-clients\*;%HBASE_LIB_DIR%\zkcli\*;%HBASE_LIB_DIR%\trace\*;%HBASE_LIB_DIR%\ruby\*

if not exist "%HBASE_HOME%\logs" mkdir "%HBASE_HOME%\logs"

@rem Apply heap from hbase-env.cmd (JAVA_HEAP_MAX=-Xmx1024m) then append log/identity opts
@rem NOTE: use %HBASE_OPTS% (append) not a bare = (reset) so env.cmd opts are preserved
set HBASE_OPTS=%HBASE_OPTS% %JAVA_HEAP_MAX%
set HBASE_OPTS=%HBASE_OPTS% -Dhbase.log.dir=%HBASE_HOME%\logs
set HBASE_OPTS=%HBASE_OPTS% -Dhbase.log.file=hbase-master.log
set HBASE_OPTS=%HBASE_OPTS% -Dhbase.home.dir=%HBASE_HOME%
set HBASE_OPTS=%HBASE_OPTS% -Dhbase.id.str=%USERNAME%
set HBASE_OPTS=%HBASE_OPTS% -Dhbase.root.logger=INFO,RFA

echo Starting HBase Master...
echo HBase Web UI will be at: http://localhost:16010
echo Press Ctrl+C to stop.
echo.

"%JAVA_HOME%\bin\java" -cp "%HBASE_CLASSPATH%" %HBASE_OPTS% org.apache.hadoop.hbase.master.HMaster start
"@

# stop-hbase.cmd
$stopHBaseCmdContent = @"
@echo off
@rem Stop all HBase processes (kills java.exe processes running HBase)
@rem Generated by install-hbase.ps1  |  Author: VANSH RANA
echo Stopping HBase...
for /f "tokens=1" %%p in ('jps 2^>nul ^| findstr /i "HMaster HRegionServer HQuorumPeer"') do (
    echo   Killing PID %%p
    taskkill /PID %%p /F >nul 2>&1
)
echo HBase stopped.
"@

# Write .cmd files as ASCII (no BOM possible with ASCII) to ensure cmd.exe compatibility
# Do NOT use UTF8 - PowerShell 5.1 UTF8 adds BOM which causes '∩╗┐@rem' error
$asciiEnc = [System.Text.Encoding]::ASCII

Write-Step "5.1" "Writing hbase.cmd launcher..."
[System.IO.File]::WriteAllText("$INSTALL_DIR\bin\hbase.cmd", $hbaseCmdContent, $asciiEnc)
Write-Success "hbase.cmd -> $INSTALL_DIR\bin\hbase.cmd"

Write-Step "5.2" "Writing start-hbase.cmd..."
[System.IO.File]::WriteAllText("$INSTALL_DIR\bin\start-hbase.cmd", $startHBaseCmdContent, $asciiEnc)
Write-Success "start-hbase.cmd -> $INSTALL_DIR\bin\start-hbase.cmd"

Write-Step "5.3" "Writing stop-hbase.cmd..."
[System.IO.File]::WriteAllText("$INSTALL_DIR\bin\stop-hbase.cmd", $stopHBaseCmdContent, $asciiEnc)
Write-Success "stop-hbase.cmd -> $INSTALL_DIR\bin\stop-hbase.cmd"

# Also fix the existing files in C:\hbase\bin if they already exist (immediate fix)
$alreadyInstalled = @(
    "$INSTALL_DIR\bin\hbase.cmd",
    "$INSTALL_DIR\bin\start-hbase.cmd",
    "$INSTALL_DIR\bin\stop-hbase.cmd",
    "$INSTALL_DIR\conf\hbase-env.cmd"
)
foreach ($f in $alreadyInstalled) {
    if (Test-Path $f) {
        $raw = [System.IO.File]::ReadAllBytes($f)
        # Strip UTF-8 BOM (EF BB BF) if present
        if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) {
            $stripped = $raw[3..($raw.Length - 1)]
            [System.IO.File]::WriteAllBytes($f, $stripped)
            Write-Success "BOM stripped from: $(Split-Path $f -Leaf)"
        }
    }
}

# ============================================================================
#  STEP 6: HDFS DIRECTORIES FOR HBASE
# ============================================================================

Write-Banner "STEP 6: HDFS Directories for HBase"

if ($HADOOP_HOME) {
    Write-Host "  Checking HDFS availability..." -ForegroundColor Gray
    $hdfsReady = $false
    try {
        & "$HADOOP_HOME\bin\hdfs.cmd" dfs -ls / 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $safeModeOut = (& "$HADOOP_HOME\bin\hdfs.cmd" dfsadmin -safemode get 2>&1) -join " "
            if ($safeModeOut -match 'Safe mode is OFF') {
                $hdfsReady = $true
                Write-Success "HDFS is running and safe mode is OFF"
            }
            else {
                Write-Warn "HDFS is in safe mode. Skipping HDFS directory creation."
            }
        }
        else {
            Write-Warn "HDFS not reachable (exit $LASTEXITCODE). Skipping HDFS directory creation."
        }
    }
    catch {
        Write-Warn "Could not connect to HDFS: $_"
    }

    if ($hdfsReady) {
        # Set HADOOP_CLASSPATH so HBase can talk to HDFS
        $env:HADOOP_CLASSPATH = (& "$HADOOP_HOME\bin\hadoop.cmd" classpath 2>$null) |
            Where-Object { $_ } | Select-Object -Last 1

        Write-Step "6.1" "Creating /hbase on HDFS..."
        & "$HADOOP_HOME\bin\hdfs.cmd" dfs -mkdir -p /hbase 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "hdfs mkdir /hbase failed (exit $LASTEXITCODE) - run manually after HDFS starts" }
        & "$HADOOP_HOME\bin\hdfs.cmd" dfs -chmod 755 /hbase 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "hdfs chmod /hbase failed (exit $LASTEXITCODE)" }
        else { Write-Success "HDFS /hbase ready (chmod 755)" }

        Write-Step "6.2" "Creating /tmp/hbase on HDFS..."
        & "$HADOOP_HOME\bin\hdfs.cmd" dfs -mkdir -p /tmp/hbase 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "hdfs mkdir /tmp/hbase failed (exit $LASTEXITCODE) - run manually after HDFS starts" }
        & "$HADOOP_HOME\bin\hdfs.cmd" dfs -chmod 1777 /tmp/hbase 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "hdfs chmod /tmp/hbase failed (exit $LASTEXITCODE)" }
        else { Write-Success "HDFS /tmp/hbase ready (chmod 1777)" }
    }
    else {
        Write-Warn "Start HDFS first, then run these commands manually:"
        Write-Host "    hdfs dfs -mkdir -p /hbase" -ForegroundColor Cyan
        Write-Host "    hdfs dfs -chmod 755 /hbase" -ForegroundColor Cyan
        Write-Host "    hdfs dfs -mkdir -p /tmp/hbase" -ForegroundColor Cyan
        Write-Host "    hdfs dfs -chmod 1777 /tmp/hbase" -ForegroundColor Cyan
    }
}
else {
    Write-Success "Standalone mode - no HDFS directories needed"
}

# ============================================================================
#  STEP 7: WINDOWS FIREWALL RULES
# ============================================================================

Write-Banner "STEP 7: Windows Firewall Rules"

$firewallPorts = @(
    @{ Port = 16000; Name = "HBase-Master-RPC"; Description = "HBase Master RPC" },
    @{ Port = 16010; Name = "HBase-Master-WebUI"; Description = "HBase Master Web UI" },
    @{ Port = 16020; Name = "HBase-RegionServer-RPC"; Description = "HBase RegionServer RPC" },
    @{ Port = 16030; Name = "HBase-RegionServer-WebUI"; Description = "HBase RegionServer Web UI" },
    @{ Port = 2181; Name = "HBase-ZooKeeper"; Description = "ZooKeeper client port" }
)

foreach ($fw in $firewallPorts) {
    try {
        $existing = Get-NetFirewallRule -DisplayName $fw.Name -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetFirewallRule -DisplayName $fw.Name -Direction Inbound -Protocol TCP `
                -LocalPort $fw.Port -Action Allow -ErrorAction Stop | Out-Null
            Write-Success "Firewall rule added: $($fw.Name) (port $($fw.Port))"
        }
        else {
            Write-Success "Firewall rule already exists: $($fw.Name)"
        }
    }
    catch {
        Write-Warn "Could not add firewall rule for $($fw.Name): $($_.Exception.Message.Split([char]10)[0])"
    }
}

# ============================================================================
#  STEP 8: VERIFICATION
# ============================================================================

Write-Banner "STEP 8: Installation Verification"

$allGood = $true

# Check binaries exist
$checks = @(
    @{ Path = "$INSTALL_DIR\bin\hbase.cmd"; Label = "hbase.cmd launcher" },
    @{ Path = "$INSTALL_DIR\bin\start-hbase.cmd"; Label = "start-hbase.cmd" },
    @{ Path = "$INSTALL_DIR\bin\stop-hbase.cmd"; Label = "stop-hbase.cmd" },
    @{ Path = "$INSTALL_DIR\conf\hbase-env.cmd"; Label = "hbase-env.cmd" },
    @{ Path = "$INSTALL_DIR\conf\hbase-site.xml"; Label = "hbase-site.xml" },
    @{ Path = "$INSTALL_DIR\lib"; Label = "lib directory" }
)

foreach ($chk in $checks) {
    if (Test-Path $chk.Path) {
        Write-Success "$($chk.Label): OK"
    }
    else {
        Write-Err "$($chk.Label): MISSING - $($chk.Path)"
        $allGood = $false
    }
}

# Check env vars
$hbaseHomeEnv = [System.Environment]::GetEnvironmentVariable("HBASE_HOME", "Machine")
if ($hbaseHomeEnv -eq $INSTALL_DIR) {
    Write-Success "HBASE_HOME env var: OK ($hbaseHomeEnv)"
}
else {
    Write-Warn "HBASE_HOME env var not confirmed. Current value: $hbaseHomeEnv"
}

$javaHomeEnv = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
if ($javaHomeEnv -and (Test-Path "$javaHomeEnv\bin\java.exe")) {
    Write-Success "JAVA_HOME env var: OK ($javaHomeEnv)"
}
else {
    Write-Warn "JAVA_HOME env var missing or invalid. Current value: $javaHomeEnv"
}

$systemPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$pathEntries = ($systemPath -split ';') | ForEach-Object { $_.Trim() }
if ($pathEntries -contains "$INSTALL_DIR\bin") {
    Write-Success "PATH contains HBase bin: OK"
}
else {
    Write-Warn "PATH may not contain HBase bin. Check manually."
}

# Check data directories
foreach ($d in @($HBASE_DATA_DIR, "$HBASE_DATA_DIR\logs", "$HBASE_DATA_DIR\tmp", "$HBASE_DATA_DIR\root", "$HBASE_DATA_DIR\zookeeper")) {
    if (Test-Path $d) { Write-Success "Data dir: $d" }
    else { Write-Warn "Data dir missing: $d" }
}

# ============================================================================
#  FINAL SUMMARY
# ============================================================================

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  HBASE INSTALLATION COMPLETE" -NoNewline -ForegroundColor Green
Write-Host "                      by VANSH RANA" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host ""
Write-Host "  HBase Version  : $HBASE_VERSION" -ForegroundColor White
Write-Host "  Install Dir    : $INSTALL_DIR" -ForegroundColor White
Write-Host "  Data Dir       : $HBASE_DATA_DIR" -ForegroundColor White
Write-Host "  Mode           : $(if ($HADOOP_HOME) { 'HDFS-backed (pseudo-distributed)' } else { 'Standalone (local filesystem)' })" -ForegroundColor White
Write-Host "  Log Dir        : $HBASE_DATA_DIR\logs" -ForegroundColor White
Write-Host ""
Write-Host "  IMPORTANT: Open a NEW PowerShell/CMD window for env vars to take effect!" -ForegroundColor Yellow
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan

if ($HADOOP_HOME) {
    Write-Host "  1. Start Hadoop first:" -ForegroundColor White
    Write-Host "       start-dfs.cmd" -ForegroundColor DarkCyan
    Write-Host "       start-yarn.cmd" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  2. Verify /hbase exists on HDFS (auto-created if HDFS was running):" -ForegroundColor White
    Write-Host "       hadoop fs -ls /hbase" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  3. Start HBase:" -ForegroundColor White
    Write-Host "       cd $INSTALL_DIR\bin" -ForegroundColor DarkCyan
    Write-Host "       .\start-hbase.cmd" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  4. Open HBase Shell:" -ForegroundColor White
    Write-Host "       .\hbase.cmd shell" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  5. HBase Master Web UI:" -ForegroundColor White
    Write-Host "       http://localhost:16010" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  6. Quick test in HBase Shell:" -ForegroundColor White
    Write-Host "       hbase> status" -ForegroundColor DarkCyan
    Write-Host "       hbase> create 'test', 'cf'" -ForegroundColor DarkCyan
    Write-Host "       hbase> put 'test', 'row1', 'cf:a', 'value1'" -ForegroundColor DarkCyan
    Write-Host "       hbase> scan 'test'" -ForegroundColor DarkCyan
    Write-Host "       hbase> exit" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  7. Stop HBase:" -ForegroundColor White
    Write-Host "       .\stop-hbase.cmd" -ForegroundColor DarkCyan
}
else {
    Write-Host "  1. Start HBase (standalone mode):" -ForegroundColor White
    Write-Host "       cd $INSTALL_DIR\bin" -ForegroundColor DarkCyan
    Write-Host "       .\start-hbase.cmd" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  2. Open HBase Shell:" -ForegroundColor White
    Write-Host "       .\hbase.cmd shell" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  3. HBase Master Web UI:" -ForegroundColor White
    Write-Host "       http://localhost:16010" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  4. Quick test in HBase Shell:" -ForegroundColor White
    Write-Host "       hbase> status" -ForegroundColor DarkCyan
    Write-Host "       hbase> create 'test', 'cf'" -ForegroundColor DarkCyan
    Write-Host "       hbase> put 'test', 'row1', 'cf:a', 'value1'" -ForegroundColor DarkCyan
    Write-Host "       hbase> scan 'test'" -ForegroundColor DarkCyan
    Write-Host "       hbase> exit" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  5. Stop HBase:" -ForegroundColor White
    Write-Host "       .\stop-hbase.cmd" -ForegroundColor DarkCyan
}
Write-Host ""

if (-not $allGood) {
    Write-Warn "Some checks above failed. Review errors before starting HBase."
}
else {
    Write-Success "All checks passed. HBase is ready to use!"
}

# Cleanup prompt - delete only downloads, not the log
if (Confirm-Continue "Delete temporary download files (archive, 7-Zip installer)?") {
    $filesToClean = @(
        "$TEMP_DIR\hbase-$HBASE_VERSION-bin.tar.gz",
        "$TEMP_DIR\7z_installer.exe"
    )
    foreach ($f in $filesToClean) {
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path "$TEMP_DIR\hbase-extract") { Remove-Item "$TEMP_DIR\hbase-extract" -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path "$TEMP_DIR\7z-extract")    { Remove-Item "$TEMP_DIR\7z-extract"    -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Success "Temp download files cleaned up (log file kept)"
}

Write-Host ""
Write-Host "  [LOG] Full transcript saved to: $_logFile" -ForegroundColor DarkGray

Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
