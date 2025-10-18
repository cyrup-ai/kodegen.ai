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

# Track installation state for rollback
$script:InstallationState = @{
    McpServerInstalled = $false
    DaemonInstalled = $false
}

# Cleanup function
function Cleanup {
    if ($global:TempDir -and (Test-Path $global:TempDir)) {
        Write-Info "Cleaning up temporary directory: $global:TempDir"
        Remove-Item -Path $global:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Rollback partial installation on failure
function Rollback-Installation {
    param([string]$Reason)
    
    Write-Host ""
    Write-Error "Installation failed: $Reason"
    Write-Host ""
    Write-Warn "Rolling back partial installation..."
    Write-Host ""
    
    # Remove installed binaries in reverse order
    if ($script:InstallationState.DaemonInstalled) {
        Write-Info "Removing installed daemon..."
        $daemonPath = "$env:USERPROFILE\.cargo\bin\kodegend.exe"
        if (Test-Path $daemonPath) {
            Remove-Item $daemonPath -Force -ErrorAction SilentlyContinue
            Write-Success "Daemon removed"
        }
    }
    
    if ($script:InstallationState.McpServerInstalled) {
        Write-Info "Removing installed MCP server..."
        $serverPath = "$env:USERPROFILE\.cargo\bin\kodegen.exe"
        if (Test-Path $serverPath) {
            Remove-Item $serverPath -Force -ErrorAction SilentlyContinue
            Write-Success "MCP server removed"
        }
    }
    
    Write-Host ""
    Write-Success "Rollback completed - system restored to pre-installation state"
    Write-Host ""
    Write-Info "Please review the error above and try again"
    Write-Info "If the issue persists, please report it:"
    Write-Dim "  https://github.com/cyrup-ai/kodegen/issues"
    Write-Host ""
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
        throw "Git is required but not found"
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
            throw "Failed to download rustup installer"
        }
        
        # Verify it's actually an executable
        if (-not (Test-Path $rustupPath)) {
            Write-Error "Downloaded file not found at expected location"
            throw "Downloaded rustup installer not found"
        }
        
        $fileExt = [System.IO.Path]::GetExtension($rustupPath)
        if ($fileExt -ne ".exe") {
            Write-Error "Downloaded file is not a valid executable (extension: $fileExt)"
            Remove-Item $rustupPath -Force -ErrorAction SilentlyContinue
            throw "Downloaded file is not a valid executable"
        }
        
        # Run installer
        Write-Info "Running rustup installer..."
        try {
            & $rustupPath -y --default-toolchain nightly
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Rustup installer returned exit code $LASTEXITCODE"
                throw "Rustup installation failed"
            }
        } catch {
            Write-Error "Rustup installation failed: $($_.Exception.Message)"
            throw
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
            throw "Failed to install Rust toolchain"
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
            throw "Nightly toolchain verification failed"
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
        throw "Failed to create temporary directory: $($_.Exception.Message)"
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
        throw "Git clone failed with exit code $LASTEXITCODE"
    }
    
    # Verify directory was created
    if (-not (Test-Path $repoDir)) {
        Write-Error "Clone appeared successful but directory not found: $repoDir"
        throw "Clone appeared successful but directory not found"
    }
    
    Set-Location $repoDir
    
    # Verify it's a valid git repository
    $isGitRepo = Test-Path ".git"
    if (-not $isGitRepo) {
        Write-Error "Cloned directory is not a valid git repository"
        throw "Cloned directory is not a valid git repository"
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
        throw "Clone incomplete - missing required files"
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
            $script:InstallationState.McpServerInstalled = $true
        } else {
            Write-Error "MCP server installation verification failed"
            Write-Info "Build appeared successful but binary is not working"
            Write-Info "Build log: $logFile"
            throw "MCP server installation verification failed"
        }
    } else {
        Write-Host ""
        Write-Error "MCP server installation failed (exit code: $LASTEXITCODE)"
        Write-Host ""
        Write-Info "Build log saved to: $logFile"
        Write-Info "Please review the log and report issues at:"
        Write-Dim "  https://github.com/cyrup-ai/kodegen/issues"
        Write-Host ""
        throw "MCP server installation failed (exit code: $LASTEXITCODE)"
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
            $script:InstallationState.DaemonInstalled = $true
        } else {
            Write-Error "Daemon installation verification failed"
            Write-Info "Build appeared successful but binary is not working"
            Write-Info "Build log: $logFile"
            throw "Daemon installation verification failed"
        }
    } else {
        Write-Host ""
        Write-Error "Daemon installation failed (exit code: $LASTEXITCODE)"
        Write-Host ""
        Write-Info "Build log saved to: $logFile"
        Write-Info "Please review the log and report issues at:"
        Write-Dim "  https://github.com/cyrup-ai/kodegen/issues"
        Write-Host ""
        throw "Daemon installation failed (exit code: $LASTEXITCODE)"
    }
    
    Write-Host ""
    Write-Success "All binaries compiled, installed, and verified! ✓"
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

