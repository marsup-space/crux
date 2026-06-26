#!/usr/bin/env bash
# Crux local release script — builds a version from source and installs it
# to ~/.crux/bin/. This is the local equivalent of `install.sh` (which
# downloads a release zip from GitHub).
#
# Usage:
#   ./release.sh 0.8.1                    # bump + build + install
#   ./release.sh 0.8.1 --skip-bump        # build + install only
#   ./release.sh 0.8.1 --no-install       # bump + build, skip install
#   ./release.sh 0.8.1 --commit           # also git commit + tag v<version>
#   ./release.sh 0.8.1 --install-dir DIR  # override install dir
#   ./release.sh 0.8.1 --clean            # delete build/releases/ after install
#   ./release.sh 0.8.1 --semble-bin PATH  # path to semble binary (default below)
#   ./release.sh 0.8.1 --no-semble        # skip the semble copy step
#   ./release.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION=""
SKIP_BUMP=false
NO_INSTALL=false
DO_COMMIT=false
DO_CLEAN=false
NO_SEMBLE=false
INSTALL_DIR="${CRUX_INSTALL_DIR:-$HOME/.crux/bin}"
SEMBLE_BIN="${CRUX_SEMBLE_BIN:-$SCRIPT_DIR/.research/.venv-semble/bin/semble}"

