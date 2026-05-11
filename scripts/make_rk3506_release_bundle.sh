#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: make_rk3506_release_bundle.sh [options]

Build and package a RK3506 gateway release asset. The output tarball contains
Neuron and NanoMQ runtime files and can be uploaded to a GitHub or Codeup
release.

Options:
  --version <name>        Release version. Default: current git short hash
  --build-dir <path>      Build directory. Default: <repo>/build-armhf
  --staging-dir <path>    Dependency staging dir. Default: $STAGING or ~/neuron-staging/arm-linux-gnueabihf
  --nanomq-root <path>    NanoMQ repo root. Default: ~/nanomq-master
  --nanomq-bin <path>     NanoMQ ARMHF binary. Default: <nanomq-root>/build-rk3506/nanomq/nanomq
  --nanomq-etc <path>     NanoMQ config dir. Default: <nanomq-root>/etc
  --bundle-dir <path>     Temporary bundle dir. Default: /tmp/neuron-rk3506-release
  --output-dir <path>     Output dir. Default: <repo>/dist
  --skip-build            Reuse current build output
  --skip-dashboard        Do not copy dashboard dist into bundle
  --skip-nanomq           Do not include NanoMQ in release asset
  -h, --help              Show this help

Example:
  scripts/make_rk3506_release_bundle.sh --version v1.0.0
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

is_repo_root() {
  [[ -f "$1/CMakeLists.txt" && -d "$1/plugins/mqtt" && -d "$1/scripts" ]]
}

find_repo_root() {
  local probe
  probe="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if is_repo_root "$probe"; then
    printf '%s\n' "$probe"
    return
  fi

  probe="$PWD"
  while [[ "$probe" != "/" ]]; do
    if is_repo_root "$probe"; then
      printf '%s\n' "$probe"
      return
    fi
    probe="$(dirname "$probe")"
  done

  die "cannot find neuron repo root"
}

repo_root="$(find_repo_root)"
version=""
build_dir="$repo_root/build-armhf"
staging_dir="${STAGING:-$HOME/neuron-staging/arm-linux-gnueabihf}"
nanomq_root="$HOME/nanomq-master"
nanomq_bin=""
nanomq_etc=""
bundle_dir="/tmp/neuron-rk3506-release"
output_dir="$repo_root/dist"
skip_build=0
skip_dashboard=0
skip_nanomq=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "missing value for --version"
      version="$2"
      shift 2
      ;;
    --build-dir)
      [[ $# -ge 2 ]] || die "missing value for --build-dir"
      build_dir="$2"
      shift 2
      ;;
    --staging-dir)
      [[ $# -ge 2 ]] || die "missing value for --staging-dir"
      staging_dir="$2"
      shift 2
      ;;
    --nanomq-root)
      [[ $# -ge 2 ]] || die "missing value for --nanomq-root"
      nanomq_root="$2"
      shift 2
      ;;
    --nanomq-bin)
      [[ $# -ge 2 ]] || die "missing value for --nanomq-bin"
      nanomq_bin="$2"
      shift 2
      ;;
    --nanomq-etc)
      [[ $# -ge 2 ]] || die "missing value for --nanomq-etc"
      nanomq_etc="$2"
      shift 2
      ;;
    --bundle-dir)
      [[ $# -ge 2 ]] || die "missing value for --bundle-dir"
      bundle_dir="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "missing value for --output-dir"
      output_dir="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --skip-dashboard)
      skip_dashboard=1
      shift
      ;;
    --skip-nanomq)
      skip_nanomq=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

require_cmd cmake
require_cmd tar
require_cmd sha256sum

if [[ -z "$version" ]]; then
  if git -C "$repo_root" rev-parse --short HEAD >/dev/null 2>&1; then
    version="$(git -C "$repo_root" rev-parse --short HEAD)"
  else
    version="$(date +%Y%m%d%H%M%S)"
  fi
fi

export TARGET=arm-linux-gnueabihf
export STAGING="$staging_dir"

[[ -d "$STAGING/lib" ]] || die "staging lib directory not found: $STAGING/lib"

if [[ "$skip_nanomq" -eq 0 ]]; then
  if [[ -z "$nanomq_bin" ]]; then
    nanomq_bin="$nanomq_root/build-rk3506/nanomq/nanomq"
  fi
  if [[ -z "$nanomq_etc" ]]; then
    nanomq_etc="$nanomq_root/etc"
  fi
  [[ -f "$nanomq_bin" ]] || die "NanoMQ binary not found: $nanomq_bin"
  [[ -d "$nanomq_etc" ]] || die "NanoMQ config directory not found: $nanomq_etc"
fi

if [[ "$skip_build" -eq 0 ]]; then
  echo "==> Configuring ARMHF build"
  cmake -S "$repo_root" \
    -B "$build_dir" \
    -DCMAKE_TOOLCHAIN_FILE="$repo_root/cmake/arm-linux-gnueabihf.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DDISABLE_UT=ON \
    -DDISABLE_ASAN=ON \
    -DDISABLE_WERROR=ON \
    -DENABLE_DATALAYERS=OFF

  echo "==> Building Neuron"
  cmake --build "$build_dir" -j"$(nproc)"
else
  echo "==> Build skipped"
fi

package_args=(
  --root-dir "$repo_root"
  --build-dir "$build_dir"
  --output-dir "$bundle_dir/neuron"
  --staging-dir "$STAGING"
)
if [[ "$skip_dashboard" -eq 1 ]]; then
  package_args+=(--skip-dashboard)
fi

echo "==> Preparing bundle"
rm -rf "$bundle_dir"
mkdir -p "$bundle_dir"
bash "$repo_root/scripts/package_rk3506_bundle.sh" "${package_args[@]}"
cp -a "$repo_root/scripts/deploy_rk3506_release_bundle.sh" "$bundle_dir/"
cp -a "$repo_root/scripts/install_rk3506_release_on_target.sh" "$bundle_dir/"

if [[ "$skip_nanomq" -eq 0 ]]; then
  echo "==> Adding NanoMQ runtime"
  mkdir -p "$bundle_dir/nanomq/bin" "$bundle_dir/nanomq/etc"
  cp -a "$nanomq_bin" "$bundle_dir/nanomq/bin/nanomq"
  cp -a "$nanomq_etc"/*.conf "$bundle_dir/nanomq/etc/"
  chmod +x "$bundle_dir/nanomq/bin/nanomq"
  file "$bundle_dir/nanomq/bin/nanomq"
fi

mkdir -p "$output_dir"
asset="$output_dir/industrial-iot-rk3506-${version}.tar.gz"

echo "==> Creating $asset"
tar -C "$bundle_dir" -czf "$asset" .
(
  cd "$output_dir"
  sha256sum "$(basename "$asset")" > "$(basename "$asset").sha256"
)

echo
echo "Release asset ready:"
echo "  $asset"
echo "  $asset.sha256"
