#!/bin/bash
set -euo pipefail

# KODEGEN.ᴀɪ One-Line Installer
# Usage: curl -fsSL https://kodegen.ai/install.sh | bash

# Parse command-line arguments
FORCE_INSTALL=false
SKIP_DEPS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_INSTALL=true
            shift
            ;;
        --skip-deps)
            SKIP_DEPS=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            show_help() {
                cat <<EOF
KODEGEN.ᴀɪ Installer

Usage: install.sh [OPTIONS]

Options:
    --force         Force reinstall even if already installed
    --skip-deps     Skip system dependency installation
    --dry-run       Show what would be installed without doing it
    --help          Show this help message

Examples:
    # Normal install (skips if already installed)
    ./install.sh
    
    # Force reinstall
    ./install.sh --force
    
    # Update only (skip deps)
    ./install.sh --skip-deps
EOF
            }
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Color output functions
red() { echo -e "\033[0;31m$1\033[0m"; }
green() { echo -e "\033[0;32m$1\033[0m"; }
yellow() { echo -e "\033[0;33m$1\033[0m"; }
blue() { echo -e "\033[0;34m$1\033[0m"; }
cyan() { echo -e "\033[0;36m$1\033[0m"; }
bold() { echo -e "\033[1m$1\033[0m"; }
dim() { echo -e "\033[2m$1\033[0m"; }

# Logging functions with fancy symbols
info() { echo -e "\033[0;36m▸\033[0m $1"; }
warn() { echo -e "\033[0;33m⚠\033[0m $1"; }
error() { echo -e "\033[0;31m✗\033[0m $1"; }
success() { echo -e "\033[0;32m✓\033[0m $1"; }

# Cleanup function
cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        info "Cleaning up temporary directory..."
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Global variables for binary paths
KODEGEN_BIN=""
KODEGEND_BIN=""

# OS detection
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_LIKE="${ID_LIKE:-}"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        OS_LIKE=""
    else
        OS="unknown"
        OS_LIKE=""
    fi
    info "Detected OS: $OS"
}

# Platform detection
detect_platform() {
    local arch
    arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *) error "Unsupported architecture: $arch" && exit 1 ;;
    esac
    
    case "$OS" in
        linux) PLATFORM="$arch-unknown-linux-gnu" ;;
        darwin|macos) PLATFORM="$arch-apple-darwin" ;;
        *) error "Unsupported operating system: $OS" && exit 1 ;;
    esac
    
    info "Detected platform: $PLATFORM"
}

# Ensure cargo bin directory is in PATH
ensure_cargo_in_path() {
    local cargo_bin="$HOME/.cargo/bin"
    
    # Add to PATH if needed
    if [[ ":$PATH:" != *":$cargo_bin:"* ]]; then
        export PATH="$cargo_bin:$PATH"
    fi
    
    # Source cargo env
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi
}

# Verify binary is installed and executable
verify_binary_installed() {
    local bin_name="$1"
    local bin_path="$HOME/.cargo/bin/$bin_name"
    
    if [[ ! -f "$bin_path" ]]; then
        error "Binary not found: $bin_path"
        return 1
    fi
    
    if [[ ! -x "$bin_path" ]]; then
        error "Binary not executable: $bin_path"
        ls -la "$bin_path"
        return 1
    fi
    
    # Test execution
    if ! "$bin_path" --version >/dev/null 2>&1; then
        error "Binary exists but won't execute: $bin_path"
        return 1
    fi
    
    success "Verified: $bin_name at $bin_path"
    return 0
}

