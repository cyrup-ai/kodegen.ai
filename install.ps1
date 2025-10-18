# KODEGEN.ᴀɪ One-Line Installer for Windows
# Usage: iex (iwr -UseBasicParsing https://kodegen.ai/install.ps1).Content

# Enable strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Color output functions with fancy symbols
function Write-Info($Message) {
    Write-Host "▸" -ForegroundColor Cyan -NoNewline
    Write-Host " $Message"
}

function Write-Warn($Message) {
    Write-Host "⚠" -ForegroundColor Yellow -NoNewline
    Write-Host " $Message"
}

function Write-Error($Message) {
    Write-Host "✗" -ForegroundColor Red -NoNewline
    Write-Host " $Message" -ForegroundColor Red
}

function Write-Success($Message) {
    Write-Host "✓" -ForegroundColor Green -NoNewline
    Write-Host " $Message" -ForegroundColor Green
}

function Write-Dim($Message) {
    Write-Host $Message -ForegroundColor DarkGray
}

function Write-Bold($Message) {
    Write-Host $Message -ForegroundColor White
}

# Cleanup function
function Cleanup {
    if ($global:TempDir -and (Test-Path $global:TempDir)) {
        Write-Info "Cleaning up temporary directory: $global:TempDir"
        Remove-Item -Path $global:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# Platform detection
function Detect-Platform {
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "i686" }
    $global:Platform = "$arch-pc-windows-msvc"
    Write-Info "Detected platform: $global:Platform"
}

# Check for required commands
function Check-Requirements {
    Write-Info "Checking system requirements..."
    
    # Check for git
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "Git is required but not found"
        Write-Info "Install git from: https://git-scm.com/downloads"
        exit 1
    }
    
    # Check for curl (should be available on Windows 10+)
    if (-not (Get-Command curl -ErrorAction SilentlyContinue)) {
        Write-Warn "curl not found, but may not be needed"
    }
    
    Write-Success "System requirements satisfied"
}

