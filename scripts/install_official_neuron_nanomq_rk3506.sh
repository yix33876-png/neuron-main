#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: install_official_neuron_nanomq_rk3506.sh [options]

Install official Neuron and NanoMQ packages into isolated directories on RK3506.
It does not overwrite /opt/neuron or /usr/local/bin/nanomq, and does not start
anything unless --start is provided.

Default install paths:
  Neuron: /opt/neuron-official
  NanoMQ: /opt/nanomq-official

Options:
  --neuron-version <ver>   Default: 2.6.0
  --nanomq-version <ver>   Default: 0.24.13
  --neuron-url <url>       Override official Neuron tar.gz URL
  --nanomq-url <url>       Override official NanoMQ deb URL
  --neuron-dir <path>      Default: /opt/neuron-official
  --nanomq-dir <path>      Default: /opt/nanomq-official
  --start <mode>           none|neuron|nanomq|all. Default: none
  --force                  Replace existing official install directories
  -h, --help               Show this help

Examples:
  sh install_official_neuron_nanomq_rk3506.sh

  sh install_official_neuron_nanomq_rk3506.sh --start nanomq

  sh install_official_neuron_nanomq_rk3506.sh \
    --neuron-url https://www.emqx.com/en/downloads/neuron/2.6.0/neuron-2.6.0-linux-armhf.tar.gz
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

download() {
  url="$1"
  out="$2"

  if have_cmd curl; then
    curl -fL "$url" -o "$out"
  elif have_cmd wget; then
    wget -O "$out" "$url"
  else
    die "need curl or wget"
  fi
}

check_armhf() {
  case "$(uname -m)" in
    armv7l|armv7*|arm*)
      ;;
    *)
      die "unsupported architecture: $(uname -m). This script defaults to ARMHF packages"
      ;;
  esac
}

port_in_use() {
  port="$1"
  if have_cmd netstat; then
    netstat -lnt 2>/dev/null | grep -q "[.:]$port "
  elif have_cmd ss; then
    ss -lnt 2>/dev/null | grep -q "[.:]$port "
  else
    return 1
  fi
}

extract_deb_data() {
  deb="$1"
  out="$2"
  work="$3"

  if have_cmd dpkg-deb; then
    dpkg-deb -x "$deb" "$out"
    return
  fi

  have_cmd ar || die "need dpkg-deb or ar to extract NanoMQ deb package"
  mkdir -p "$work/deb"
  (
    cd "$work/deb"
    ar x "$deb"
    data_tar="$(ls data.tar.* 2>/dev/null | head -n 1 || true)"
    [ -n "$data_tar" ] || die "invalid deb: missing data.tar.*"
    tar -xf "$data_tar" -C "$out"
  )
}

write_neuron_scripts() {
  dir="$1"

  cat > "$dir/start-neuron.sh" <<EOF
#!/bin/sh
set -eu
DIR="$dir"
cd "\$DIR"
if netstat -lnt 2>/dev/null | grep -q '[.:]7000 '; then
  echo "error: port 7000 is already in use; stop the other Neuron first" >&2
  exit 1
fi
LD_LIBRARY_PATH="\$DIR:\${LD_LIBRARY_PATH:-}" nohup "\$DIR/neuron" \\
  --config_dir "\$DIR/config" \\
  --plugin_dir "\$DIR/plugins" \\
  -d >/tmp/neuron-official-stdout.log 2>&1
sleep 2
ps | grep '[n]euron' || true
netstat -lntp 2>/dev/null | grep ':7000' || true
EOF

  cat > "$dir/stop-neuron.sh" <<EOF
#!/bin/sh
set -eu
DIR="$dir"
pids=\$(ps | awk -v dir="\$DIR" '\$0 ~ dir "/neuron" || \$0 ~ "[.]\\/neuron" {print \$1}' || true)
if [ -n "\$pids" ]; then
  kill \$pids >/dev/null 2>&1 || true
  sleep 1
  kill -9 \$pids >/dev/null 2>&1 || true
fi
EOF

  chmod +x "$dir/start-neuron.sh" "$dir/stop-neuron.sh"
}

write_nanomq_scripts() {
  dir="$1"

  cat > "$dir/start-nanomq.sh" <<EOF
#!/bin/sh
set -eu
DIR="$dir"
if netstat -lnt 2>/dev/null | grep -q '[.:]1883 '; then
  echo "error: port 1883 is already in use; stop the other NanoMQ first" >&2
  exit 1
fi
nohup "\$DIR/bin/nanomq" start \\
  --conf "\$DIR/etc/nanomq.conf" \\
  --log_level info \\
  --log_stdout false >/tmp/nanomq-official-stdout.log 2>&1 &
sleep 2
ps | grep '[n]anomq' || true
netstat -lntp 2>/dev/null | grep ':1883' || true
EOF

  cat > "$dir/stop-nanomq.sh" <<EOF
#!/bin/sh
set -eu
DIR="$dir"
if [ -x "\$DIR/bin/nanomq" ]; then
  "\$DIR/bin/nanomq" stop >/tmp/nanomq-official-stop.log 2>&1 || true
fi
pids=\$(ps | awk -v dir="\$DIR" '\$0 ~ dir "/bin/nanomq" {print \$1}' || true)
if [ -n "\$pids" ]; then
  kill \$pids >/dev/null 2>&1 || true
  sleep 1
  kill -9 \$pids >/dev/null 2>&1 || true
fi
EOF

  chmod +x "$dir/start-nanomq.sh" "$dir/stop-nanomq.sh"
}