# Check for existing installation
check_existing_installation() {
    info "Checking for existing installation..."
    
    local has_kodegen=false
    local has_kodegend=false
    local kodegen_version=""
    local kodegend_version=""
    
    # Ensure cargo bin is in PATH
    ensure_cargo_in_path
    
    # Check for kodegen binary
    if command -v kodegen >/dev/null 2>&1; then
        has_kodegen=true
        kodegen_version=$(kodegen --version 2>/dev/null | awk '{print $2}' || echo "unknown")
    fi
    
    # Check for kodegend binary
    if command -v kodegend >/dev/null 2>&1; then
        has_kodegend=true
        kodegend_version=$(kodegend --version 2>/dev/null | awk '{print $2}' || echo "unknown")
    fi
    
    # If both binaries are installed and --force is not set, exit early
    if [[ "$has_kodegen" == true ]] && [[ "$has_kodegend" == true ]]; then
        success "KODEGEN.ᴀɪ already installed:"
        dim "  kodegen:  $kodegen_version"
        dim "  kodegend: $kodegend_version"
        
        if [[ "$FORCE_INSTALL" == false ]]; then
            echo ""
            info "Use --force to reinstall"
            exit 0
        else
            warn "Forcing reinstall..."
        fi
    elif [[ "$has_kodegen" == true ]] || [[ "$has_kodegend" == true ]]; then
        info "Partial installation detected, continuing with full installation..."
        if [[ "$has_kodegen" == true ]]; then
            dim "  kodegen:  $kodegen_version (installed)"
        fi
        if [[ "$has_kodegend" == true ]]; then
            dim "  kodegend: $kodegend_version (installed)"
        fi
    fi
}

# Helper function to check if a command is installed
check_command_installed() {
    command -v "$1" >/dev/null 2>&1
}

# Helper function to check if a Debian package is installed
check_debian_package() {
    dpkg -s "$1" >/dev/null 2>&1
}

# Helper function to check if an RPM package is installed
check_rpm_package() {
    rpm -q "$1" >/dev/null 2>&1
}

# Helper function to check if a header file exists
check_header_file() {
    [[ -f "$1" ]]
}

