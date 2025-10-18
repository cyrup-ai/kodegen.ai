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

# Error handling with context
show_error_with_context() {
    local operation="$1"
    local exit_code="$2"
    local error_output="$3"
    
    error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    error "Operation failed: $operation"
    error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [[ -n "$error_output" ]]; then
        echo ""
        error "Error output:"
        echo "$error_output" | sed 's/^/  | /' | head -20
        echo ""
    fi
    
    error "Exit code: $exit_code"
    error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Save debug information to file
save_debug_info() {
    local debug_file="/tmp/kodegen-install-$(date +%Y%m%d-%H%M%S).log"
    
    {
        echo "KODEGEN Installation Failed"
        echo "Timestamp: $(date)"
        echo ""
        echo "System: $OS $PLATFORM"
        echo "Shell: $BASH_VERSION"
        echo ""
        echo "Environment:"
        env | grep -E '(PATH|HOME|USER|SHELL|TMPDIR)' | sort
        echo ""
        echo "Tool Versions:"
        echo "  git: $(git --version 2>&1)"
        echo "  curl: $(curl --version 2>&1 | head -1)"
        echo "  rustc: $(rustc --version 2>&1)"
        echo "  cargo: $(cargo --version 2>&1)"
        echo ""
        echo "Disk Space:"
        df -h 2>&1
        echo ""
        if [[ -n "${TEMP_DIR:-}" ]]; then
            echo "Temp Directory: $TEMP_DIR"
            if [[ -d "$TEMP_DIR" ]]; then
                echo "Temp Dir Contents:"
                ls -la "$TEMP_DIR" 2>&1 || echo "Cannot list temp dir"
            fi
            echo ""
        fi
        echo "Recent Logs:"
        tail -50 /tmp/cargo-install.log 2>/dev/null || echo "No cargo log"
        echo ""
    } > "$debug_file" 2>&1
    
    echo "$debug_file"
}

# Combined cleanup and error handler
on_exit() {
    local exit_code=$?
    
    # Always cleanup temp directory
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        info "Cleaning up temporary directory..."
        rm -rf "$TEMP_DIR"
    fi
    
    # Show error info only on failure
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        error "╔════════════════════════════════════════╗"
        error "║  Installation Failed                   ║"
        error "╚════════════════════════════════════════╝"
        echo ""
        
        local debug_file
        debug_file=$(save_debug_info)
        
        info "Debug information saved to:"
        echo "  $debug_file"
        echo ""
        info "To get help:"
        echo "  1. Check the error message above"
        echo "  2. Review the debug file"
        echo "  3. Search existing issues: https://github.com/cyrup-ai/kodegen/issues"
        echo "  4. Create new issue with debug file attached"
        echo ""
        info "Quick fixes to try:"
        echo "  • Re-run the installer: ./install.sh"
        echo "  • Skip dependencies: ./install.sh --skip-deps"
        echo "  • Force reinstall: ./install.sh --force"
        echo ""
    fi
}

# Set up combined exit trap
trap on_exit EXIT

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
    
    # If both binaries are installed
    if [[ "$has_kodegen" == true ]] && [[ "$has_kodegend" == true ]]; then
        success "KODEGEN.ᴀɪ currently installed:"
        dim "  kodegen:  $kodegen_version"
        dim "  kodegend: $kodegend_version"
        
        if [[ "$FORCE_INSTALL" == false ]]; then
            # Check if newer version available
            if should_check_for_updates; then
                info "Checking for updates..."
                
                # Clone repo to temporary location (shallow, just to check version)
                local temp_check=$(mktemp -d)
                if git clone --depth 1 --quiet https://github.com/cyrup-ai/kodegen.git "$temp_check" 2>/dev/null; then
                    local repo_version=$(get_repo_version "$temp_check/packages/server/Cargo.toml")
                    
                    if [[ -n "$repo_version" ]] && version_greater "$repo_version" "$kodegen_version"; then
                        info "Newer version available: $repo_version"
                        warn "Current version $kodegen_version is outdated"
                        echo ""
                        
                        # Ask user if they want to update
                        read -p "Update to version $repo_version? [Y/n] " -n 1 -r
                        echo
                        if [[ $REPLY =~ ^[Nn]$ ]]; then
                            success "Keeping current version"
                            rm -rf "$temp_check"
                            exit 0
                        else
                            info "Proceeding with update..."
                            rm -rf "$temp_check"
                            return 0  # Continue with installation
                        fi
                    else
                        success "You have the latest version"
                        rm -rf "$temp_check"
                        exit 0
                    fi
                else
                    # Couldn't check for updates, assume current is fine
                    info "Could not check for updates (network issue?)"
                    success "Keeping current installation"
                    exit 0
                fi
            else
                echo ""
                info "Use --force to reinstall"
                exit 0
            fi
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

# Helper: Should we check for updates?
should_check_for_updates() {
    # Don't check if in non-interactive mode or CI
    [[ -t 0 ]] && [[ -z "${CI:-}" ]]
}

# Helper: Get version from Cargo.toml
get_repo_version() {
    local cargo_toml="$1"
    grep '^version = ' "$cargo_toml" | head -1 | cut -d'"' -f2
}

# Helper: Compare semantic versions (returns 0 if v1 > v2)
version_greater() {
    local v1="$1"
    local v2="$2"
    
    # Use sort -V to compare versions
    local sorted=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -1)
    
    # If v2 sorts first, v1 is greater
    [[ "$sorted" == "$v2" ]] && [[ "$v1" != "$v2" ]]
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
        check_command_installed gcc || missing+=("gcc")
        check_command_installed g++ || missing+=("gcc-c++")
        check_command_installed make || missing+=("make")
        check_command_installed pkg-config || missing+=("pkg-config")
        check_header_file /usr/include/openssl/ssl.h || missing+=("libopenssl-devel")
        
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
        check_command_installed gcc || missing+=("build-base")
        check_command_installed pkg-config || missing+=("pkgconfig")
        check_header_file /usr/include/openssl/ssl.h || missing+=("openssl-dev")
        
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
        check_command_installed brew || missing+=("homebrew")
        check_command_installed pkg-config || missing+=("pkg-config")
        
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
        if ! check_command_installed brew; then
            warn "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            if [[ -f /opt/homebrew/bin/brew ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            fi
        fi
        # Install dependencies via Homebrew
        if check_command_installed brew; then
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
        local output
        if ! output=$(curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs 2>&1 | sh -s -- -y --default-toolchain stable 2>&1); then
            show_error_with_context "rustup installation" $? "$output"
            
            # Provide specific help
            echo ""
            info "Possible fixes:"
            echo "  1. Check internet connection"
            echo "  2. Verify you have write access to ~/.cargo"
            echo "  3. Check disk space: df -h ~"
            echo "  4. Try manual install: https://rustup.rs"
            
            exit 1
        fi
        
        if [[ -f "$HOME/.cargo/env" ]]; then
            # shellcheck source=/dev/null
            source "$HOME/.cargo/env"
        fi
        
        if command -v rustc >/dev/null 2>&1; then
            success "Rust stable installed: $(rustc --version)"
        else
            error "Failed to install Rust toolchain"
            error "rustc command not found after installation"
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
        local nightly_output
        if ! nightly_output=$(rustup toolchain install nightly 2>&1); then
            show_error_with_context "nightly toolchain installation" $? "$nightly_output"
            echo ""
            info "Possible fixes:"
            echo "  1. Check internet connection"
            echo "  2. Try again: rustup toolchain install nightly"
            echo "  3. Update rustup: rustup self update"
            exit 1
        fi
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
    local output
    if ! output=$(git clone --depth 1 https://github.com/cyrup-ai/kodegen.git 2>&1); then
        show_error_with_context "git clone" $? "$output"
        
        # Provide specific help based on error type
        if echo "$output" | grep -q "Could not resolve"; then
            echo ""
            warn "Diagnosis: DNS resolution failed"
            info "Possible fixes:"
            echo "  1. Check internet: ping github.com"
            echo "  2. Check DNS: nslookup github.com"
            echo "  3. Try alternate DNS: use 8.8.8.8 or 1.1.1.1"
        elif echo "$output" | grep -q "Connection refused\|Failed to connect"; then
            echo ""
            warn "Diagnosis: Connection refused"
            info "Possible fixes:"
            echo "  1. Check if GitHub is down: https://www.githubstatus.com"
            echo "  2. Check proxy settings: echo \$HTTP_PROXY"
            echo "  3. Check firewall settings"
        elif echo "$output" | grep -q "No space left"; then
            echo ""
            warn "Diagnosis: No disk space"
            info "Possible fixes:"
            echo "  1. Free up space: df -h"
            echo "  2. Clear temp: rm -rf /tmp/*"
            echo "  3. Use different location: TMPDIR=/other/path ./install.sh"
        fi
        
        exit 1
    fi
    
    cd kodegen
    success "Repository cloned successfully"
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
    local cargo_output
    if ! cargo_output=$(cargo install --path . 2>&1); then
        show_error_with_context "cargo install kodegen (MCP server)" $? "$cargo_output"
        
        echo ""
        info "Possible fixes:"
        echo "  1. Check disk space: df -h ~"
        echo "  2. Clear cargo cache: rm -rf ~/.cargo/registry/cache"
        echo "  3. Update rust: rustup update"
        echo "  4. Check build log above for specific errors"
        
        exit 1
    fi
    success "KODEGEN.ᴀɪ MCP server installed!"

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
    local daemon_output
    if ! daemon_output=$(cargo install --path . 2>&1); then
        show_error_with_context "cargo install kodegend (daemon)" $? "$daemon_output"
        
        echo ""
        info "Possible fixes:"
        echo "  1. Check disk space: df -h ~"
        echo "  2. Clear cargo cache: rm -rf ~/.cargo/registry/cache"
        echo "  3. Update rust: rustup update"
        echo "  4. Check build log above for specific errors"
        
        exit 1
    fi
    success "KODEGEN.ᴀɪ daemon installed!"

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
