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

# Install Rust nightly toolchain
function Install-Rust {
    if (-not (Get-Command rustc -ErrorAction SilentlyContinue)) {
        Write-Info "Installing Rust nightly toolchain..."
        
        # Download and run rustup-init
        $rustupUrl = "https://win.rustup.rs/x86_64"
        $rustupPath = "$env:TEMP\rustup-init.exe"
        
        Invoke-WebRequest -Uri $rustupUrl -OutFile $rustupPath
        & $rustupPath -y --default-toolchain nightly
        
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
        Write-Info "Rust toolchain found: $(rustc --version)"
        
        # Ensure nightly is installed
        $nightlyInstalled = rustup toolchain list | Select-String "nightly"
        if (-not $nightlyInstalled) {
            Write-Info "Installing nightly toolchain..."
            rustup toolchain install nightly
        }
        
        # Set nightly as default
        Write-Info "Ensuring nightly toolchain is available..."
        rustup default nightly
        Write-Success "Rust nightly toolchain ready: $(rustc --version)"
    }
}


# Clone the repository
function Clone-Repository {
    Write-Info "Cloning KODEGEN.ᴀɪ repository..."
    
    $global:TempDir = Join-Path $env:TEMP "kodegen-$(Get-Random)"
    New-Item -ItemType Directory -Path $global:TempDir | Out-Null
    Set-Location $global:TempDir
    
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
    Write-Info "Installing KODEGEN.ᴀɪ (this may take a few minutes)..."

    # Navigate to the server package
    Set-Location packages\server

    # Install the binary to %USERPROFILE%\.cargo\bin
    $installResult = cargo install --path .
    if ($LASTEXITCODE -eq 0) {
        Write-Success "KODEGEN.ᴀɪ installed successfully!"
    } else {
        Write-Error "Installation failed"
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


# Main installation function
function Main {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                                            ║" -ForegroundColor Cyan
    Write-Host "║      🍯  KODEGEN.ᴀɪ  INSTALLER             ║" -ForegroundColor Cyan
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
        Write-Host "║   🍯  Welcome to KODEGEN.ᴀɪ!               ║" -ForegroundColor Green
        Write-Host "║                                            ║" -ForegroundColor Green
        Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
    } finally {
        Cleanup
    }
}

# Run main function
Main
