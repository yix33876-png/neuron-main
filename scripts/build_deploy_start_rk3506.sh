#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build_deploy_start_rk3506.sh [options]

Build Neuron for RK3506, deploy it to /opt/neuron, then start NanoMQ and
Neuron on the target board.

Options:
  --host <ip>             RK3506 IP. If omitted, prompt interactively
  --user <name>           SSH user. Default: root
  --password <password>   SSH password. Default: root
  --build-dir <path>      Build directory. Default: <repo>/build-armhf
  --staging-dir <path>    Dependency staging dir. Default: $STAGING or ~/neuron-staging/arm-linux-gnueabihf
  --bundle-dir <path>     Local deploy bundle dir. Default: /tmp/neuron-rk3506
  --neuron-dir <path>     Target Neuron dir. Default: /opt/neuron
  --nanomq-conf <path>    Target NanoMQ conf. Default: /root/nanomq-local.conf
  --plugins-only          Deploy only MQTT/Auth/Aggregate plugins and schemas
  --skip-build            Reuse current build output
  --skip-package          Reuse current bundle output
  --skip-start            Build and deploy only, do not restart services
  --skip-dashboard        Do not copy dashboard dist into bundle
  -h, --help              Show this help

Examples:
  scripts/build_deploy_start_rk3506.sh --host 192.168.9.10
  scripts/build_deploy_start_rk3506.sh --host 192.168.9.10 --plugins-only
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

ssh_target() {
  printf '%s@%s' "$ssh_user" "$host"
}

remote_run() {
  sshpass -p "$password" ssh -o StrictHostKeyChecking=no "$(ssh_target)" "$@"
}

remote_copy() {
  sshpass -p "$password" scp -o StrictHostKeyChecking=no "$@"
}