# Robust download function with retry logic
function Download-WithRetry {
    param(
        [string]$Url,
        [string]$OutFile,
        [int]$MaxRetries = 3,
        [int]$TimeoutSec = 30,
        [string]$ExpectedHash = $null,
        [int64]$MinSizeBytes = 0
    )
    
    $attempt = 0
    $success = $false
    
    while (-not $success -and $attempt -lt $MaxRetries) {
        $attempt++
        
        try {
            Write-Info "Downloading from $Url (attempt $attempt/$MaxRetries)..."
            
            # Download with timeout and basic parsing
            $response = Invoke-WebRequest `
                -Uri $Url `
                -OutFile $OutFile `
                -TimeoutSec $TimeoutSec `
                -UseBasicParsing `
                -ErrorAction Stop
            
            # Verify download succeeded and file exists
            if (-not (Test-Path $OutFile)) {
                Write-Warn "Download completed but file not found at $OutFile"
                continue
            }
            
            # Verify file size is reasonable
            $fileInfo = Get-Item $OutFile
            $fileSize = $fileInfo.Length
            if ($MinSizeBytes -gt 0 -and $fileSize -lt $MinSizeBytes) {
                Write-Warn "Downloaded file is suspiciously small: $fileSize bytes (minimum: $MinSizeBytes bytes)"
                Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                continue
            }
            
            # Verify hash if provided
            if ($ExpectedHash) {
                $actualHash = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
                if ($actualHash -ne $ExpectedHash) {
                    Write-Warn "Hash mismatch! Expected: $ExpectedHash, Got: $actualHash"
                    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                    continue
                }
                Write-Success "Hash verification passed"
            }
            
            $success = $true
            Write-Success "Download completed successfully ($fileSize bytes)"
            return $true
            
        } catch {
            Write-Warn "Download attempt $attempt failed: $($_.Exception.Message)"
            
            # Clean up failed download
            if (Test-Path $OutFile) {
                Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            }
            
            if ($attempt -lt $MaxRetries) {
                $waitSeconds = $attempt * 2  # Exponential backoff
                Write-Info "Waiting $waitSeconds seconds before retry..."
                Start-Sleep -Seconds $waitSeconds
            }
        }
    }
    
    # If we get here, all retries failed
    Write-Error "Download failed after $MaxRetries attempts"
    return $false
}

# Add a path to the persistent user PATH environment variable
function Add-ToPersistentPath {
    param([string]$PathToAdd)
    
    # Get current user PATH from registry
    $regPath = "HKCU:\Environment"
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    
    # Check if already in PATH
    if ($currentPath -split ';' -contains $PathToAdd) {
        Write-Info "Already in PATH: $PathToAdd"
        return
    }
    
    # Add to PATH
    $newPath = "$PathToAdd;$currentPath"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    
    # Also update current session
    $env:PATH = "$PathToAdd;$env:PATH"
    
    Write-Success "Added to PATH: $PathToAdd"
    Write-Warn "PATH changes take effect in new shells"
}

# Install Rust nightly toolchain
function Install-Rust {
    if (-not (Get-Command rustc -ErrorAction SilentlyContinue)) {
        Write-Info "Installing Rust nightly toolchain..."
        
        # Download and run rustup-init
        $rustupUrl = "https://win.rustup.rs/x86_64"
        $rustupPath = "$env:TEMP\rustup-init.exe"
        
        # Use robust download with retry (rustup-init is typically 8-10MB)
        $downloadSuccess = Download-WithRetry `
            -Url $rustupUrl `
            -OutFile $rustupPath `
            -MaxRetries 3 `
            -TimeoutSec 30 `
            -MinSizeBytes 1MB
        
        if (-not $downloadSuccess) {
            Write-Error "Failed to download rustup installer"
            Write-Dim "Please check your internet connection and try again"
            Write-Info "Manual download: $rustupUrl"
            exit 1
        }
        
        # Verify it's actually an executable
        if (-not (Test-Path $rustupPath)) {
            Write-Error "Downloaded file not found at expected location"
            exit 1
        }
        
        $fileExt = [System.IO.Path]::GetExtension($rustupPath)
        if ($fileExt -ne ".exe") {
            Write-Error "Downloaded file is not a valid executable (extension: $fileExt)"
            Remove-Item $rustupPath -Force -ErrorAction SilentlyContinue
            exit 1
        }
        
        # Run installer
        Write-Info "Running rustup installer..."
        try {
            & $rustupPath -y --default-toolchain nightly
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Rustup installer returned exit code $LASTEXITCODE"
                exit 1
            }
        } catch {
            Write-Error "Rustup installation failed: $($_.Exception.Message)"
            exit 1
        } finally {
            # Always cleanup installer
            if (Test-Path $rustupPath) {
                Remove-Item $rustupPath -Force -ErrorAction SilentlyContinue
            }
        }
        
        # Add cargo bin to persistent PATH
        $cargoPath = "$env:USERPROFILE\.cargo\bin"
        Add-ToPersistentPath -PathToAdd $cargoPath
        
        # Verify installation
        if (Get-Command rustc -ErrorAction SilentlyContinue) {
            Write-Success "Rust nightly installed: $(rustc --version)"
        } else {
            Write-Error "Failed to install Rust toolchain"
            exit 1
        }
    } else {
        # Rust exists - check nightly availability
        Write-Info "Rust toolchain found: $(rustc --version)"
        
        # Check if nightly is installed
        $toolchains = rustup toolchain list
        $nightlyInstalled = $toolchains | Select-String "nightly"
        
        if (-not $nightlyInstalled) {
            Write-Info "Installing nightly toolchain (your default will not be changed)..."
            rustup toolchain install nightly
            Write-Success "Nightly toolchain installed"
        } else {
            Write-Success "Nightly toolchain already available"
            
            # Optionally check if update needed
            Write-Info "Checking for nightly updates..."
            rustup update nightly 2>&1 | Out-Null
        }
        
        # Verify nightly works
        $nightlyVersion = rustup run nightly rustc --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Nightly toolchain ready: $nightlyVersion"
        } else {
            Write-Error "Nightly toolchain verification failed"
            exit 1
        }
        
        # Ensure cargo bin is in persistent PATH
        $cargoPath = "$env:USERPROFILE\.cargo\bin"
        Add-ToPersistentPath -PathToAdd $cargoPath
    }
}


