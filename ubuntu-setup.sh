#!/usr/bin/env bash
# ============================================================================
#  Ubuntu Post-Install Setup Script
#  Pull & run: curl -fsSL https://raw.githubusercontent.com/<you>/dotfiles/main/ubuntu-setup.sh | bash
#  Or clone and run: ./ubuntu-setup.sh
# ============================================================================
set -euo pipefail

# ── Colors & formatting ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

OPT_DIR="/opt"

# ── Helper functions ────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[  OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }

need_root() {
    if [[ $EUID -ne 0 ]]; then
        fail "This script must be run as root (or with sudo)."
        exit 1
    fi
}

ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(eval echo "~${ACTUAL_USER}")

run_as_user() {
    sudo -u "$ACTUAL_USER" -- bash -c "$*"
}

# ── Interactive menu ────────────────────────────────────────────────────────
declare -A MODULES=(
    [zsh]="Zsh + Oh-My-Zsh"
    [firacode]="FiraCode Nerd Font"
    [ghostty]="Ghostty terminal"
    [neovim]="Neovim (latest from GitHub)"
    [stow]="GNU Stow (dotfile symlinks)"
    [java]="Java (Adoptium Temurin 21 JDK)"
    [gradle]="Gradle"
    [rust]="Rust (via rustup)"
    [python]="Python tooling (uv)"
    [cpp]="C/C++ (gcc, g++, cmake, make)"
    [docker]="Docker Engine + Compose"
    [nodejs]="Node.js LTS (installed to /opt)"
    [clitools]="CLI tools (ripgrep, fd, bat, curl, wget, jq, htop, tree, unzip, git)"
)

MODULE_ORDER=(zsh firacode ghostty neovim stow java gradle rust python cpp docker nodejs clitools)

declare -A SELECTED
for key in "${MODULE_ORDER[@]}"; do
    SELECTED[$key]=1   # all selected by default
done

draw_menu() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║            Ubuntu Post-Install Setup Script                 ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  Toggle items with their ${BOLD}number${NC}, then press ${BOLD}s${NC} to start.\n"

    local i=1
    for key in "${MODULE_ORDER[@]}"; do
        if [[ ${SELECTED[$key]} -eq 1 ]]; then
            echo -e "    ${GREEN}[✓]${NC} ${BOLD}${i})${NC}  ${MODULES[$key]}"
        else
            echo -e "    ${RED}[ ]${NC} ${BOLD}${i})${NC}  ${MODULES[$key]}"
        fi
        ((i++))
    done

    echo ""
    echo -e "  ${BOLD}a)${NC} Select all    ${BOLD}n)${NC} Select none    ${BOLD}s)${NC} Start install    ${BOLD}q)${NC} Quit"
    echo ""
}

interactive_menu() {
    while true; do
        draw_menu
        read -rp "  ▸ Choice: " choice
        case "$choice" in
            [1-9]|1[0-3])
                local idx=$((choice - 1))
                if [[ $idx -lt ${#MODULE_ORDER[@]} ]]; then
                    local key="${MODULE_ORDER[$idx]}"
                    SELECTED[$key]=$(( 1 - ${SELECTED[$key]} ))
                fi
                ;;
            a|A)
                for key in "${MODULE_ORDER[@]}"; do SELECTED[$key]=1; done
                ;;
            n|N)
                for key in "${MODULE_ORDER[@]}"; do SELECTED[$key]=0; done
                ;;
            s|S) break ;;
            q|Q) echo "Aborted."; exit 0 ;;
            *)   ;;
        esac
    done
}

# ── Module: Core apt update ─────────────────────────────────────────────────
do_apt_update() {
    info "Updating package lists …"
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq software-properties-common apt-transport-https \
        ca-certificates gnupg lsb-release curl wget
    success "Base packages up to date."
}

# ── Module: CLI tools ───────────────────────────────────────────────────────
install_clitools() {
    info "Installing CLI tools …"
    apt-get install -y -qq \
        git curl wget unzip jq htop tree tmux \
        ripgrep fd-find bat xclip
    # fd and bat are installed under different names on Ubuntu
    if [[ ! -L /usr/local/bin/fd ]]; then
        ln -sf "$(which fdfind)" /usr/local/bin/fd 2>/dev/null || true
    fi
    if [[ ! -L /usr/local/bin/bat ]]; then
        ln -sf "$(which batcat)" /usr/local/bin/bat 2>/dev/null || true
    fi
    success "CLI tools installed."
}

