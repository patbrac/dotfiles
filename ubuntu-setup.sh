#!/usr/bin/env bash
# ============================================================================
#  ubuntu-setup.sh — Ubuntu post-install setup for developer machines
#
#  Installs a curated dev environment: shell, terminal, editor, toolchains,
#  containers and CLI tools. Pick modules interactively or via flags.
#
#  Usage:
#    sudo ./ubuntu-setup.sh                     interactive checklist
#    sudo ./ubuntu-setup.sh --all               everything, unattended
#    sudo ./ubuntu-setup.sh --only zsh,neovim   just those modules
#    ./ubuntu-setup.sh --list                   show available modules
#
#  One-liner (the menu reads from /dev/tty, so it stays interactive):
#    curl -fsSL https://raw.githubusercontent.com/<you>/dotfiles/main/ubuntu-setup.sh | sudo bash
#
#  Tested against Ubuntu 24.04 and 26.04 on amd64/arm64.
# ============================================================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Constants ───────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi
readonly RED GREEN YELLOW CYAN BOLD DIM NC

readonly OPT_DIR="/opt"
readonly KEYRING_DIR="/etc/apt/keyrings"
readonly CURL=(curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15)
RULE="$(printf '─%.0s' {1..62})"
readonly RULE

# Globals filled in by detect_system()
OS_PRETTY="" OS_CODENAME="" ARCH_DEB="" ARCH_NODE="" ARCH_NVIM="" ARCH_JAVA=""
ACTUAL_USER="" ACTUAL_HOME=""

# Runtime state
RUN_MODE="menu"           # menu | all | only
WORKDIR=""
CURSOR=0
MENU_MSG=""
STEP_INDEX=0
TOTAL_STEPS=0
CURRENT_MODULE=""

# ── Module registry ─────────────────────────────────────────────────────────
declare -A MODULES=(
    [clitools]="CLI tools (ripgrep, fd, bat, jq, htop, tmux, tree …)"
    [zsh]="Zsh + Oh-My-Zsh"
    [firacode]="FiraCode Nerd Font"
    [neovim]="Neovim (latest stable from GitHub)"
    [stow]="GNU Stow (dotfile symlinks)"
    [java]="Java (Adoptium Temurin 21 JDK)"
    [gradle]="Gradle (latest)"
    [rust]="Rust (via rustup)"
    [python]="Python tooling (uv)"
    [cpp]="C/C++ toolchain (gcc, g++, cmake, gdb)"
    [docker]="Docker Engine + Compose"
    [nodejs]="Node.js LTS (installed to /opt)"
    [claude]="Claude Code (Anthropic's CLI coding agent)"
)
MODULE_ORDER=(clitools zsh firacode neovim stow java gradle rust python cpp docker nodejs claude)

declare -A SELECTED=()
for key in "${MODULE_ORDER[@]}"; do
    SELECTED[$key]=1   # everything selected by default
done
unset key

# ── Logging ─────────────────────────────────────────────────────────────────
info()    { printf '%s\n' "  ${CYAN}·${NC} $*"; }
success() { printf '%s\n' "  ${GREEN}✓${NC} $*"; }
warn()    { printf '%s\n' "  ${YELLOW}!${NC} $*"; }
fail()    { printf '%s\n' "  ${RED}✗${NC} $*" >&2; }

heading() {  # heading "<tag>" "<title>"
    printf '\n%s\n' "${BOLD}${CYAN}[$1]${NC} ${BOLD}$2${NC}"
}

