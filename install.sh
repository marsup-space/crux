#!/usr/bin/env bash
# Crux install script — mirrors the opencode install conventions.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/marsup-space/crux/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --version v0.7.0
#   curl -fsSL ... | bash -s -- --binary /path/to/crux
#
# Flags:
#   -h, --help              Show this help
#   -v, --version <ver>     Install a specific version (e.g. v0.7.0)
#   -b, --binary <path>     Install from a local binary instead of downloading
#       --no-modify-path    Don't modify shell config files
#
# Environment variables (also honored):
#   CRUX_VERSION            Same as --version
#   CRUX_INSTALL_DIR        Override the install directory (default: $HOME/.crux/bin)
#   CRUX_REPO               GitHub "owner/repo" (default: marsup-space/crux)
#   CRUX_NO_PATH_UPDATE     Set to 1 to skip PATH modification (alias for --no-modify-path)
#
# After install, the script writes the install dir to one shell rc file (the
# first that exists for the user's $SHELL). The line is guarded by a
# `grep -Fxq` check, so re-runs are a no-op once configured.

set -euo pipefail

APP=crux
REPO="${CRUX_REPO:-marsup-space/crux}"
INSTALL_DIR="${CRUX_INSTALL_DIR:-$HOME/.$APP/bin}"

requested_version="${CRUX_VERSION:-}"
binary_path=""
no_modify_path=false
[ "${CRUX_NO_PATH_UPDATE:-0}" = "1" ] && no_modify_path=true

MUTED='\033[0;2m'
RED='\033[0;31m'
ORANGE='\033[38;5;214m'
NC='\033[0m'

log()  { printf "${ORANGE}==>${NC} %s\n" "$*"; }
info() { printf "${MUTED}%s${NC}\n" "$*"; }
warn() { printf "${ORANGE}warning:${NC} %s\n" "$*" >&2; }
fail() { printf "${RED}error:${NC} %s\n" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Crux Installer

Usage: install.sh [options]

Options:
    -h, --help              Display this help message
    -v, --version <version> Install a specific version (e.g., v0.7.0)
    -b, --binary <path>     Install from a local binary instead of downloading
        --no-modify-path    Don't modify shell config files

Examples:
    curl -fsSL https://raw.githubusercontent.com/marsup-space/crux/main/install.sh | bash
    curl -fsSL .../install.sh | bash -s -- --version v0.7.0
    ./install.sh --binary /path/to/crux
EOF
}

# ---- parse args --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -v|--version)
            [ -n "${2:-}" ] || fail "--version requires a version argument"
            requested_version="$2"; shift 2 ;;
        -b|--binary)
            [ -n "${2:-}" ] || fail "--binary requires a path argument"
            binary_path="$2"; shift 2 ;;
        --no-modify-path) no_modify_path=true; shift ;;
        *) warn "unknown option: $1"; shift ;;
    esac
done

mkdir -p "$INSTALL_DIR"

# ---- detect OS / arch --------------------------------------------------------
# Skipped when installing from --binary; we don't need the target info then.
target=""
if [ -z "$binary_path" ]; then
    raw_os=$(uname -s)
    case "$raw_os" in
        Darwin) os="macos" ;;
        Linux)  os="linux" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        *) fail "unsupported OS: $raw_os (Windows: use scoop/winget or download the zip manually)" ;;
    esac

    arch=$(uname -m)
    case "$arch" in
        aarch64) arch="arm64" ;;
        x86_64)  arch="x64" ;;
    esac
    case "$arch" in
        arm64|arm64e|x64) ;;
        *) fail "unsupported architecture: $arch" ;;
    esac

    # Rosetta: when an Intel shell runs inside Rosetta 2 on Apple Silicon,
    # uname reports x86_64 but we want the native arm64 binary.
    if [ "$os" = "macos" ] && [ "$arch" = "x64" ]; then
        rosetta=$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)
        [ "$rosetta" = "1" ] && arch="arm64"
    fi

    target="${os}-${arch}"
    asset="${APP}-${target}.zip"
fi