# Clone the repository
function Clone-Repository {
    Write-Info "Cloning KODEGEN.ᴀɪ repository..."
    
    # Use GUID for guaranteed uniqueness
    $uniqueId = [guid]::NewGuid().ToString()
    $global:TempDir = Join-Path $env:TEMP "kodegen-$uniqueId"
    
    try {
        # New-Item with -Force handles race condition
        New-Item -ItemType Directory -Path $global:TempDir -Force -ErrorAction Stop | Out-Null
        Set-Location $global:TempDir
        
    } catch {
        Write-Error "Failed to create temporary directory: $($_.Exception.Message)"
        exit 1
    }
    
    # Clone with HTTPS (most compatible)
    $repoUrl = "https://github.com/cyrup-ai/kodegen.git"
    $repoDir = "kodegen"
    
    Write-Info "Cloning from $repoUrl..."
    
    # Clone with visible output for debugging
    git clone --depth 1 --progress $repoUrl 2>&1 | ForEach-Object {
        if ($_ -match "Receiving objects|Resolving deltas") {
            Write-Progress -Activity "Cloning repository" -Status $_
        }
    }
    
    # Check git exit code
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Git clone failed with exit code $LASTEXITCODE"
        Write-Info "Repository URL: $repoUrl"
        Write-Info "Check your internet connection and repository access"
        exit 1
    }
    
    # Verify directory was created
    if (-not (Test-Path $repoDir)) {
        Write-Error "Clone appeared successful but directory not found: $repoDir"
        exit 1
    }
    
    Set-Location $repoDir
    
    # Verify it's a valid git repository
    $isGitRepo = Test-Path ".git"
    if (-not $isGitRepo) {
        Write-Error "Cloned directory is not a valid git repository"
        exit 1
    }
    
    # Verify essential project files exist
    $requiredFiles = @(
        "Cargo.toml",
        "packages\server\Cargo.toml",
        "packages\daemon\Cargo.toml"
    )
    
    $missingFiles = @()
    foreach ($file in $requiredFiles) {
        if (-not (Test-Path $file)) {
            $missingFiles += $file
        }
    }
    
    if ($missingFiles.Count -gt 0) {
        Write-Error "Clone incomplete - missing required files:"
        foreach ($file in $missingFiles) {
            Write-Error "  - $file"
        }
        exit 1
    }
    
    # Get and display clone information
    $commitHash = git rev-parse --short HEAD 2>$null
    $commitDate = git log -1 --format=%cd --date=short 2>$null
    
    Write-Success "Repository cloned successfully"
    Write-Dim "  Commit: $commitHash"
    Write-Dim "  Date: $commitDate"
    Write-Dim "  Location: $(Get-Location)"
}

# Verify binary installation
function Test-BinaryInstalled {
    param(
        [string]$BinaryName,
        [string]$ExpectedPath = "$env:USERPROFILE\.cargo\bin\$BinaryName.exe"
    )
    
    Write-Info "Verifying $BinaryName installation..."
    
    # Check if file exists
    if (-not (Test-Path $ExpectedPath)) {
        Write-Error "Binary not found at expected location: $ExpectedPath"
        return $false
    }
    
    # Check file size (should be at least 1MB for Rust binaries)
    $fileSize = (Get-Item $ExpectedPath).Length
    if ($fileSize -lt 1MB) {
        Write-Error "Binary is suspiciously small: $fileSize bytes"
        return $false
    }
    
    # Check if it's actually an executable
    $extension = [System.IO.Path]::GetExtension($ExpectedPath)
    if ($extension -ne ".exe") {
        Write-Error "Binary has wrong extension: $extension"
        return $false
    }
    
    # Try to run with --version (most binaries support this)
    try {
        Write-Info "Testing $BinaryName execution..."
        
        # Use full path to avoid PATH issues
        $versionOutput = & $ExpectedPath --version 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -ne 0) {
            Write-Error "Binary exits with error code: $exitCode"
            Write-Dim "Output: $versionOutput"
            return $false
        }
        
        Write-Success "$BinaryName verified: $versionOutput"
        return $true
        
    } catch {
        Write-Error "Failed to execute binary: $($_.Exception.Message)"
        return $false
    }
}