usage() {
  cat <<EOF
Usage: $0 <version> [options]

Arguments:
  <version>           Semver version, with or without leading 'v' (e.g. 0.8.1)

Options:
  --skip-bump         Skip version bump; assume pubspec.yaml + bin/crux.dart
                      are already at the target version.
  --no-install        Build the bundle but don't copy it to the install dir.
  --commit            After a successful build+install, git commit the
                      version-bump files and create tag v<version>.
  --install-dir DIR   Override install dir (default: \$CRUX_INSTALL_DIR or
                      ~/.crux/bin).
  --clean             Delete the build/releases/crux-<target>/ output after
                      a successful install.
  --semble-bin PATH   Path to the \`semble\` binary to copy into the install
                      dir's third_party/bin/. Default: the venv at
                      <repo>/.research/.venv-semble/bin/semble. The copy
                      is skipped with a warning if the source doesn't
                      exist or if --no-semble is set.
  --no-semble         Skip the semble copy step (useful if you don't use
                      semantic_search / find_similar_code).
  -h, --help          Show this help.

Environment:
  CRUX_INSTALL_DIR    Override the default install dir (matches install.sh).
  CRUX_SEMBLE_BIN     Override the default semble binary path (matches
                      --semble-bin).

Examples:
  ./release.sh 0.8.1
  ./release.sh v0.8.1 --commit
  CRUX_INSTALL_DIR=/tmp/crux-test ./release.sh 0.8.1 --no-install
EOF
}

# ---- parse args --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-bump)    SKIP_BUMP=true; shift ;;
    --no-install)   NO_INSTALL=true; shift ;;
    --commit)       DO_COMMIT=true; shift ;;
    --clean)        DO_CLEAN=true; shift ;;
    --no-semble)    NO_SEMBLE=true; shift ;;
    --semble-bin)   SEMBLE_BIN="${2:?--semble-bin requires a path}"; shift 2 ;;
    --install-dir)  INSTALL_DIR="${2:?--install-dir requires a path}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)
      [[ -z "$VERSION" ]] || { echo "Multiple versions given: '$VERSION' and '$1'" >&2; exit 1; }
      VERSION="${1#v}"
      shift ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Error: version is required" >&2
  usage
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: '$VERSION' is not a valid semver version" >&2
  exit 1
fi

# ---- resolve repo + target ---------------------------------------------------
# SCRIPT_DIR is set at the top of the script.
cd "$SCRIPT_DIR"

# Detect target from uname (matches build_release.dart's allowed targets).
raw_os=$(uname -s)
case "$raw_os" in
  Darwin)  os="macos" ;;
  Linux)   os="linux" ;;
  MINGW*|MSYS*|CYGWIN*) os="windows" ;;
  *)       echo "Unsupported OS: $raw_os" >&2; exit 1 ;;
esac
arch=$(uname -m)
case "$arch" in
  aarch64) arch="arm64" ;;
  x86_64)  arch="x64" ;;
esac
if [[ "$os" == "macos" && "$arch" == "x64" ]]; then
  rosetta=$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)
  [[ "$rosetta" == "1" ]] && arch="arm64"
fi
TARGET="${os}-${arch}"
BUNDLE_DIR="$SCRIPT_DIR/build/releases/crux-$TARGET"
EXPECTED_VERSION="v$VERSION"

echo "==> Repo:        $SCRIPT_DIR"
echo "==> Target:      $TARGET"
echo "==> Version:     $EXPECTED_VERSION"
echo "==> Install dir: $INSTALL_DIR"
echo ""

# ---- 1. bump version ---------------------------------------------------------
if [[ "$SKIP_BUMP" == "true" ]]; then
  echo "==> [1/3] Skipping version bump (--skip-bump)"
else
  echo "==> [1/3] Bumping version in pubspec.yaml, bin/crux.dart, README.md"
  dart run tool/prepare_release.dart "$VERSION"
fi

# ---- 2. build release bundle ------------------------------------------------
echo ""
echo "==> [2/3] Building release bundle"
dart run tool/build_release.dart

if [[ ! -f "$BUNDLE_DIR/bin/crux" ]]; then
  echo "Error: expected build artifact not found: $BUNDLE_DIR/bin/crux" >&2
  exit 1
fi

# Sanity-check the built binary reports the right version.
REPORTED="$("$BUNDLE_DIR/bin/crux" --version 2>/dev/null || true)"
if [[ "$REPORTED" != "$EXPECTED_VERSION" ]]; then
  echo "Error: built binary reports '$REPORTED', expected '$EXPECTED_VERSION'" >&2
  echo "       (Did you forget to bump pubspec.yaml? Try without --skip-bump.)" >&2
  exit 1
fi
echo "    Built binary reports: $REPORTED ✓"

# ---- 3. install --------------------------------------------------------------
if [[ "$NO_INSTALL" == "true" ]]; then
  echo ""
  echo "==> [3/3] Skipping install (--no-install)"
  echo "    Bundle: $BUNDLE_DIR"
else
  echo ""
  echo "==> [3/3] Installing to $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$BUNDLE_DIR/bin/crux" "$INSTALL_DIR/crux"
  for d in providers themes third_party; do
    rm -rf "${INSTALL_DIR:?}/$d"
    cp -R "$BUNDLE_DIR/$d" "$INSTALL_DIR/"
  done
  echo "    Installed: $INSTALL_DIR/crux -> $("$INSTALL_DIR/crux" --version)"

  # Copy `semble` into the install dir's third_party/bin/ so the
  # semantic_search / find_similar_code tools can resolve it without
  # referencing any project paths. `semble` is a Python shebang script
  # in a venv — the copy keeps the shebang intact, so the install dir
  # still depends on the source venv existing at the original path.
  # Skipped with a warning if the source is missing or --no-semble.
  if [[ "$NO_SEMBLE" == "true" ]]; then
    echo "    Skipping semble copy (--no-semble)."
  elif [[ ! -e "$SEMBLE_BIN" ]]; then
    echo "    ⚠  semble not found at: $SEMBLE_BIN"
    echo "       (semantic_search / find_similar_code won't work until"
    echo "        you install semble or pass --semble-bin PATH.)"
  else
    mkdir -p "$INSTALL_DIR/third_party/bin"
    cp "$SEMBLE_BIN" "$INSTALL_DIR/third_party/bin/semble"
    chmod +x "$INSTALL_DIR/third_party/bin/semble"
    echo "    Copied semble: $SEMBLE_BIN -> $INSTALL_DIR/third_party/bin/semble"
  fi
fi

# ---- optional: clean + commit/tag -------------------------------------------
if [[ "$DO_CLEAN" == "true" && "$NO_INSTALL" != "true" ]]; then
  echo ""
  echo "==> Cleaning $BUNDLE_DIR"
  rm -rf "$BUNDLE_DIR"
fi

if [[ "$DO_COMMIT" == "true" ]]; then
  echo ""
  echo "==> Committing and tagging $EXPECTED_VERSION"
  git add pubspec.yaml bin/crux.dart README.md
  if git diff --cached --quiet; then
    echo "    No version-bump changes to commit."
  else
    git commit -m "Release $EXPECTED_VERSION"
    git tag "$EXPECTED_VERSION"
    echo "    Committed. Push with:"
    echo "      git push origin master"
    echo "      git push origin $EXPECTED_VERSION"
  fi
fi

echo ""
echo "==> Done. 'crux --version' will report $EXPECTED_VERSION in any new shell."