# ── Module: Zsh + Oh-My-Zsh ─────────────────────────────────────────────────
install_zsh() {
    info "Installing Zsh …"
    apt-get install -y -qq zsh

    info "Installing Oh-My-Zsh for ${ACTUAL_USER} …"
    if [[ ! -d "${ACTUAL_HOME}/.oh-my-zsh" ]]; then
        run_as_user 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
    else
        warn "Oh-My-Zsh already installed — skipping."
    fi

    chsh -s "$(which zsh)" "$ACTUAL_USER"
    success "Zsh is now the default shell for ${ACTUAL_USER}."
}

# ── Module: FiraCode Nerd Font ───────────────────────────────────────────────
install_firacode() {
    info "Installing FiraCode Nerd Font …"
    local font_dir="${ACTUAL_HOME}/.local/share/fonts/FiraCode"
    mkdir -p "$font_dir"

    local latest
    latest=$(curl -fsSL "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest" \
        | jq -r '.tag_name')

    curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/download/${latest}/FiraCode.tar.xz" \
        -o /tmp/FiraCode.tar.xz
    tar -xf /tmp/FiraCode.tar.xz -C "$font_dir"
    chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "$font_dir"
    fc-cache -fv > /dev/null 2>&1
    rm -f /tmp/FiraCode.tar.xz
    success "FiraCode Nerd Font ${latest} installed."
}

# ── Module: Ghostty ──────────────────────────────────────────────────────────
install_ghostty() {
    info "Installing Ghostty terminal …"

    # Ghostty provides an apt repo for Ubuntu 24.04+
    if [[ ! -f /etc/apt/keyrings/ghostty-archive-keyring.gpg ]]; then
        curl -fsSL https://pkg.ghostty.org/gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/ghostty-archive-keyring.gpg
    fi

    local codename
    codename=$(lsb_release -cs)

    cat > /etc/apt/sources.list.d/ghostty.list <<EOF
deb [signed-by=/etc/apt/keyrings/ghostty-archive-keyring.gpg] https://pkg.ghostty.org/apt ${codename} main
EOF

    apt-get update -qq
    apt-get install -y -qq ghostty
    success "Ghostty installed."
}

# ── Module: Neovim (latest GitHub release) ───────────────────────────────────
install_neovim() {
    info "Installing Neovim (latest stable from GitHub) …"
    local latest
    latest=$(curl -fsSL "https://api.github.com/repos/neovim/neovim/releases/latest" \
        | jq -r '.tag_name')

    local nvim_dir="${OPT_DIR}/nvim"
    mkdir -p "$nvim_dir"

    curl -fsSL "https://github.com/neovim/neovim/releases/download/${latest}/nvim-linux-x86_64.tar.gz" \
        -o /tmp/nvim.tar.gz
    tar -xzf /tmp/nvim.tar.gz -C "$nvim_dir" --strip-components=1
    ln -sf "${nvim_dir}/bin/nvim" /usr/local/bin/nvim
    rm -f /tmp/nvim.tar.gz
    success "Neovim ${latest} installed to ${nvim_dir}."
}

# ── Module: GNU Stow ────────────────────────────────────────────────────────
install_stow() {
    info "Installing GNU Stow …"
    apt-get install -y -qq stow
    success "Stow installed."
}