# ── Traps ───────────────────────────────────────────────────────────────────
cleanup() {
    if [[ -n "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
    fi
    printf '\e[?25h'   # always restore the cursor
}

on_error() {
    fail "Setup failed${CURRENT_MODULE:+ during \"${CURRENT_MODULE}\"} (line $1). See output above."
}

# ── Helpers ─────────────────────────────────────────────────────────────────
need_root() {
    if [[ $EUID -ne 0 ]]; then
        fail "This script must be run as root:  sudo $0"
        exit 1
    fi
}

run_as_user() {
    sudo -u "$ACTUAL_USER" -H -- bash -c "$*"
}

apt_update()  { apt-get update -qq -o Acquire::Retries=3; }
apt_install() { apt-get install -y -qq -o Acquire::Retries=3 "$@"; }

add_apt_keyring() {  # add_apt_keyring <name> <key-url>  → $KEYRING_DIR/<name>.gpg
    install -d -m 0755 "$KEYRING_DIR"
    "${CURL[@]}" "$2" | gpg --dearmor --yes -o "${KEYRING_DIR}/$1.gpg"
    chmod 0644 "${KEYRING_DIR}/$1.gpg"
}

apt_suite_exists() {  # apt_suite_exists <repo-base-url> <suite>
    "${CURL[@]}" --max-time 20 -o /dev/null "${1%/}/dists/$2/Release"
}

# Print the first suite the repo actually serves. New Ubuntu releases often
# aren't in third-party repos yet, so callers pass an LTS fallback.
pick_apt_suite() {  # pick_apt_suite <repo-base-url> <suite> [suite…]
    local base="$1" s
    shift
    for s in "$@"; do
        if apt_suite_exists "$base" "$s"; then
            printf '%s\n' "$s"
            return 0
        fi
    done
    return 1
}

github_latest_tag() {  # github_latest_tag <owner/repo>
    local tag
    tag="$("${CURL[@]}" "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name // empty')"
    if [[ -z "$tag" ]]; then
        fail "Could not resolve the latest release of $1 (GitHub API rate limit?)."
        return 1
    fi
    printf '%s\n' "$tag"
}

detect_system() {
    if [[ ! -r /etc/os-release ]]; then
        fail "/etc/os-release not found — is this really Ubuntu?"
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-Ubuntu}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "This script targets Ubuntu — detected '${OS_PRETTY}'. Proceeding anyway."
    fi
    if [[ -z "$OS_CODENAME" ]]; then
        warn "Could not detect the release codename — assuming 'noble' for apt repos."
        OS_CODENAME="noble"
    fi

    ARCH_DEB="$(dpkg --print-architecture)"
    case "$ARCH_DEB" in
        amd64) ARCH_NODE="x64";   ARCH_NVIM="x86_64"; ARCH_JAVA="x64" ;;
        arm64) ARCH_NODE="arm64"; ARCH_NVIM="arm64";  ARCH_JAVA="aarch64" ;;
        *)
            fail "Unsupported architecture '${ARCH_DEB}' — only amd64 and arm64 are supported."
            exit 1
            ;;
    esac

    ACTUAL_USER="${SUDO_USER:-$(id -un)}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" | cut -d: -f6)"
    if [[ "$ACTUAL_USER" == "root" ]]; then
        warn "No sudo user detected — user-level tools (zsh, rust, uv, Claude Code) will be set up for root."
    fi
}

# ── CLI arguments ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Ubuntu Developer Setup

Usage: sudo $0 [options]

Options:
  -a, --all         Install all modules without showing the menu
      --only LIST   Install a comma-separated list of modules (see --list)
  -l, --list        List available modules and exit
  -h, --help        Show this help and exit

Examples:
  sudo $0                       interactive checklist
  sudo $0 --all                 everything, unattended
  sudo $0 --only zsh,neovim     just those two modules

Menu keys:  ↑/↓ or j/k move · space toggle · a all · n none · enter install · q quit
EOF
}

list_modules() {
    printf '%s\n' "Available modules (keys for --only):"
    local key
    for key in "${MODULE_ORDER[@]}"; do
        printf '  %-10s %s\n' "$key" "${MODULES[$key]}"
    done
}

