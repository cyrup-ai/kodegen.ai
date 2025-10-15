#!/bin/bash
set -euo pipefail

# KODEGEN.ᴀɪ One-Line Installer
# Usage: curl -fsSL https://kodegen.ai/install.sh | bash

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

# Install system dependencies
install_deps() {
    info "Installing system dependencies..."
    
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]] || [[ "$OS_LIKE" == *"debian"* ]]; then
        sudo apt-get update -qq
        sudo apt-get install -y git curl build-essential pkg-config libssl-dev
    elif [[ "$OS" == "fedora" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "centos" ]]; then
        sudo dnf install -y git curl gcc gcc-c++ make pkgconfig openssl-devel
    elif [[ "$OS" == "arch" ]] || [[ "$OS" == "manjaro" ]]; then
        sudo pacman -S --needed --noconfirm git curl base-devel openssl
    elif [[ "$OS" == "opensuse"* ]]; then
        sudo zypper install -y git curl gcc gcc-c++ make pkg-config libopenssl-devel
    elif [[ "$OS" == "alpine" ]]; then
        sudo apk add --no-cache git curl build-base pkgconfig openssl-dev
    elif [[ "$OS" == "macos" ]]; then
        # Install Xcode Command Line Tools if needed
        if ! xcode-select -p >/dev/null 2>&1; then
            warn "Installing Xcode Command Line Tools..."
            xcode-select --install 2>/dev/null || true
            # Wait for installation
            until xcode-select -p >/dev/null 2>&1; do
                sleep 5
            done
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
        brew install git curl openssl pkg-config
    else
        warn "Unknown OS, attempting generic install..."
        # Try to find and use available package manager
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -qq && sudo apt-get install -y git curl build-essential pkg-config libssl-dev
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y git curl gcc gcc-c++ make pkgconfig openssl-devel
        elif command -v apk >/dev/null 2>&1; then
            sudo apk add --no-cache git curl build-base pkgconfig openssl-dev
        else
            error "Could not detect package manager. Please install: git, curl, gcc, make, pkg-config, openssl-dev"
            exit 1
        fi
    fi
    
    success "System dependencies installed!"
}

# Install Rust nightly toolchain
install_rust() {
    if ! command -v rustc >/dev/null 2>&1; then
        info "Installing Rust nightly toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly
        
        # Source the cargo environment
        if [[ -f "$HOME/.cargo/env" ]]; then
            # shellcheck source=/dev/null
            source "$HOME/.cargo/env"
        fi
        
        # Verify installation
        if command -v rustc >/dev/null 2>&1; then
            success "Rust nightly installed: $(rustc --version)"
        else
            error "Failed to install Rust toolchain"
            exit 1
        fi
    else
        info "Rust toolchain found: $(rustc --version)"
        # Ensure nightly is installed
        if ! rustup toolchain list | grep -q nightly; then
            info "Installing nightly toolchain..."
            rustup toolchain install nightly
        fi
        # Set nightly as default for this project
        info "Ensuring nightly toolchain is available..."
        rustup default nightly
        success "Rust nightly toolchain ready: $(rustc --version)"
    fi
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
    info "Installing KODEGEN.ᴀɪ (this may take a few minutes)..."

    # Navigate to the server package
    cd packages/server

    # Install the binary to ~/.cargo/bin
    if cargo install --path .; then
        success "KODEGEN.ᴀɪ installed successfully!"
    else
        error "Installation failed"
        exit 1
    fi
}

# Auto-configure all detected MCP clients
auto_configure_clients() {
    info "Auto-configuring detected MCP clients..."

    # Source cargo environment to ensure kodegen is in PATH
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi

    # Run kodegen install
    if kodegen install; then
        success "MCP clients configured automatically!"
    else
        warn "Auto-configuration failed, you can run 'kodegen install' manually later"
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
    install_deps
    install_rust
    clone_repository
    install_project
    auto_configure_clients

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