# ── Module: Java (Adoptium Temurin 21) ───────────────────────────────────────
install_java() {
    info "Installing Adoptium Temurin 21 JDK …"

    apt-get install -y -qq wget apt-transport-https gpg

    local codename
    codename=$(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release)

    # ── Strategy 1: Try the Adoptium apt repo ────────────────────────────
    #    New Ubuntu releases (e.g. 26.04 "resolute") may not have a repo yet.
    #    We try the native codename first, then fall back to "noble" (24.04).
    local apt_success=false

    for try_codename in "$codename" "noble"; do
        info "Trying Adoptium apt repo with codename: ${try_codename} …"

        # Download and dearmor the GPG key
        if [[ ! -f /etc/apt/trusted.gpg.d/adoptium.gpg ]]; then
            wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
                | gpg --dearmor \
                | tee /etc/apt/trusted.gpg.d/adoptium.gpg > /dev/null
        fi

        echo "deb https://packages.adoptium.net/artifactory/deb ${try_codename} main" \
            | tee /etc/apt/sources.list.d/adoptium.list > /dev/null

        if apt-get update -qq 2>/dev/null && apt-get install -y -qq temurin-21-jdk 2>/dev/null; then
            apt_success=true
            if [[ "$try_codename" != "$codename" ]]; then
                warn "Your codename '${codename}' is not yet supported by Adoptium."
                warn "Installed using '${try_codename}' repo (binary compatible)."
            fi
            break
        else
            warn "Adoptium repo for '${try_codename}' failed, trying next option …"
            rm -f /etc/apt/sources.list.d/adoptium.list
        fi
    done

    # ── Strategy 2: Direct tarball download to /opt ──────────────────────
    #    If the apt repo doesn't work at all, grab the tarball from the
    #    Adoptium API. This also fits the /opt install preference.
    if [[ "$apt_success" == false ]]; then
        warn "Adoptium apt repo unavailable — falling back to direct tarball install."

        local arch
        arch=$(dpkg --print-architecture)
        # Map Debian arch names to Adoptium API names
        case "$arch" in
            amd64)  arch="x64" ;;
            arm64)  arch="aarch64" ;;
            *)      arch="$arch" ;;
        esac

        local java_dir="${OPT_DIR}/temurin-21-jdk"
        mkdir -p "$java_dir"

        local download_url="https://api.adoptium.net/v3/binary/latest/21/ga/linux/${arch}/jdk/hotspot/normal/eclipse"

        info "Downloading Temurin 21 JDK tarball …"
        curl -fsSL -o /tmp/temurin-21.tar.gz "$download_url"
        tar -xzf /tmp/temurin-21.tar.gz -C "$java_dir" --strip-components=1
        rm -f /tmp/temurin-21.tar.gz

        # Symlink binaries
        ln -sf "${java_dir}/bin/java"  /usr/local/bin/java
        ln -sf "${java_dir}/bin/javac" /usr/local/bin/javac
        ln -sf "${java_dir}/bin/jar"   /usr/local/bin/jar

        info "Note: tarball installs don't auto-update via apt."
        info "Re-run this script or check adoptium.net for newer releases."
    fi

    success "Adoptium Temurin 21 JDK installed."
    java --version
}