# ---- resolve version ---------------------------------------------------------
if [ -n "$binary_path" ]; then
    [ -f "$binary_path" ] || fail "binary not found: $binary_path"
    specific_version="local"
elif [ -n "$requested_version" ]; then
    requested_version="${requested_version#v}"
    url="https://github.com/${REPO}/releases/download/v${requested_version}/${asset}"
    specific_version="$requested_version"
    http_status=$(curl -sI -o /dev/null -w "%{http_code}" \
        "https://github.com/${REPO}/releases/tag/v${requested_version}")
    [ "$http_status" != "404" ] || fail "release v${requested_version} not found"
else
    url="https://github.com/${REPO}/releases/latest/download/${asset}"
    specific_version=$(
        curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
            | grep '"tag_name"' \
            | head -1 \
            | sed -E 's/.*"tag_name":[[:space:]]*"v?([^"]+)".*/\1/'
    )
    [ -n "$specific_version" ] || fail "failed to fetch latest version (rate-limited?)"
fi

# ---- check for matching installed version ------------------------------------
if [ -z "$binary_path" ] && command -v "$APP" >/dev/null 2>&1; then
    installed=$("$APP" --version 2>/dev/null | sed -E 's/^v?//' || echo "")
    if [ "$installed" = "$specific_version" ]; then
        info "crux v${specific_version} already installed"
        exit 0
    fi
    [ -n "$installed" ] && info "Installed version: v${installed}"
fi

log "Installing crux v${specific_version}${target:+ ($target)} -> $INSTALL_DIR"

# ---- download + install ------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -n "$binary_path" ]; then
    cp "$binary_path" "${INSTALL_DIR}/${APP}"
    chmod 755 "${INSTALL_DIR}/${APP}"
else
    command -v curl >/dev/null 2>&1 || fail "curl is required but not installed"
    command -v unzip >/dev/null 2>&1 || fail "unzip is required but not installed"

    curl -fL --retry 3 --connect-timeout 15 -o "${tmp}/${asset}" "$url" \
        || fail "download failed: $url"
    unzip -q -o "${tmp}/${asset}" -d "$tmp"

    # The zip extracts to crux-<target>/{providers,themes,third_party,...}
    # plus the binary, whose location depends on the layout: legacy zips
    # ship crux-<target>/crux, current `dart build cli` zips ship
    # crux-<target>/bin/crux. Windows artifacts are crux.exe. Try the
    # top level first, then bin/.
    bundle_dir=$(find "$tmp" -maxdepth 1 -type d -name "${APP}-*" | head -1)
    [ -n "$bundle_dir" ] || fail "unexpected zip layout — no ${APP}-* top-level dir"

    binary=""
    for candidate in \
        "${bundle_dir}/${APP}" \
        "${bundle_dir}/${APP}.exe" \
        "${bundle_dir}/bin/${APP}" \
        "${bundle_dir}/bin/${APP}.exe"; do
        if [ -x "$candidate" ]; then
            binary="$candidate"
            break
        fi
    done
    [ -n "$binary" ] || fail "extracted binary is missing or not executable"

    # Preserve the source name (crux vs crux.exe) so the installed file
    # stays invocable from cmd/PowerShell on Windows.
    install -m 0755 "$binary" "${INSTALL_DIR}/$(basename "$binary")"

    # Copy bundled assets as siblings of the binary.
    for asset_dir in providers themes third_party; do
        src="${bundle_dir}/${asset_dir}"
        [ -d "$src" ] || continue
        rm -rf "${INSTALL_DIR:?}/${asset_dir}"
        cp -R "$src" "${INSTALL_DIR}/"
    done
fi

# ---- PATH update -------------------------------------------------------------
add_to_path() {
    local config_file="$1" command="$2"
    if [ -f "$config_file" ] && grep -Fxq "$command" "$config_file" 2>/dev/null; then
        info "PATH already configured in $config_file"
    elif [ -w "$config_file" ] 2>/dev/null; then
        printf '\n# crux\n%s\n' "$command" >> "$config_file"
        info "Added $APP to PATH in $config_file"
    else
        warn "Cannot write to $config_file; add this line manually:"
        printf '     %s\n' "$command" >&2
    fi
}