# Install the project using cargo
function Install-Project {
    Write-Info "Installing KODEGEN.ᴀɪ MCP server (this may take several minutes)..."
    Write-Dim "Compiling Rust code... please wait patiently ☕"
    Write-Host ""

    # Create log directory
    $logDir = Join-Path $env:TEMP "kodegen-install-logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    
    # Navigate to the server package
    Set-Location packages\server

    # Install with output to both console and log file
    $logFile = Join-Path $logDir "mcp-server-install.log"
    Write-Dim "  Logging to: $logFile"
    Write-Host ""
    
    # Show output in real-time while logging
    cargo install --path . 2>&1 | Tee-Object -FilePath $logFile
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        
        # CRITICAL: Verify installation actually worked
        if (Test-BinaryInstalled -BinaryName "kodegen") {
            Write-Success "KODEGEN.ᴀɪ MCP server installed successfully!"
        } else {
            Write-Error "MCP server installation verification failed"
            Write-Info "Build appeared successful but binary is not working"
            Write-Info "Build log: $logFile"
            exit 1
        }
    } else {
        Write-Host ""
        Write-Error "MCP server installation failed (exit code: $LASTEXITCODE)"
        Write-Host ""
        Write-Info "Build log saved to: $logFile"
        Write-Info "Please review the log and report issues at:"
        Write-Dim "  https://github.com/cyrup-ai/kodegen/issues"
        Write-Host ""
        exit 1
    }

    # Navigate to the daemon package
    Write-Host ""
    Write-Info "Installing KODEGEN.ᴀɪ daemon..."
    Write-Dim "Compiling daemon code... ☕"
    Write-Host ""
    Set-Location ..\daemon

    $logFile = Join-Path $logDir "daemon-install.log"
    Write-Dim "  Logging to: $logFile"
    Write-Host ""
    
    cargo install --path . 2>&1 | Tee-Object -FilePath $logFile
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        
        if (Test-BinaryInstalled -BinaryName "kodegend") {
            Write-Success "KODEGEN.ᴀɪ daemon installed successfully!"
        } else {
            Write-Error "Daemon installation verification failed"
            Write-Info "Build appeared successful but binary is not working"
            Write-Info "Build log: $logFile"
            exit 1
        }
    } else {
        Write-Host ""
        Write-Error "Daemon installation failed (exit code: $LASTEXITCODE)"
        Write-Host ""
        Write-Info "Build log saved to: $logFile"
        Write-Info "Please review the log and report issues at:"
        Write-Dim "  https://github.com/cyrup-ai/kodegen/issues"
        Write-Host ""
        exit 1
    }
    
    Write-Host ""
    Write-Success "All binaries compiled and installed!"
    Write-Dim "Build logs preserved in: $logDir"
}

# Auto-configure all detected MCP clients
function Auto-Configure-Clients {
    Write-Info "Auto-configuring detected MCP clients..."

    # Run kodegen install
    try {
        kodegen install
        if ($LASTEXITCODE -eq 0) {
            Write-Success "MCP clients configured automatically!"
        } else {
            Write-Warn "Auto-configuration failed, you can run 'kodegen install' manually later"
        }
    } catch {
        Write-Warn "Auto-configuration failed, you can run 'kodegen install' manually later"
    }
}

# Install and start daemon service
function Install-DaemonService {
    Write-Info "Installing daemon service..."

    # Install daemon service (may require administrator privileges)
    Write-Info "You may be prompted for administrator privileges to install the system service..."
    try {
        kodegend install
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Daemon service installed and started!"
        } else {
            Write-Warn "Daemon service installation failed - auto-configuration will only run once"
            Write-Warn "You can manually install the daemon later with: kodegend install"
        }
    } catch {
        Write-Warn "Daemon service installation failed - auto-configuration will only run once"
        Write-Warn "You can manually install the daemon later with: kodegend install"
    }
}


# Main installation function
function Main {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                                            ║" -ForegroundColor Cyan
    Write-Host "║      ⚡  KODEGEN.ᴀɪ  INSTALLER             ║" -ForegroundColor Cyan
    Write-Host "║                                            ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    try {
        Detect-Platform
        Check-Requirements
        Install-Rust
        Clone-Repository
        Install-Project
        Auto-Configure-Clients
        Install-DaemonService

        Write-Host ""
        Write-Host "────────────────────────────────────────────" -ForegroundColor Cyan
        Write-Success "Installation completed! 🚀"
        Write-Host "────────────────────────────────────────────" -ForegroundColor Cyan
        Write-Host ""
        Write-Dim "Binary installed to: $env:USERPROFILE\.cargo\bin\kodegen.exe"
        Write-Host ""
        Write-Info "Your MCP clients have been automatically configured!"
        Write-Dim "Supported editors: Claude Desktop, Windsurf, Cursor, Zed, Roo Code"
        Write-Host ""
        Write-Bold "Next steps:"
        Write-Host "  1. Restart your editor/IDE"
        Write-Host "  2. Start coding with KODEGEN.ᴀɪ!"
        Write-Host ""
        Write-Dim "Manual configuration (if needed): kodegen install"
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║                                            ║" -ForegroundColor Green
        Write-Host "║   ⚡  Welcome to KODEGEN.ᴀɪ!               ║" -ForegroundColor Green
        Write-Host "║                                            ║" -ForegroundColor Green
        Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
    } finally {
        Cleanup
    }
}

# Run main function
Main