neuron_version="2.6.0"
nanomq_version="0.24.13"
neuron_url=""
nanomq_url=""
neuron_dir="/opt/neuron-official"
nanomq_dir="/opt/nanomq-official"
start_mode="none"
force=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --neuron-version)
      [ "$#" -ge 2 ] || die "missing value for --neuron-version"
      neuron_version="$2"
      shift 2
      ;;
    --nanomq-version)
      [ "$#" -ge 2 ] || die "missing value for --nanomq-version"
      nanomq_version="$2"
      shift 2
      ;;
    --neuron-url)
      [ "$#" -ge 2 ] || die "missing value for --neuron-url"
      neuron_url="$2"
      shift 2
      ;;
    --nanomq-url)
      [ "$#" -ge 2 ] || die "missing value for --nanomq-url"
      nanomq_url="$2"
      shift 2
      ;;
    --neuron-dir)
      [ "$#" -ge 2 ] || die "missing value for --neuron-dir"
      neuron_dir="$2"
      shift 2
      ;;
    --nanomq-dir)
      [ "$#" -ge 2 ] || die "missing value for --nanomq-dir"
      nanomq_dir="$2"
      shift 2
      ;;
    --start)
      [ "$#" -ge 2 ] || die "missing value for --start"
      start_mode="$2"
      shift 2
      ;;
    --force)
      force=1
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

[ "$(id -u)" = "0" ] || die "please run as root"
check_armhf
have_cmd tar || die "need tar"

case "$start_mode" in
  none|neuron|nanomq|all)
    ;;
  *)
    die "--start must be one of: none, neuron, nanomq, all"
    ;;
esac

if [ -z "$neuron_url" ]; then
  neuron_url="https://www.emqx.com/en/downloads/neuron/$neuron_version/neuron-$neuron_version-linux-armhf.tar.gz"
fi

if [ -z "$nanomq_url" ]; then
  nanomq_url="https://www.emqx.com/en/downloads/nanomq/$nanomq_version/nanomq-$nanomq_version-linux-armhf.deb"
fi

tmp_dir="${TMPDIR:-/tmp}/official-neuron-nanomq.$$"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

mkdir -p "$tmp_dir"

echo "==> Official isolated install"
echo "    Neuron dir : $neuron_dir"
echo "    NanoMQ dir : $nanomq_dir"
echo "    Neuron URL : $neuron_url"
echo "    NanoMQ URL : $nanomq_url"

if [ "$force" = "0" ]; then
  [ ! -e "$neuron_dir" ] || die "$neuron_dir already exists; pass --force to replace it"
  [ ! -e "$nanomq_dir" ] || die "$nanomq_dir already exists; pass --force to replace it"
fi

echo "==> Downloading Neuron"
download "$neuron_url" "$tmp_dir/neuron.tar.gz"

echo "==> Downloading NanoMQ"
download "$nanomq_url" "$tmp_dir/nanomq.deb"

echo "==> Extracting Neuron"
mkdir -p "$tmp_dir/neuron-extract"
tar -xzf "$tmp_dir/neuron.tar.gz" -C "$tmp_dir/neuron-extract"
bundle_neuron="$(find "$tmp_dir/neuron-extract" -maxdepth 2 -type f -name neuron | head -n 1 | xargs dirname)"
[ -n "$bundle_neuron" ] && [ -f "$bundle_neuron/neuron" ] || die "invalid Neuron package: missing neuron executable"

echo "==> Extracting NanoMQ deb"
mkdir -p "$tmp_dir/nanomq-extract"
extract_deb_data "$tmp_dir/nanomq.deb" "$tmp_dir/nanomq-extract" "$tmp_dir"
[ -f "$tmp_dir/nanomq-extract/usr/local/bin/nanomq" ] || die "invalid NanoMQ package: missing usr/local/bin/nanomq"
[ -d "$tmp_dir/nanomq-extract/usr/local/etc" ] || die "invalid NanoMQ package: missing usr/local/etc"

echo "==> Installing isolated Neuron"
rm -rf "$neuron_dir"
mkdir -p "$(dirname "$neuron_dir")"
cp -a "$bundle_neuron" "$neuron_dir"
chmod +x "$neuron_dir/neuron"

echo "==> Installing isolated NanoMQ"
rm -rf "$nanomq_dir"
mkdir -p "$nanomq_dir/bin" "$nanomq_dir/etc"
cp -a "$tmp_dir/nanomq-extract/usr/local/bin"/. "$nanomq_dir/bin/"
cp -a "$tmp_dir/nanomq-extract/usr/local/etc"/. "$nanomq_dir/etc/"
chmod +x "$nanomq_dir/bin/nanomq" "$nanomq_dir/bin/nanomq_cli" "$nanomq_dir/bin/nngcat" 2>/dev/null || true

write_neuron_scripts "$neuron_dir"
write_nanomq_scripts "$nanomq_dir"

echo "==> Installed"
echo "    Start Neuron: $neuron_dir/start-neuron.sh"
echo "    Stop Neuron : $neuron_dir/stop-neuron.sh"
echo "    Start NanoMQ: $nanomq_dir/start-nanomq.sh"
echo "    Stop NanoMQ : $nanomq_dir/stop-nanomq.sh"

case "$start_mode" in
  neuron)
    "$neuron_dir/start-neuron.sh"
    ;;
  nanomq)
    "$nanomq_dir/start-nanomq.sh"
    ;;
  all)
    "$nanomq_dir/start-nanomq.sh"
    "$neuron_dir/start-neuron.sh"
    ;;
  none)
    echo "==> Start skipped"
    ;;
esac

