#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy_rk3506_release_bundle.sh [options]

Deploy a prebuilt RK3506 gateway release bundle to a target board, then start
NanoMQ and Neuron.

Options:
  --host <ip>             RK3506 IP. If omitted, prompt interactively
  --user <name>           SSH user. Default: root
  --password <password>   SSH password. Default: root
  --bundle-file <path>    Local release tar.gz
  --bundle-url <url>      Download release tar.gz before deploy
  --work-dir <path>       Temporary extract dir. Default: /tmp/neuron-rk3506-release-install
  --neuron-dir <path>     Target Neuron dir. Default: /opt/neuron
  --nanomq-bin <path>     Target NanoMQ binary. Default: /usr/local/bin/nanomq
  --nanomq-conf <path>    Target NanoMQ conf. Default: /etc/nanomq/nanomq.conf
  --skip-start            Deploy only, do not restart services
  -h, --help              Show this help

Examples:
  scripts/deploy_rk3506_release_bundle.sh \
    --host 192.168.9.10 \
    --bundle-file dist/industrial-iot-rk3506-v1.0.0.tar.gz

  bash deploy_rk3506_release_bundle.sh \
    --host 192.168.9.10 \
    --bundle-url https://github.com/<user>/<repo>/releases/download/v1.0.0/industrial-iot-rk3506-v1.0.0.tar.gz
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
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
bundle_file=""
bundle_url=""
work_dir="/tmp/neuron-rk3506-release-install"
neuron_dir="/opt/neuron"
nanomq_bin="/usr/local/bin/nanomq"
nanomq_conf="/etc/nanomq/nanomq.conf"
skip_start=0

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
    --bundle-file)
      [[ $# -ge 2 ]] || die "missing value for --bundle-file"
      bundle_file="$2"
      shift 2
      ;;
    --bundle-url)
      [[ $# -ge 2 ]] || die "missing value for --bundle-url"
      bundle_url="$2"
      shift 2
      ;;
    --work-dir)
      [[ $# -ge 2 ]] || die "missing value for --work-dir"
      work_dir="$2"
      shift 2
      ;;
    --neuron-dir)
      [[ $# -ge 2 ]] || die "missing value for --neuron-dir"
      neuron_dir="$2"
      shift 2
      ;;
    --nanomq-bin)
      [[ $# -ge 2 ]] || die "missing value for --nanomq-bin"
      nanomq_bin="$2"
      shift 2
      ;;
    --nanomq-conf)
      [[ $# -ge 2 ]] || die "missing value for --nanomq-conf"
      nanomq_conf="$2"
      shift 2
      ;;
    --skip-start)
      skip_start=1
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

require_cmd sshpass
require_cmd scp
require_cmd ssh
require_cmd tar

if [[ -z "$host" ]]; then
  read -r -p "RK3506 IP: " host
fi
[[ -n "$host" ]] || die "RK3506 IP is required"

if [[ -n "$bundle_url" ]]; then
  require_cmd curl
  mkdir -p "$work_dir"
  bundle_file="$work_dir/$(basename "$bundle_url")"
  echo "==> Downloading $bundle_url"
  curl -fL "$bundle_url" -o "$bundle_file"
fi

[[ -n "$bundle_file" ]] || die "provide --bundle-file or --bundle-url"
[[ -f "$bundle_file" ]] || die "bundle file not found: $bundle_file"

echo "==> Extracting bundle"
rm -rf "$work_dir/extract"
mkdir -p "$work_dir/extract"
tar -xzf "$bundle_file" -C "$work_dir/extract"

bundle_neuron_dir="$work_dir/extract/neuron"
[[ -f "$bundle_neuron_dir/neuron" ]] || die "invalid bundle: missing neuron executable"
[[ -d "$bundle_neuron_dir/plugins" ]] || die "invalid bundle: missing plugins"
[[ -d "$bundle_neuron_dir/lib" ]] || die "invalid bundle: missing lib"

bundle_nanomq_bin="$work_dir/extract/nanomq/bin/nanomq"
bundle_nanomq_etc="$work_dir/extract/nanomq/etc"
[[ -f "$bundle_nanomq_bin" ]] || die "invalid bundle: missing nanomq binary"
[[ -d "$bundle_nanomq_etc" ]] || die "invalid bundle: missing nanomq config directory"

echo "==> Stopping target services"
remote_run "
if [ -x '$nanomq_bin' ]; then
  '$nanomq_bin' stop >/tmp/nanomq-stop.log 2>&1 || true
fi
pkill neuron >/dev/null 2>&1 || true
sleep 1
"

echo "==> Deploying Neuron bundle to $(ssh_target):$neuron_dir"
remote_run "mkdir -p '$neuron_dir'"
remote_copy -r "$bundle_neuron_dir"/. "$(ssh_target):$neuron_dir/"

echo "==> Deploying NanoMQ to $(ssh_target):$nanomq_bin"
remote_run "mkdir -p '$(dirname "$nanomq_bin")' '$(dirname "$nanomq_conf")'"
remote_copy "$bundle_nanomq_bin" "$(ssh_target):$nanomq_bin"
remote_copy -r "$bundle_nanomq_etc"/. "$(ssh_target):$(dirname "$nanomq_conf")/"
remote_run "chmod +x '$nanomq_bin'"

if [[ "$skip_start" -eq 1 ]]; then
  echo "==> Deploy complete. Service start skipped."
  exit 0
fi

echo "==> Starting NanoMQ and Neuron"
remote_run "
set -e
if [ -x '$nanomq_bin' ] && [ -f '$nanomq_conf' ]; then
  nohup '$nanomq_bin' start --conf '$nanomq_conf' --log_level info --log_stdout false >/tmp/nanomq-stdout.log 2>&1 &
else
  echo 'warning: NanoMQ binary or config not found; skip NanoMQ start' >&2
fi
cd '$neuron_dir'
LD_LIBRARY_PATH='$neuron_dir/lib' ./neuron --config_dir '$neuron_dir/config' --plugin_dir '$neuron_dir/plugins' -d
sleep 2
ps | grep -E 'neuron|nanomq' | grep -v grep || true
netstat -lntp 2>/dev/null | grep -E ':(7000|1883)' || true
"

echo "==> Done"
echo "Check messages with:"
echo "  mosquitto_sub -h $host -p 1883 -t 'neuron/#' -v"