if [ "$no_modify_path" != "true" ]; then
    XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
    current_shell=$(basename "${SHELL:-/bin/sh}")
    case "$current_shell" in
        fish)
            config_files="$HOME/.config/fish/config.fish"
            ;;
        zsh)
            config_files="${ZDOTDIR:-$HOME}/.zshrc ${ZDOTDIR:-$HOME}/.zshenv $XDG_CONFIG_HOME/zsh/.zshrc $XDG_CONFIG_HOME/zsh/.zshenv"
            ;;
        bash)
            config_files="$HOME/.bashrc $HOME/.bash_profile $HOME/.profile $XDG_CONFIG_HOME/bash/.bashrc $XDG_CONFIG_HOME/bash/.bash_profile"
            ;;
        ash|sh)
            config_files="$HOME/.ashrc $HOME/.profile /etc/profile"
            ;;
        *)
            config_files="$HOME/.bashrc $HOME/.bash_profile $XDG_CONFIG_HOME/bash/.bashrc $XDG_CONFIG_HOME/bash/.bash_profile"
            ;;
    esac

    config_file=""
    for file in $config_files; do
        if [ -f "$file" ]; then
            config_file="$file"
            break
        fi
    done

    if [ -z "$config_file" ]; then
        warn "No config file found for $current_shell. Add this line manually:"
        printf '     export PATH=%s:$PATH\n' "$INSTALL_DIR" >&2
    elif [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        case "$current_shell" in
            fish) add_to_path "$config_file" "fish_add_path $INSTALL_DIR" ;;
            *)    add_to_path "$config_file" "export PATH=$INSTALL_DIR:\$PATH" ;;
        esac
    fi

    # On Windows (Git Bash / MSYS / Cygwin): the .bashrc update above only
    # affects future Git Bash sessions. Also update the Windows user PATH
    # via setx so cmd and PowerShell see the install too.
    if [ -n "${WINDIR:-}" ] || [ -n "${SYSTEMROOT:-}" ] || command -v setx >/dev/null 2>&1; then
        win_install_dir=$(cygpath -w "$INSTALL_DIR" 2>/dev/null || echo "$INSTALL_DIR")
        win_path=$(cmd //c "echo %PATH%" 2>/dev/null | tr -d '\r' | head -1)
        if [ -n "$win_path" ]; then
            case ";$win_path;" in
                *";$win_install_dir;"*)
                    info "Windows PATH already contains $win_install_dir"
                    ;;
                *)
                    new_path="${win_path};${win_install_dir}"
                    if [ ${#new_path} -ge 1024 ]; then
                        warn "PATH would exceed 1024 chars (setx limit); add $win_install_dir manually"
                    else
                        info "Adding $win_install_dir to Windows PATH (for cmd / PowerShell)"
                        if setx Path "$new_path" >/dev/null 2>&1; then
                            info "Done — open a new cmd or PowerShell window to use crux."
                        else
                            warn "setx failed; add $win_install_dir to your PATH manually"
                        fi
                    fi
                    ;;
            esac
        fi
    fi
fi

# ---- GitHub Actions: append to GITHUB_PATH -----------------------------------
if [ -n "${GITHUB_ACTIONS:-}" ] && [ "$GITHUB_ACTIONS" = "true" ] && [ -n "${GITHUB_PATH:-}" ]; then
    echo "$INSTALL_DIR" >> "$GITHUB_PATH"
    info "Added $INSTALL_DIR to \$GITHUB_PATH"
fi

# ---- summary -----------------------------------------------------------------
info ""
info "Installed: $INSTALL_DIR/$APP"
info ""
info "Run: $APP --version"

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]] && [ "$no_modify_path" != "true" ]; then
    info ""
    info "To use in THIS shell right now:"
    printf '     export PATH=%s:$PATH\n' "$INSTALL_DIR"
    info "(open a new terminal to make it permanent)"
fi
