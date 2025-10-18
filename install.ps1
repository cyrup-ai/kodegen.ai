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
        
        # Add cargo to PATH for current session
        $cargoPath = "$env:USERPROFILE\.cargo\bin"
        $env:PATH = "$cargoPath;$env:PATH"
        
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
    try {
        git clone --depth 1 https://github.com/cyrup-ai/kodegen.git 2>&1 | Out-Null
        Set-Location kodegen
        Write-Success "Repository cloned successfully"
    } catch {
        Write-Error "Failed to clone repository"
        exit 1
    }
}

# Install the project using cargo
function Install-Project {
    Write-Info "Installing KODEGEN.ᴀɪ MCP server (this may take a few minutes)..."

    # Navigate to the server package
    Set-Location packages\server

    # Install the MCP server binary to %USERPROFILE%\.cargo\bin
    $installResult = cargo install --path .
    if ($LASTEXITCODE -eq 0) {
        Write-Success "KODEGEN.ᴀɪ MCP server installed successfully!"
    } else {
        Write-Error "MCP server installation failed"
        exit 1
    }

    # Navigate to the daemon package
    Write-Info "Installing KODEGEN.ᴀɪ daemon..."
    Set-Location ..\daemon

    # Install the daemon binary to %USERPROFILE%\.cargo\bin
    $installResult = cargo install --path .
    if ($LASTEXITCODE -eq 0) {
        Write-Success "KODEGEN.ᴀɪ daemon installed successfully!"
    } else {
        Write-Error "Daemon installation failed"
        exit 1
    }
}

# Auto-configure all detected MCP clients
function Auto-Configure-Clients {
    Write-Info "Auto-configuring detected MCP clients..."

    # Ensure cargo bin is in PATH
    $cargoPath = "$env:USERPROFILE\.cargo\bin"
    $env:PATH = "$cargoPath;$env:PATH"

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

    # Ensure cargo bin is in PATH
    $cargoPath = "$env:USERPROFILE\.cargo\bin"
    $env:PATH = "$cargoPath;$env:PATH"

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