# Check if running with administrator privileges
function Test-IsAdmin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator
    return $principal.IsInRole($adminRole)
}

# Check if user can elevate to administrator
function Test-CanElevate {
    # Check if current user is in Administrators group
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator
    
    if ($principal.IsInRole($adminRole)) {
        return $true
    }
    
    # Check if user account has admin rights (even if not elevated)
    $user = $currentUser.Name
    try {
        $adminGroup = [ADSI]"WinNT://./Administrators,group"
        $members = $adminGroup.Invoke("Members") | ForEach-Object {
            $_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)
        }
        
        $userName = $user.Split('\')[-1]
        return $members -contains $userName
    } catch {
        # If we can't check, assume elevation is possible
        return $true
    }
}

# Install and start daemon service
function Install-DaemonService {
    Write-Info "Installing daemon service..."

    # Ensure kodegend is available
    $cargoPath = "$env:USERPROFILE\.cargo\bin"
    $env:PATH = "$cargoPath;$env:PATH"
    
    $kodegendPath = "$cargoPath\kodegend.exe"
    if (-not (Test-Path $kodegendPath)) {
        Write-Error "kodegend binary not found at $kodegendPath"
        Write-Info "Please ensure daemon was installed correctly"
        return
    }
    
    # Check if service already installed
    try {
        $serviceStatus = kodegend status 2>&1
        if ($LASTEXITCODE -eq 0 -and $serviceStatus -match "running|installed") {
            Write-Success "Daemon service is already installed and running"
            return
        }
    } catch {
        # Service not installed, continue
    }
    
    # Check if we can elevate
    $isAdmin = Test-IsAdmin
    $canElevate = Test-CanElevate
    
    if ($isAdmin) {
        Write-Info "Running with administrator privileges..."
    } elseif ($canElevate) {
        Write-Host ""
        Write-Info "The daemon service requires administrator privileges to install."
        Write-Host ""
        Write-Bold "What is the daemon service?"
        Write-Dim "  • Runs in the background to keep your MCP configuration up-to-date"
        Write-Dim "  • Optional - you can skip this and run 'kodegen install' manually when needed"
        Write-Host ""
        
        $response = Read-Host "Install daemon service now? You'll be prompted for admin rights (Y/n)"
        
        if ($response -eq 'n' -or $response -eq 'N') {
            Write-Info "Skipping daemon service installation"
            Write-Dim "You can install it later with: kodegend install"
            return
        }
        
        Write-Host ""
        Write-Info "You will now be prompted for administrator privileges..."
    } else {
        Write-Warn "Administrator privileges not available on this account"
        Write-Info "Skipping daemon service installation"
        Write-Dim "To install daemon, run as administrator: kodegend install"
        return
    }
    
    # Attempt installation
    Write-Info "Installing daemon service (this may take a moment)..."
    Write-Host ""
    
    try {
        # Capture output for better error reporting
        $output = kodegend install 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            Write-Success "Daemon service installed and started!"
            
            # Verify service is running
            Start-Sleep -Seconds 2
            $serviceStatus = kodegend status 2>&1
            if ($serviceStatus -match "running") {
                Write-Dim "  Service status: Running"
            } else {
                Write-Warn "Service installed but may not be running"
                Write-Dim "  Check with: kodegend status"
            }
            
        } elseif ($output -match "access.*denied|privilege|administrator") {
            Write-Warn "Administrator privileges were denied or insufficient"
            Write-Info "Daemon service installation skipped"
            Write-Info "To install later, run as administrator: kodegend install"
            
        } elseif ($output -match "already.*installed|already.*exists") {
            Write-Success "Daemon service is already installed"
            
        } else {
            Write-Warn "Daemon service installation failed (exit code: $exitCode)"
            Write-Host ""
            Write-Info "Error details:"
            Write-Dim ($output | Out-String)
            Write-Host ""
            Write-Info "You can try installing manually later with: kodegend install"
        }
        
    } catch {
        Write-Warn "Daemon service installation encountered an error"
        Write-Dim "Error: $($_.Exception.Message)"
        Write-Info "You can try installing manually later with: kodegend install"
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
    } catch {
        # Trigger rollback on any failure
        Rollback-Installation -Reason $_.Exception.Message
        exit 1
    } finally {
        Cleanup
    }
}

# Run main function
Main