# Install system dependencies
install_deps() {
    if [[ "$SKIP_DEPS" == true ]]; then
        info "Skipping dependency installation (--skip-deps)"
        return 0
    fi
    
    info "Checking system dependencies..."
    
    local missing=()
    
    # Check common commands first
    if ! check_command_installed git; then
        missing+=("git")
    fi
    
    if ! check_command_installed curl; then
        missing+=("curl")
    fi
    
    # OS-specific dependency checks
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]] || [[ "$OS_LIKE" == *"debian"* ]]; then
        check_debian_package build-essential || missing+=("build-essential")
        check_debian_package pkg-config || missing+=("pkg-config")
        check_debian_package libssl-dev || missing+=("libssl-dev")
        
        if [[ ${#missing[@]} -eq 0 ]]; then
            success "All system dependencies present"
            return 0
        fi
        
        if [[ "$DRY_RUN" == true ]]; then
            info "Would install: ${missing[*]}"
            return 0
        fi
        
        info "Installing missing dependencies: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}"
    elif [[ "$OS" == "fedora" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "centos" ]]; then
        check_command_installed gcc || missing+=("gcc")
        check_command_installed g++ || missing+=("gcc-c++")
        check_command_installed make || missing+=("make")
        check_command_installed pkg-config || missing+=("pkgconfig")
        check_header_file /usr/include/openssl/ssl.h || missing+=("openssl-devel")
        
        if [[ ${#missing[@]} -eq 0 ]]; then
            success "All system dependencies present"
            return 0
        fi
        
        if [[ "$DRY_RUN" == true ]]; then
            info "Would install: ${missing[*]}"
            return 0
        fi
        
        info "Installing missing dependencies: ${missing[*]}"
        sudo dnf install -y "${missing[@]}"
    elif [[ "$OS" == "arch" ]] || [[ "$OS" == "manjaro" ]]; then
        check_command_installed gcc || missing+=("base-devel")
        check_header_file /usr/include/openssl/ssl.h || missing+=("openssl")
        
        if [[ ${#missing[@]} -eq 0 ]]; then
            success "All system dependencies present"
            return 0
        fi
        
        if [[ "$DRY_RUN" == true ]]; then
            info "Would install: ${missing[*]}"
            return 0
        fi
        
        info "Installing missing dependencies: ${missing[*]}"
        sudo pacman -S --needed --noconfirm "${missing[@]}"
    elif [[ "$OS" == "opensuse"* ]]; then
        command -v gcc >/dev/null || missing+=("gcc")
        command -v g++ >/dev/null || missing+=("gcc-c++")
        command -v make >/dev/null || missing+=("make")
        command -v pkg-config >/dev/null || missing+=("pkg-config")
        [[ -f /usr/include/openssl/ssl.h ]] || missing+=("libopenssl-devel")
        
        if [[ ${#missing[@]} -eq 0 ]]; then
            success "All system dependencies present"
            return 0
        fi
        
        if [[ "$DRY_RUN" == true ]]; then
            info "Would install: ${missing[*]}"
            return 0
        fi
        
        info "Installing missing dependencies: ${missing[*]}"
        sudo zypper install -y "${missing[@]}"
    elif [[ "$OS" == "alpine" ]]; then
        command -v gcc >/dev/null || missing+=("build-base")
        command -v pkg-config >/dev/null || missing+=("pkgconfig")
        [[ -f /usr/include/openssl/ssl.h ]] || missing+=("openssl-dev")
        
        if [[ ${#missing[@]} -eq 0 ]]; then
            success "All system dependencies present"
            return 0
        fi
        
        if [[ "$DRY_RUN" == true ]]; then
            info "Would install: ${missing[*]}"
            return 0
        fi
        
        info "Installing missing dependencies: ${missing[*]}"
        sudo apk add --no-cache "${missing[@]}"
    elif [[ "$OS" == "macos" ]]; then
        # Check macOS-specific dependencies
        xcode-select -p >/dev/null 2>&1 || missing+=("xcode-cli-tools")
        command -v brew >/dev/null || missing+=("homebrew")
        command -v pkg-config >/dev/null || missing+=("pkg-config")
        
        if [[ ${#missing[@]} -eq 0 ]]; then
            success "All system dependencies present"
            return 0
        fi
        
        if [[ "$DRY_RUN" == true ]]; then
            info "Would install: ${missing[*]}"
            return 0
        fi
        
        info "Installing missing dependencies: ${missing[*]}"
        
        # Install Xcode Command Line Tools if needed
        if ! xcode-select -p >/dev/null 2>&1; then
            warn "Xcode Command Line Tools not found"
            
            # Check if we're in SSH/CI environment where GUI dialogs won't work
            if [[ -n "${SSH_CONNECTION:-}" || -n "${CI:-}" ]]; then
                error "Xcode Command Line Tools required but GUI not available (SSH/CI environment detected)"
                error "Please install manually: xcode-select --install"
                exit 1
            fi
            
            # Check if installation is already in progress
            if pgrep -q "Install Command Line"; then
                info "Installation already in progress, waiting..."
            else
                info "Starting installation (this will open a GUI dialog)..."
                xcode-select --install 2>/dev/null || true
            fi
            
            # Wait for installation with timeout
            info "Waiting for Xcode Command Line Tools installation (this may take a few minutes)..."
            local max_wait=300  # 5 minutes
            local elapsed=0
            until xcode-select -p >/dev/null 2>&1; do
                if [[ $elapsed -ge $max_wait ]]; then
                    echo ""
                    error "Xcode Command Line Tools installation timed out after ${max_wait}s"
                    error "Installation may have failed or been cancelled"
                    error "Please complete the installation manually and run this script again: xcode-select --install"
                    exit 1
                fi
                echo -n "."
                sleep 5
                elapsed=$((elapsed + 5))
            done
            echo ""
            success "Xcode Command Line Tools installed!"
        else
            success "Xcode Command Line Tools already installed"
        fi
        # Install Homebrew if needed
        if ! command -v brew >/dev/null 2>&1; then
            warn "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            if [[ -f /opt/homebrew/bin/brew ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            fi
        fi
        # Install dependencies via Homebrew
        if command -v brew >/dev/null 2>&1; then
            # Check which deps are missing
            local brew_missing=()
            brew list git &>/dev/null || brew_missing+=("git")
            brew list curl &>/dev/null || brew_missing+=("curl")
            brew list openssl &>/dev/null || brew_missing+=("openssl")
            brew list pkg-config &>/dev/null || brew_missing+=("pkg-config")
            
            if [[ ${#brew_missing[@]} -gt 0 ]]; then
                info "Installing Homebrew packages: ${brew_missing[*]}"
                brew install "${brew_missing[@]}"
            else
                success "All Homebrew packages already installed"
            fi
        fi
    else
        warn "Unknown OS, attempting generic install..."
        
        if [[ ${#missing[@]} -eq 0 ]]; then
            success "All system dependencies present"
            return 0
        fi
        
        if [[ "$DRY_RUN" == true ]]; then
            info "Would install: ${missing[*]}"
            return 0
        fi
        
        info "Installing missing dependencies: ${missing[*]}"
        # Try to find and use available package manager
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y "${missing[@]}"
        elif command -v apk >/dev/null 2>&1; then
            sudo apk add --no-cache "${missing[@]}"
        else
            error "Could not detect package manager. Please install: git, curl, gcc, make, pkg-config, openssl-dev"
            exit 1
        fi
    fi
    
    # Verify critical tools after installation
    if ! check_command_installed git; then
        error "git still not available after installation"
        exit 1
    fi
    
    if ! check_command_installed gcc && ! check_command_installed clang; then
        error "C compiler (gcc or clang) still not available after installation"
        exit 1
    fi
    
    success "System dependencies ready!"
}

# Install Rust toolchain (non-destructive)
install_rust() {
    if ! command -v rustc >/dev/null 2>&1; then
        if [[ "$DRY_RUN" == true ]]; then
            info "Would install Rust toolchain"
            return 0
        fi
        
        info "Installing Rust toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
            sh -s -- -y --default-toolchain stable
        
        if [[ -f "$HOME/.cargo/env" ]]; then
            # shellcheck source=/dev/null
            source "$HOME/.cargo/env"
        fi
        
        if command -v rustc >/dev/null 2>&1; then
            success "Rust stable installed: $(rustc --version)"
        else
            error "Failed to install Rust toolchain"
            exit 1
        fi
    else
        local default_toolchain=$(rustup default | awk '{print $1}' | head -1)
        success "Rust already installed: $default_toolchain"
    fi
    
    # Ensure nightly is available (but don't make it default)
    if ! rustup toolchain list | grep -q nightly; then
        if [[ "$DRY_RUN" == true ]]; then
            info "Would install nightly toolchain for kodegen"
            return 0
        fi
        
        info "Installing nightly toolchain for kodegen..."
        rustup toolchain install nightly
        success "Nightly toolchain installed"
    else
        success "Nightly toolchain already available"
    fi
    
    info "Project will use nightly via rust-toolchain.toml (global default unchanged)"
}

# Verify rust-toolchain.toml exists and specifies nightly
verify_rust_toolchain_file() {
    local toolchain_file="$TEMP_DIR/kodegen/rust-toolchain.toml"
    
    if [[ ! -f "$toolchain_file" ]]; then
        error "Missing rust-toolchain.toml in repository!"
        error "This file is required to specify nightly toolchain"
        exit 1
    fi
    
    if ! grep -q 'channel.*=.*"nightly"' "$toolchain_file"; then
        error "rust-toolchain.toml doesn't specify nightly channel!"
        exit 1
    fi
    
    success "Verified rust-toolchain.toml specifies nightly"
}

# Clone repository to temporary directory
clone_repository() {
    info "Cloning KODEGEN.ᴀɪ repository..."

    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"

    # Try HTTPS (most compatible)
    if git clone --depth 1 https://github.com/cyrup-ai/kodegen.git; then
        cd kodegen
        success "Repository cloned successfully"
    else
        error "Failed to clone repository"
        exit 1
    fi
}

# Install the project using cargo
install_project() {
    local needs_install=false
    local reason=""
    
    # Check if already installed (unless --force is used)
    if [[ "$FORCE_INSTALL" == false ]]; then
        if command -v kodegen >/dev/null 2>&1 && command -v kodegend >/dev/null 2>&1; then
            local current_version=$(kodegen --version 2>/dev/null | awk '{print $2}' || echo "unknown")
            success "kodegen $current_version already installed (use --force to reinstall)"
            
            # Set binary paths for later use
            KODEGEN_BIN="$HOME/.cargo/bin/kodegen"
            KODEGEND_BIN="$HOME/.cargo/bin/kodegend"
            return 0
        fi
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        info "Would install KODEGEN.ᴀɪ MCP server and daemon"
        return 0
    fi
    
    # Verify project uses rust-toolchain.toml
    verify_rust_toolchain_file
    
    info "Installing KODEGEN.ᴀɪ MCP server (this may take a few minutes)..."
    
    # cargo will automatically use nightly via rust-toolchain.toml
    info "Building with nightly toolchain (via rust-toolchain.toml)..."

    # Navigate to the server package
    cd packages/server

    # Install the MCP server binary to ~/.cargo/bin
    if cargo install --path .; then
        success "KODEGEN.ᴀɪ MCP server installed!"
    else
        error "MCP server installation failed"
        exit 1
    fi

    # Ensure PATH is correct
    ensure_cargo_in_path

    # Verify binary is usable
    if ! verify_binary_installed "kodegen"; then
        error "kodegen installation verification failed"
        exit 1
    fi
    KODEGEN_BIN="$HOME/.cargo/bin/kodegen"

    # Navigate to the daemon package
    cd ../daemon
    info "Installing KODEGEN.ᴀɪ daemon..."

    # Install the daemon binary to ~/.cargo/bin
    if cargo install --path .; then
        success "KODEGEN.ᴀɪ daemon installed!"
    else
        error "Daemon installation failed"
        exit 1
    fi

    # Verify daemon binary
    if ! verify_binary_installed "kodegend"; then
        error "kodegend installation verification failed"
        exit 1
    fi
    KODEGEND_BIN="$HOME/.cargo/bin/kodegend"
}

# Auto-configure all detected MCP clients
auto_configure_clients() {
    info "Auto-configuring detected MCP clients..."

    if [[ -z "$KODEGEN_BIN" ]]; then
        error "KODEGEN_BIN not set, this is a bug"
        exit 1
    fi

    # Use absolute path
    if "$KODEGEN_BIN" install; then
        success "MCP clients configured automatically!"
    else
        warn "Auto-configuration failed"
        warn "Run manually: $KODEGEN_BIN install"
    fi
}

# Install and start daemon service
install_daemon_service() {
    info "Installing daemon service..."

    if [[ -z "$KODEGEND_BIN" ]]; then
        error "KODEGEND_BIN not set, this is a bug"
        exit 1
    fi

    # Install daemon service (will prompt for authorization on macOS)
    info "You may be prompted for your password to install the system service..."
    if "$KODEGEND_BIN" install; then
        success "Daemon service installed and started!"
    else
        warn "Daemon service installation failed"
        warn "Run manually: $KODEGEND_BIN install"
    fi
}

# Main installation process
main() {
    echo ""
    cyan "╔════════════════════════════════════════════╗"
    cyan "║                                            ║"
    cyan "║      ⚡  KODEGEN.ᴀɪ  INSTALLER             ║"
    cyan "║                                            ║"
    cyan "╚════════════════════════════════════════════╝"
    echo ""

    detect_os
    detect_platform
    
    # Check for existing installation early (unless --force is used)
    check_existing_installation
    
    install_deps
    install_rust
    
    # Only clone and install if needed
    if [[ "$FORCE_INSTALL" == true ]] || ! command -v kodegen >/dev/null 2>&1 || ! command -v kodegend >/dev/null 2>&1; then
        clone_repository
        install_project
    fi
    
    auto_configure_clients
    install_daemon_service

    echo ""
    cyan "────────────────────────────────────────────"
    success "Installation completed! 🚀"
    cyan "────────────────────────────────────────────"
    echo ""
    dim "Binary installed to: ~/.cargo/bin/kodegen"
    echo ""
    info "Your MCP clients have been automatically configured!"
    dim "Supported editors: Claude Desktop, Windsurf, Cursor, Zed, Roo Code"
    echo ""
    bold "Next steps:"
    echo "  1. Restart your editor/IDE"
    echo "  2. Start coding with KODEGEN.ᴀɪ!"
    echo ""
    dim "Manual configuration (if needed): kodegen install"
    echo ""
    green "╔════════════════════════════════════════════╗"
    green "║                                            ║"
    green "║   ⚡  Welcome to KODEGEN.ᴀɪ!               ║"
    green "║                                            ║"
    green "╚════════════════════════════════════════════╝"
    echo ""
}

# Run main function
main "$@"