# ── Module: Gradle ───────────────────────────────────────────────────────────
install_gradle() {
    info "Installing Gradle …"
    local latest
    latest=$(curl -fsSL "https://services.gradle.org/versions/current" | jq -r '.version')

    local gradle_dir="${OPT_DIR}/gradle"
    mkdir -p "$gradle_dir"

    curl -fsSL "https://services.gradle.org/distributions/gradle-${latest}-bin.zip" \
        -o /tmp/gradle.zip
    unzip -qo /tmp/gradle.zip -d /tmp/gradle-extract
    cp -rf /tmp/gradle-extract/gradle-${latest}/* "$gradle_dir"/
    ln -sf "${gradle_dir}/bin/gradle" /usr/local/bin/gradle
    rm -rf /tmp/gradle.zip /tmp/gradle-extract
    success "Gradle ${latest} installed to ${gradle_dir}."
}

# ── Module: Rust ─────────────────────────────────────────────────────────────
install_rust() {
    info "Installing Rust via rustup for ${ACTUAL_USER} …"
    run_as_user 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
    success "Rust installed. Source \$HOME/.cargo/env to use."
}

# ── Module: Python (uv) ─────────────────────────────────────────────────────
install_python() {
    info "Installing Python tooling (uv) …"
    run_as_user 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    success "uv installed. Use 'uv python install' to grab Python versions."
}

# ── Module: C/C++ ────────────────────────────────────────────────────────────
install_cpp() {
    info "Installing C/C++ toolchain …"
    apt-get install -y -qq build-essential gcc g++ cmake make gdb
    success "gcc/g++/cmake/make/gdb installed."
}

# ── Module: Docker ───────────────────────────────────────────────────────────
install_docker() {
    info "Installing Docker Engine …"

    if ! command -v docker &>/dev/null; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    else
        warn "Docker already installed — skipping."
    fi

    usermod -aG docker "$ACTUAL_USER"
    success "Docker installed. ${ACTUAL_USER} added to docker group (re-login to take effect)."
}

# ── Module: Node.js LTS (to /opt) ───────────────────────────────────────────
install_nodejs() {
    info "Installing Node.js LTS to ${OPT_DIR} …"

    # Fetch the latest LTS version
    local node_version
    node_version=$(curl -fsSL https://nodejs.org/dist/index.json \
        | jq -r '[.[] | select(.lts != false)][0].version')

    local node_dir="${OPT_DIR}/nodejs"
    mkdir -p "$node_dir"

    curl -fsSL "https://nodejs.org/dist/${node_version}/node-${node_version}-linux-x64.tar.xz" \
        -o /tmp/node.tar.xz
    tar -xf /tmp/node.tar.xz -C "$node_dir" --strip-components=1
    rm -f /tmp/node.tar.xz

    # Symlink binaries
    for bin in node npm npx corepack; do
        ln -sf "${node_dir}/bin/${bin}" /usr/local/bin/${bin}
    done

    success "Node.js ${node_version} installed to ${node_dir}."
}

# ── Post-install: shell profile paths ────────────────────────────────────────
write_path_snippet() {
    info "Writing /etc/profile.d/custom-paths.sh for /opt tools …"

    # Auto-detect JAVA_HOME: tarball in /opt takes priority, then apt location
    local java_home=""
    if [[ -d "${OPT_DIR}/temurin-21-jdk/bin" ]]; then
        java_home="${OPT_DIR}/temurin-21-jdk"
    elif [[ -d "/usr/lib/jvm/temurin-21-jdk-amd64" ]]; then
        java_home="/usr/lib/jvm/temurin-21-jdk-amd64"
    elif [[ -d "/usr/lib/jvm/temurin-21-jdk-arm64" ]]; then
        java_home="/usr/lib/jvm/temurin-21-jdk-arm64"
    fi

    cat > /etc/profile.d/custom-paths.sh <<PATHS
# Added by ubuntu-setup.sh
export PATH="/opt/nodejs/bin:/opt/nvim/bin:/opt/gradle/bin:\$PATH"
${java_home:+export JAVA_HOME="${java_home}"}
PATHS
    success "Path snippet written. Will apply on next login."
}

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║                    Setup complete! 🎉                      ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${BOLD}Next steps:${NC}"
    echo "    • Log out and back in (or reboot) so group/shell changes apply."
    echo "    • Clone your dotfiles repo and run: cd dotfiles && stow <package>"
    echo "    • Source Rust env:  source \$HOME/.cargo/env"
    echo "    • Install a Python: uv python install 3.12"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    need_root
    interactive_menu

    echo ""
    info "Starting installation …"
    echo ""

    do_apt_update

    [[ ${SELECTED[clitools]} -eq 1 ]] && install_clitools
    [[ ${SELECTED[zsh]}      -eq 1 ]] && install_zsh
    [[ ${SELECTED[firacode]} -eq 1 ]] && install_firacode
    [[ ${SELECTED[ghostty]}  -eq 1 ]] && install_ghostty
    [[ ${SELECTED[neovim]}   -eq 1 ]] && install_neovim
    [[ ${SELECTED[stow]}     -eq 1 ]] && install_stow
    [[ ${SELECTED[java]}     -eq 1 ]] && install_java
    [[ ${SELECTED[gradle]}   -eq 1 ]] && install_gradle
    [[ ${SELECTED[rust]}     -eq 1 ]] && install_rust
    [[ ${SELECTED[python]}   -eq 1 ]] && install_python
    [[ ${SELECTED[cpp]}      -eq 1 ]] && install_cpp
    [[ ${SELECTED[docker]}   -eq 1 ]] && install_docker
    [[ ${SELECTED[nodejs]}   -eq 1 ]] && install_nodejs

    write_path_snippet
    print_summary
}

main "$@"