host=""
ssh_user="root"
password="root"
neuron_dir="/opt/neuron"
nanomq_conf="/root/nanomq-local.conf"
bundle_dir="/tmp/neuron-rk3506"
plugins_only=0
skip_build=0
skip_package=0
skip_start=0
skip_dashboard=0
build_dir=""
staging_dir="${STAGING:-$HOME/neuron-staging/arm-linux-gnueabihf}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || die "missing value for --host"
      host="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || die "missing value for --user"
      ssh_user="$2"
      shift 2
      ;;
    --password)
      [[ $# -ge 2 ]] || die "missing value for --password"
      password="$2"
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
    --bundle-dir)
      [[ $# -ge 2 ]] || die "missing value for --bundle-dir"
      bundle_dir="$2"
      shift 2
      ;;
    --neuron-dir)
      [[ $# -ge 2 ]] || die "missing value for --neuron-dir"
      neuron_dir="$2"
      shift 2
      ;;
    --nanomq-conf)
      [[ $# -ge 2 ]] || die "missing value for --nanomq-conf"
      nanomq_conf="$2"
      shift 2
      ;;
    --plugins-only)
      plugins_only=1
      shift
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --skip-package)
      skip_package=1
      shift
      ;;
    --skip-start)
      skip_start=1
      shift
      ;;
    --skip-dashboard)
      skip_dashboard=1
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
require_cmd sshpass
require_cmd scp
require_cmd ssh

if [[ -z "$host" ]]; then
  read -r -p "RK3506 IP: " host
fi
[[ -n "$host" ]] || die "RK3506 IP is required"

repo_root="$(find_repo_root)"
if [[ -z "$build_dir" ]]; then
  build_dir="$repo_root/build-armhf"
fi

export TARGET=arm-linux-gnueabihf
export STAGING="$staging_dir"

[[ -d "$STAGING/lib" ]] || die "staging lib directory not found: $STAGING/lib"
[[ -f "$repo_root/cmake/arm-linux-gnueabihf.cmake" ]] || die "missing toolchain file"

echo "==> Repo:        $repo_root"
echo "==> Build dir:   $build_dir"
echo "==> Staging:     $STAGING"
echo "==> Bundle dir:  $bundle_dir"
echo "==> Target:      $(ssh_target)"
echo "==> Neuron dir:  $neuron_dir"
echo "==> NanoMQ conf: $nanomq_conf"

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

  if [[ "$plugins_only" -eq 1 ]]; then
    echo "==> Building MQTT plugins"
    cmake --build "$build_dir" \
      --target plugin-mqtt plugin-mqtt-auth plugin-mqtt-aggregate \
      -j"$(nproc)"
  else
    echo "==> Building Neuron and plugins"
    cmake --build "$build_dir" -j"$(nproc)"
  fi
else
  echo "==> Build skipped"
fi

plugin_files=(
  "$build_dir/plugins/libplugin-mqtt.so"
  "$build_dir/plugins/libplugin-mqtt-auth.so"
  "$build_dir/plugins/libplugin-mqtt-aggregate.so"
)

schema_files=(
  "$build_dir/plugins/schema/mqtt.json"
  "$build_dir/plugins/schema/mqtt-auth.json"
  "$build_dir/plugins/schema/mqtt-aggregate.json"
)

for f in "${plugin_files[@]}" "${schema_files[@]}" "$repo_root/default_plugins.json"; do
  [[ -f "$f" ]] || die "missing build artifact: $f"
done

echo "==> Verifying plugin architecture"
file "${plugin_files[@]}"

if [[ "$plugins_only" -eq 0 || "$skip_start" -eq 0 ]]; then
  echo "==> Stopping target services before deploy"
  remote_run "
if [ -x /usr/local/bin/nanomq ]; then
  /usr/local/bin/nanomq stop >/tmp/nanomq-stop.log 2>&1 || true
fi
pkill neuron >/dev/null 2>&1 || true
sleep 1
"
fi

if [[ "$plugins_only" -eq 1 ]]; then
  echo "==> Preparing target directories"
  remote_run "mkdir -p '$neuron_dir/plugins/schema' '$neuron_dir/config' '$neuron_dir/logs'"

  echo "==> Deploying plugins"
  remote_copy "${plugin_files[@]}" "$(ssh_target):$neuron_dir/plugins/"

  echo "==> Deploying schemas"
  remote_copy "${schema_files[@]}" "$(ssh_target):$neuron_dir/plugins/schema/"

  echo "==> Deploying default plugin list"
  remote_copy "$repo_root/default_plugins.json" "$(ssh_target):$neuron_dir/config/default_plugins.json"
else
  if [[ "$skip_package" -eq 0 ]]; then
    package_args=(
      --root-dir "$repo_root"
      --build-dir "$build_dir"
      --output-dir "$bundle_dir"
      --staging-dir "$STAGING"
    )
    if [[ "$skip_dashboard" -eq 1 ]]; then
      package_args+=(--skip-dashboard)
    fi
    echo "==> Packaging full Neuron bundle"
    bash "$repo_root/scripts/package_rk3506_bundle.sh" "${package_args[@]}"
  else
    echo "==> Package skipped"
  fi

  [[ -d "$bundle_dir" ]] || die "bundle directory not found: $bundle_dir"

  echo "==> Preparing target Neuron directory"
  remote_run "mkdir -p '$neuron_dir'"

  echo "==> Deploying full Neuron bundle"
  remote_copy -r "$bundle_dir"/. "$(ssh_target):$neuron_dir/"
fi

if [[ "$skip_start" -eq 1 ]]; then
  echo "==> Build and deploy complete. Service start skipped."
  exit 0
fi

echo "==> Restarting NanoMQ and Neuron on target"
remote_run "
set -e
if [ ! -x /usr/local/bin/nanomq ]; then
  echo 'warning: /usr/local/bin/nanomq not found or not executable; skip NanoMQ start' >&2
else
  /usr/local/bin/nanomq stop >/tmp/nanomq-stop.log 2>&1 || true
fi
pkill neuron >/dev/null 2>&1 || true
sleep 1
if [ -x /usr/local/bin/nanomq ]; then
  if [ -f '$nanomq_conf' ]; then
    nohup /usr/local/bin/nanomq start --conf '$nanomq_conf' --log_level info --log_stdout false >/tmp/nanomq-stdout.log 2>&1 &
  else
    echo 'warning: NanoMQ config not found: $nanomq_conf; skip NanoMQ start' >&2
  fi
fi
cd '$neuron_dir'
LD_LIBRARY_PATH='$neuron_dir/lib' ./neuron --config_dir '$neuron_dir/config' --plugin_dir '$neuron_dir/plugins' -d
sleep 2
ps | grep -E 'neuron|nanomq' | grep -v grep || true
netstat -lntp 2>/dev/null | grep -E ':(7000|1883)' || true
"

echo "==> Done"
echo "Check aggregate messages with:"
echo "  mosquitto_sub -h $host -p 1883 -t 'neuron/+/aggregate' -v"