set_only() {
    local raw="$1" key pick found=0
    for key in "${MODULE_ORDER[@]}"; do
        SELECTED[$key]=0
    done
    local -a picks=()
    IFS=',' read -ra picks <<< "$raw"
    for pick in "${picks[@]}"; do
        pick="${pick// /}"
        if [[ -z "$pick" ]]; then
            continue
        fi
        if [[ -v "MODULES[$pick]" ]]; then
            SELECTED[$pick]=1
            found=1
        else
            fail "Unknown module '${pick}'."
            list_modules >&2
            exit 1
        fi
    done
    if [[ $found -eq 0 ]]; then
        fail "--only requires at least one module key (see --list)."
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--all)   RUN_MODE="all" ;;
            --only=*)   RUN_MODE="only"; set_only "${1#*=}" ;;
            --only)
                if [[ $# -lt 2 ]]; then
                    fail "--only requires a value (see --list)."
                    exit 1
                fi
                shift
                RUN_MODE="only"; set_only "$1"
                ;;
            -l|--list)  list_modules; exit 0 ;;
            -h|--help)  usage; exit 0 ;;
            *)
                fail "Unknown option: $1"
                usage >&2
                exit 1
                ;;
        esac
        shift
    done
}

# ── Interactive menu ────────────────────────────────────────────────────────
selected_count() {
    local key n=0
    for key in "${MODULE_ORDER[@]}"; do
        if [[ ${SELECTED[$key]} -eq 1 ]]; then
            n=$((n + 1))
        fi
    done
    printf '%s\n' "$n"
}

read_key() {
    local k rest
    IFS= read -rsn1 k </dev/tty || { printf 'quit\n'; return 0; }
    case "$k" in
        $'\e')
            IFS= read -rsn2 -t 0.05 rest </dev/tty || true
            case "${rest:-}" in
                '[A'|'OA') printf 'up\n' ;;
                '[B'|'OB') printf 'down\n' ;;
                *)         printf 'nokey\n' ;;
            esac
            ;;
        ''|$'\n'|$'\r') printf 'start\n' ;;
        ' ')            printf 'toggle\n' ;;
        j|J)            printf 'down\n' ;;
        k|K)            printf 'up\n' ;;
        a|A)            printf 'all\n' ;;
        n|N)            printf 'none\n' ;;
        s|S)            printf 'start\n' ;;
        q|Q)            printf 'quit\n' ;;
        *)              printf 'nokey\n' ;;
    esac
}

draw_menu() {
    local key box i=0
    local total=${#MODULE_ORDER[@]} count
    count="$(selected_count)"

    printf '\e[H\n'
    printf '%s\n' "  ${BOLD}Ubuntu Developer Setup${NC}"
    printf '%s\n' "  ${DIM}${OS_PRETTY} · ${ARCH_DEB} · target user: ${ACTUAL_USER}${NC}"
    printf '%s\n\n' "  ${DIM}${RULE}${NC}"

    for key in "${MODULE_ORDER[@]}"; do
        if [[ ${SELECTED[$key]} -eq 1 ]]; then
            box="${GREEN}[✓]${NC}"
        else
            box="${DIM}[ ]${NC}"
        fi
        if [[ $i -eq $CURSOR ]]; then
            printf '%s\n' "  ${CYAN}${BOLD}❯${NC} ${box} ${BOLD}${MODULES[$key]}${NC}"
        else
            printf '%s\n' "    ${box} ${MODULES[$key]}"
        fi
        i=$((i + 1))
    done

    printf '\n%s\n' "  ${DIM}${RULE}${NC}"
    printf '%s\n' "  ${DIM}${count}/${total} selected${NC}"
    printf '%s\n' "  ${DIM}↑/↓ move · space toggle · a all · n none ·${NC} ${BOLD}enter install${NC} ${DIM}· q quit${NC}"
    printf '%s\n' "  ${YELLOW}${MENU_MSG}${NC}"
    printf '\e[J'
}

interactive_menu() {
    if ! ( : </dev/tty ) 2>/dev/null; then
        fail "No terminal available for the interactive menu."
        info "Run non-interactively instead:  --all  or  --only <modules>  (see --help)."
        exit 1
    fi

    local total=${#MODULE_ORDER[@]} action key
    printf '\e[?25l\e[2J'
    while true; do
        draw_menu
        action="$(read_key)"
        case "$action" in
            up)     CURSOR=$(( (CURSOR - 1 + total) % total )) ;;
            down)   CURSOR=$(( (CURSOR + 1) % total )) ;;
            toggle)
                key="${MODULE_ORDER[$CURSOR]}"
                SELECTED[$key]=$(( 1 - SELECTED[$key] ))
                MENU_MSG=""
                ;;
            all)
                for key in "${MODULE_ORDER[@]}"; do SELECTED[$key]=1; done
                MENU_MSG=""
                ;;
            none)
                for key in "${MODULE_ORDER[@]}"; do SELECTED[$key]=0; done
                MENU_MSG=""
                ;;
            start)
                if [[ "$(selected_count)" -gt 0 ]]; then
                    break
                fi
                MENU_MSG="Nothing selected — toggle at least one module, or press q to quit."
                ;;
            quit)
                printf '\e[?25h\n'
                info "Aborted — nothing was installed."
                exit 0
                ;;
        esac
    done
    printf '\e[?25h\e[2J\e[H'
}

