#!/bin/bash

# Ubuntu Development Environment Setup Script
# Easy to customize and extend

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to prompt user for yes/no
prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -p "$prompt" response
    response=${response:-$default}
    
    [[ "$response" =~ ^[Yy]$ ]]
}

# Function to install packages with apt
install_apt_packages() {
    local packages=("$@")
    log_info "Installing apt packages: ${packages[*]}"
    
    for package in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii  $package "; then
            log_warning "$package is already installed"
        else
            sudo apt install -y "$package"
            log_success "Installed $package"
        fi
    done
}

# Function to install snap packages
install_snap_packages() {
    local packages=("$@")
    log_info "Installing snap packages: ${packages[*]}"
    
    for package in "${packages[@]}"; do
        if snap list | grep -q "^$package "; then
            log_warning "$package is already installed"
        else
            sudo snap install "$package" --classic 2>/dev/null || sudo snap install "$package"
            log_success "Installed $package"
        fi
    done
}

# Function to add PPAs
add_ppa() {
    local ppa="$1"
    log_info "Adding PPA: $ppa"
    sudo add-apt-repository -y "$ppa"
    sudo apt update
}

# System update
update_system() {
    log_info "Updating system packages..."
    sudo apt update && sudo apt upgrade -y
    log_success "System updated"
}

# Install basic development tools
install_dev_tools() {
    log_info "Installing basic development tools..."
    
    local dev_packages=(
        "build-essential"
        "git"
        "curl"
        "wget"
        "vim"
        "neovim"
        "tree"
        "htop"
        "unzip"
        "software-properties-common"
        "apt-transport-https"
        "ca-certificates"
        "gnupg"
        "lsb-release"
        "jq"
        "xclip"
        "ffmpeg"
    )
    
    install_apt_packages "${dev_packages[@]}"
}

# Install and configure Zsh with Oh My Zsh
setup_zsh() {
    log_info "Setting up Zsh..."
    
    # Install zsh
    install_apt_packages "zsh"
    
    # Install Oh My Zsh
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        log_info "Installing Oh My Zsh..."
        sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        log_success "Oh My Zsh installed"
    else
        log_warning "Oh My Zsh already installed"
    fi
    
    # Change default shell to zsh
    if [[ "$SHELL" != */zsh ]]; then
        log_info "Changing default shell to zsh..."
        chsh -s "$(which zsh)"
        log_success "Default shell changed to zsh (requires logout/login)"
    else
        log_warning "Default shell is already zsh"
    fi
    
    # Install popular zsh plugins
    local zsh_custom="$HOME/.oh-my-zsh/custom"
    
    # zsh-autosuggestions
    if [[ ! -d "$zsh_custom/plugins/zsh-autosuggestions" ]]; then
        git clone https://github.com/zsh-users/zsh-autosuggestions "$zsh_custom/plugins/zsh-autosuggestions"
    fi
    
    # zsh-syntax-highlighting  
    if [[ ! -d "$zsh_custom/plugins/zsh-syntax-highlighting" ]]; then
        git clone https://github.com/zsh-users/zsh-syntax-highlighting "$zsh_custom/plugins/zsh-syntax-highlighting"
    fi
    
    log_success "Zsh setup complete"
}