# ── Module: base system ─────────────────────────────────────────────────────
base_prepare() {
    heading "prep" "System update & prerequisites"
    info "Refreshing package lists and upgrading the base system …"
    apt_update
    apt-get upgrade -y -qq -o Acquire::Retries=3
    apt_install ca-certificates curl wget git gnupg jq tar unzip xz-utils
    success "Base system ready."
}

# ── Module: CLI tools ───────────────────────────────────────────────────────
install_clitools() {
    info "Installing CLI tools …"
    apt_install \
        git curl wget unzip jq htop tree tmux \
        ripgrep fd-find bat xclip wl-clipboard
    # Ubuntu ships these under different binary names — expose the usual ones.
    if command -v fdfind >/dev/null; then
        ln -sf "$(command -v fdfind)" /usr/local/bin/fd
    fi
    if command -v batcat >/dev/null; then
        ln -sf "$(command -v batcat)" /usr/local/bin/bat
    fi
    success "CLI tools installed."
}

# ── Module: Zsh + Oh-My-Zsh ─────────────────────────────────────────────────
install_zsh() {
    info "Installing Zsh …"
    apt_install zsh

    info "Installing Oh-My-Zsh for ${ACTUAL_USER} …"
    if [[ ! -d "${ACTUAL_HOME}/.oh-my-zsh" ]]; then
        run_as_user 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
    else
        warn "Oh-My-Zsh already installed — skipping."
    fi

    chsh -s "$(command -v zsh)" "$ACTUAL_USER"
    success "Zsh is now the default shell for ${ACTUAL_USER}."
}

# ── Module: FiraCode Nerd Font ──────────────────────────────────────────────
install_firacode() {
    info "Installing FiraCode Nerd Font …"
    apt_install fontconfig

    local tag
    tag="$(github_latest_tag ryanoasis/nerd-fonts)"

    local font_dir="${ACTUAL_HOME}/.local/share/fonts/FiraCode"
    run_as_user "mkdir -p '${font_dir}'"

    "${CURL[@]}" "https://github.com/ryanoasis/nerd-fonts/releases/download/${tag}/FiraCode.tar.xz" \
        -o "${WORKDIR}/FiraCode.tar.xz"
    tar -xf "${WORKDIR}/FiraCode.tar.xz" -C "$font_dir"
    chown -R "${ACTUAL_USER}:" "$font_dir"
    run_as_user "fc-cache -f '${font_dir}'" >/dev/null 2>&1 || true
    success "FiraCode Nerd Font ${tag} installed."
}