# Install programming languages
install_golang() {
    log_info "Installing Go..."
    
    # Get latest Go version
    local go_version
    go_version=$(curl -s https://api.github.com/repos/golang/go/releases | jq -r '.[0].tag_name' | sed 's/go//')
    
    if command -v go &> /dev/null; then
        local current_version
        current_version=$(go version | cut -d' ' -f3 | sed 's/go//')
        if [[ "$current_version" == "$go_version" ]]; then
            log_warning "Go $current_version is already installed"
            return
        fi
    fi
    
    local go_archive="go${go_version}.linux-amd64.tar.gz"
    
    # Download and install Go
    wget -q "https://golang.org/dl/$go_archive" -O "/tmp/$go_archive"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "/tmp/$go_archive"
    rm "/tmp/$go_archive"
    
    # Add Go to PATH in .bashrc and .zshrc
    local go_path_export='export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin'
    
    if ! grep -q "/usr/local/go/bin" "$HOME/.bashrc" 2>/dev/null; then
        echo "$go_path_export" >> "$HOME/.bashrc"
    fi
    
    if [[ -f "$HOME/.zshrc" ]] && ! grep -q "/usr/local/go/bin" "$HOME/.zshrc"; then
        echo "$go_path_export" >> "$HOME/.zshrc"
    fi
    
    export PATH=$PATH:/usr/local/go/bin
    log_success "Go $go_version installed"
}

install_rust() {
    log_info "Installing Rust..."
    
    if command -v rustc &> /dev/null; then
        log_warning "Rust is already installed"
        return
    fi
    
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    
    # Add cargo to PATH in .bashrc and .zshrc
    local cargo_source='source $HOME/.cargo/env'
    
    if ! grep -q ".cargo/env" "$HOME/.bashrc" 2>/dev/null; then
        echo "$cargo_source" >> "$HOME/.bashrc"
    fi
    
    if [[ -f "$HOME/.zshrc" ]] && ! grep -q ".cargo/env" "$HOME/.zshrc"; then
        echo "$cargo_source" >> "$HOME/.zshrc"
    fi
    
    log_success "Rust installed"
}

install_lua() {
    log_info "Installing Lua..."
    
    local lua_packages=(
        "lua5.4"
	"luajit"
        "luarocks"
    )
    
    install_apt_packages "${lua_packages[@]}"
    log_success "Lua installed"
}

# Install terminal emulators and tools
install_wezterm() {
    log_info "Installing WezTerm..."
    
    if command -v wezterm &> /dev/null; then
        log_warning "WezTerm is already installed"
        return
    fi
    
    # Add WezTerm repository
    curl -fsSL https://apt.fury.io/wez/gpg.key | sudo gpg --yes --dearmor -o /usr/share/keyrings/wezterm-fury.gpg
    echo 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' | sudo tee /etc/apt/sources.list.d/wezterm.list
    
    sudo apt update
    install_apt_packages "wezterm"
    
    log_success "WezTerm installed"
}

# Install additional tools (customize this section)
install_additional_tools() {
    log_info "Installing additional tools..."
    
    # Add your favorite tools here
    local additional_packages=(
        "fzf"           # Fuzzy finder
        "ripgrep"       # Better grep
        "fd-find"       # Better find
        "bat"           # Better cat
        "exa"           # Better ls
        "docker.io"     # Containerization
        "docker-compose" # Docker Compose
    )
    
    install_apt_packages "${additional_packages[@]}"
    
    # Install Node.js via NodeSource
    if ! command -v node &> /dev/null; then
        log_info "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        install_apt_packages "nodejs"
    fi
    
    # Add user to docker group
    if groups | grep -q docker; then
        log_warning "User already in docker group"
    else
        sudo usermod -aG docker "$USER"
        log_success "Added user to docker group (requires logout/login)"
    fi
    
    log_success "Additional tools installed"
}

# Install development editors/IDEs
install_editors() {
    log_info "Installing editors and IDEs..."
    
    # VS Code
    if ! command -v code &> /dev/null; then
        log_info "Installing Visual Studio Code..."
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
        sudo install -o root -g root -m 644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
        sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
        sudo apt update
        install_apt_packages "code"
    fi
    
    log_success "Editors installed"
}

# Cleanup
cleanup() {
    log_info "Cleaning up..."
    sudo apt autoremove -y
    sudo apt autoclean
    log_success "Cleanup complete"
}

# Main installation menu
main_menu() {
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${BLUE}    Ubuntu Development Setup Script${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo
    
    # System update (always run)
    update_system
    
    # Basic dev tools
    if prompt_yes_no "Install basic development tools?" "y"; then
        install_dev_tools
    fi
    
    # Shell setup
    if prompt_yes_no "Setup Zsh with Oh My Zsh?" "y"; then
        setup_zsh
    fi
    
    # Programming languages
    echo
    log_info "Programming Languages:"
    
    if prompt_yes_no "Install Go?" "y"; then
        install_golang
    fi
    
    if prompt_yes_no "Install Rust?" "y"; then
        install_rust
    fi
    
    if prompt_yes_no "Install Lua?" "y"; then
        install_lua
    fi
    
    # Terminal tools
    echo
    log_info "Terminal Tools:"
    
    if prompt_yes_no "Install WezTerm?" "y"; then
        install_wezterm
    fi
    
    # Additional tools
    if prompt_yes_no "Install additional development tools?" "y"; then
        install_additional_tools
    fi
    
    # Editors
    if prompt_yes_no "Install editors (VS Code)?" "y"; then
        install_editors
    fi
    
    # Cleanup
    cleanup
    
    echo
    log_success "Setup complete!"
    echo -e "${YELLOW}Note: You may need to logout and login again for some changes to take effect.${NC}"
    echo -e "${YELLOW}Run 'source ~/.bashrc' or 'source ~/.zshrc' to reload your shell configuration.${NC}"
}

# Run the script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu
fi