# ── Module: Neovim (latest GitHub release) ──────────────────────────────────
install_neovim() {
    info "Installing Neovim (latest stable from GitHub) …"
    local tag
    tag="$(github_latest_tag neovim/neovim)"

    local nvim_dir="${OPT_DIR}/nvim"
    rm -rf "$nvim_dir"
    mkdir -p "$nvim_dir"

    "${CURL[@]}" "https://github.com/neovim/neovim/releases/download/${tag}/nvim-linux-${ARCH_NVIM}.tar.gz" \
        -o "${WORKDIR}/nvim.tar.gz"
    tar -xzf "${WORKDIR}/nvim.tar.gz" -C "$nvim_dir" --strip-components=1
    ln -sf "${nvim_dir}/bin/nvim" /usr/local/bin/nvim
    success "Neovim ${tag} installed to ${nvim_dir}."
}

# ── Module: GNU Stow ────────────────────────────────────────────────────────
install_stow() {
    info "Installing GNU Stow …"
    apt_install stow
    success "Stow installed."
}

# ── Module: Java (Adoptium Temurin 21) ──────────────────────────────────────
install_java() {
    info "Installing Adoptium Temurin 21 JDK …"

    local suite
    if suite="$(pick_apt_suite "https://packages.adoptium.net/artifactory/deb" "$OS_CODENAME" noble)"; then
        if [[ "$suite" != "$OS_CODENAME" ]]; then
            warn "Adoptium has no '${OS_CODENAME}' repo yet — using '${suite}' (binary compatible)."
        fi
        add_apt_keyring adoptium "https://packages.adoptium.net/artifactory/api/gpg/key/public"
        echo "deb [signed-by=${KEYRING_DIR}/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${suite} main" \
            > /etc/apt/sources.list.d/adoptium.list
        apt_update
        apt_install temurin-21-jdk
    else
        # No usable apt suite at all — install the tarball to /opt instead.
        warn "Adoptium apt repo unavailable — falling back to a tarball install in ${OPT_DIR}."
        warn "Tarball installs don't auto-update via apt; re-run this script for newer builds."

        local java_dir="${OPT_DIR}/temurin-21-jdk"
        rm -rf "$java_dir"
        mkdir -p "$java_dir"

        "${CURL[@]}" "https://api.adoptium.net/v3/binary/latest/21/ga/linux/${ARCH_JAVA}/jdk/hotspot/normal/eclipse" \
            -o "${WORKDIR}/temurin-21.tar.gz"
        tar -xzf "${WORKDIR}/temurin-21.tar.gz" -C "$java_dir" --strip-components=1

        local bin
        for bin in java javac jar; do
            ln -sf "${java_dir}/bin/${bin}" "/usr/local/bin/${bin}"
        done
    fi

    success "Adoptium Temurin 21 JDK installed."
}

# ── Module: Gradle ──────────────────────────────────────────────────────────
install_gradle() {
    info "Installing Gradle …"
    local version
    version="$("${CURL[@]}" "https://services.gradle.org/versions/current" | jq -r '.version')"

    "${CURL[@]}" "https://services.gradle.org/distributions/gradle-${version}-bin.zip" \
        -o "${WORKDIR}/gradle.zip"
    unzip -qo "${WORKDIR}/gradle.zip" -d "${WORKDIR}/gradle-extract"

    local gradle_dir="${OPT_DIR}/gradle"
    rm -rf "$gradle_dir"
    mv "${WORKDIR}/gradle-extract/gradle-${version}" "$gradle_dir"
    ln -sf "${gradle_dir}/bin/gradle" /usr/local/bin/gradle
    success "Gradle ${version} installed to ${gradle_dir}."
}

# ── Module: Rust ────────────────────────────────────────────────────────────
install_rust() {
    info "Installing Rust via rustup for ${ACTUAL_USER} …"
    run_as_user 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
    success "Rust installed. Source \$HOME/.cargo/env to use it now."
}

# ── Module: Python (uv) ─────────────────────────────────────────────────────
install_python() {
    info "Installing Python tooling (uv) for ${ACTUAL_USER} …"
    run_as_user 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    success "uv installed. Use 'uv python install' to grab Python versions."
}

# ── Module: C/C++ ───────────────────────────────────────────────────────────
install_cpp() {
    info "Installing C/C++ toolchain …"
    apt_install build-essential gcc g++ cmake make gdb pkg-config
    success "gcc/g++/cmake/make/gdb installed."
}

# ── Module: Docker ──────────────────────────────────────────────────────────
install_docker() {
    info "Installing Docker Engine …"

    if command -v docker >/dev/null; then
        warn "Docker already installed — skipping package install."
    else
        local suite
        if ! suite="$(pick_apt_suite "https://download.docker.com/linux/ubuntu" "$OS_CODENAME" noble)"; then
            fail "Docker's apt repo is unreachable."
            return 1
        fi
        if [[ "$suite" != "$OS_CODENAME" ]]; then
            warn "Docker has no '${OS_CODENAME}' repo yet — using '${suite}'."
        fi

        add_apt_keyring docker "https://download.docker.com/linux/ubuntu/gpg"
        echo "deb [arch=${ARCH_DEB} signed-by=${KEYRING_DIR}/docker.gpg] https://download.docker.com/linux/ubuntu ${suite} stable" \
            > /etc/apt/sources.list.d/docker.list

        apt_update
        apt_install docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    fi

    usermod -aG docker "$ACTUAL_USER"
    success "Docker installed — ${ACTUAL_USER} added to the docker group (applies after re-login)."
}

# ── Module: Node.js LTS (to /opt) ───────────────────────────────────────────
install_nodejs() {
    info "Installing Node.js LTS to ${OPT_DIR} …"
    local version
    version="$("${CURL[@]}" "https://nodejs.org/dist/index.json" \
        | jq -r '[.[] | select(.lts != false)][0].version')"

    local node_dir="${OPT_DIR}/nodejs"
    rm -rf "$node_dir"
    mkdir -p "$node_dir"

    "${CURL[@]}" "https://nodejs.org/dist/${version}/node-${version}-linux-${ARCH_NODE}.tar.xz" \
        -o "${WORKDIR}/node.tar.xz"
    tar -xf "${WORKDIR}/node.tar.xz" -C "$node_dir" --strip-components=1

    local bin
    for bin in node npm npx corepack; do
        if [[ -e "${node_dir}/bin/${bin}" ]]; then
            ln -sf "${node_dir}/bin/${bin}" "/usr/local/bin/${bin}"
        fi
    done
    success "Node.js ${version} installed to ${node_dir}."
}

# ── Module: Claude Code ─────────────────────────────────────────────────────
install_claude() {
    info "Installing Claude Code for ${ACTUAL_USER} …"
    # Official native installer — standalone binary, no Node.js required.
    run_as_user 'curl -fsSL https://claude.ai/install.sh | bash'
    success "Claude Code installed to ${ACTUAL_HOME}/.local/bin/claude."
}

# ── Post-install: shell profile paths ───────────────────────────────────────
write_path_snippet() {
    heading "post" "Shell profile (PATH for /opt tools & ~/.local/bin)"

    local java_home="" d
    if [[ -d "${OPT_DIR}/temurin-21-jdk" ]]; then
        java_home="${OPT_DIR}/temurin-21-jdk"
    else
        for d in /usr/lib/jvm/temurin-21-jdk-*; do
            if [[ -d "$d" ]]; then
                java_home="$d"
                break
            fi
        done
    fi

    # POSIX snippet, existence-checked and dedup-guarded, so it is safe to
    # source from /etc/profile.d (bash/dash) AND /etc/zsh/zshenv (every zsh).
    # Last entry in the list ends up first in PATH, so ~/.local/bin wins.
    cat > /etc/profile.d/custom-paths.sh <<EOF
# Generated by ubuntu-setup.sh — dev tool paths
for _d in ${OPT_DIR}/gradle/bin ${OPT_DIR}/nvim/bin ${OPT_DIR}/nodejs/bin "\$HOME/.local/bin"; do
    if [ -d "\$_d" ]; then
        case ":\$PATH:" in
            *":\$_d:"*) ;;
            *) PATH="\$_d:\$PATH" ;;
        esac
    fi
done
unset _d
export PATH
EOF
    if [[ -n "$java_home" ]]; then
        printf 'export JAVA_HOME="%s"\n' "$java_home" >> /etc/profile.d/custom-paths.sh
    fi

    # Zsh login shells do not source /etc/profile.d on Ubuntu — hook the same
    # snippet into the system-wide zshenv (idempotently) so zsh users get it.
    if [[ -d /etc/zsh ]] && ! grep -qs 'custom-paths.sh' /etc/zsh/zshenv; then
        cat >> /etc/zsh/zshenv <<'EOF'

# Added by ubuntu-setup.sh — zsh does not source /etc/profile.d
if [ -f /etc/profile.d/custom-paths.sh ]; then
    . /etc/profile.d/custom-paths.sh
fi
EOF
    fi

    success "Wrote /etc/profile.d/custom-paths.sh (hooked into bash/sh and zsh)."
}

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
    local mins=$(( SECONDS / 60 )) secs=$(( SECONDS % 60 ))

    printf '\n%s\n' "  ${DIM}${RULE}${NC}"
    printf '%s\n' "  ${BOLD}${GREEN}Setup complete${NC}${BOLD} — ${TOTAL_STEPS} modules in ${mins}m ${secs}s${NC}"
    printf '%s\n\n' "  ${DIM}${RULE}${NC}"

    printf '%s\n' "  ${BOLD}Next steps${NC}"
    echo "    • Log out and back in (or reboot) so shell, group and PATH changes apply."
    if [[ ${SELECTED[stow]} -eq 1 ]]; then
        echo "    • Clone your dotfiles and run:  cd dotfiles && stow <package>"
    fi
    if [[ ${SELECTED[rust]} -eq 1 ]]; then
        echo "    • Rust:  source \"\$HOME/.cargo/env\" (or just re-login)."
    fi
    if [[ ${SELECTED[python]} -eq 1 ]]; then
        echo "    • Python:  uv python install 3.13"
    fi
    if [[ ${SELECTED[docker]} -eq 1 ]]; then
        echo "    • Docker:  test with 'docker run hello-world' after re-login."
    fi
    if [[ ${SELECTED[claude]} -eq 1 ]]; then
        echo "    • Claude Code:  run 'claude' in a project to sign in."
    fi
    echo ""
}

# ── Orchestration ───────────────────────────────────────────────────────────
run_module() {
    local key="$1"
    STEP_INDEX=$((STEP_INDEX + 1))
    CURRENT_MODULE="${MODULES[$key]}"
    heading "${STEP_INDEX}/${TOTAL_STEPS}" "$CURRENT_MODULE"
    "install_${key}"
    CURRENT_MODULE=""
}

main() {
    parse_args "$@"
    need_root
    detect_system

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'on_error $LINENO' ERR
    WORKDIR="$(mktemp -d)"

    if [[ "$RUN_MODE" == "menu" ]]; then
        interactive_menu
    fi

    TOTAL_STEPS="$(selected_count)"
    printf '\n%s\n' "  ${BOLD}Installing ${TOTAL_STEPS} of ${#MODULE_ORDER[@]} modules${NC} ${DIM}(${OS_PRETTY} · ${ARCH_DEB} · user: ${ACTUAL_USER})${NC}"

    SECONDS=0
    base_prepare

    local key
    for key in "${MODULE_ORDER[@]}"; do
        if [[ ${SELECTED[$key]} -eq 1 ]]; then
            run_module "$key"
        fi
    done

    write_path_snippet
    print_summary
}

# Allow sourcing for tests without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
