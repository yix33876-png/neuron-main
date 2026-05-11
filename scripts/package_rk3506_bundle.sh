#!/usr/bin/env bash

usage() {
  cat <<'EOF'
Usage: package_rk3506_bundle.sh [options]

Options:
  --root-dir <path>       Repo root directory. Default: infer from script path or current directory
  --build-dir <path>      Build output directory. Default: <repo>/build-armhf
  --output-dir <path>     Bundle output directory. Default: /tmp/neuron-rk3506
  --staging-dir <path>    Cross-compiled dependency prefix. Default: $STAGING or ~/neuron-staging/arm-linux-gnueabihf
  --dashboard-dir <path>  Dashboard dist directory. Default: /tmp/neuron-dashboard/dist
  --skip-dashboard        Do not copy dashboard dist even if it exists
  -h, --help              Show this help
EOF
}

die() {
  echo "error: $*" >&2
  return 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "missing file: $path"
}

require_dir() {
  local path="$1"
  [[ -d "$path" ]] || die "missing directory: $path"
}

copy_matches() {
  local pattern="$1"
  local dest="$2"
  local matches=()
  mapfile -t matches < <(compgen -G "$pattern" || true)
  (( ${#matches[@]} > 0 )) || die "no files matched: $pattern"
  cp -a "${matches[@]}" "$dest/"
}

is_repo_root() {
  local path="$1"
  [[ -f "$path/CMakeLists.txt" && -d "$path/scripts" && -d "$path/persistence" ]]
}

find_repo_root() {
  local probe=""

  if [[ -n "${ROOT_DIR:-}" ]]; then
    if is_repo_root "$ROOT_DIR"; then
      printf '%s\n' "$ROOT_DIR"
      return 0
    fi
    die "ROOT_DIR is not a neuron repo root: $ROOT_DIR"
    return 1
  fi

  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    probe="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if is_repo_root "$probe"; then
      printf '%s\n' "$probe"
      return 0
    fi
  fi

  probe="$PWD"
  while true; do
    if is_repo_root "$probe"; then
      printf '%s\n' "$probe"
      return 0
    fi
    [[ "$probe" == "/" ]] && break
    probe="$(dirname "$probe")"
  done

  die "cannot infer repo root; run from the neuron repo or pass --root-dir <path>"
}

main() {
  set -euo pipefail

  local root_dir=""
  local build_dir=""
  local output_dir="/tmp/neuron-rk3506"
  local staging_dir="${STAGING:-$HOME/neuron-staging/arm-linux-gnueabihf}"
  local dashboard_dir="/tmp/neuron-dashboard/dist"
  local skip_dashboard=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root-dir)
        [[ $# -ge 2 ]] || die "missing value for --root-dir"
        root_dir="$2"
        shift 2
        ;;
      --build-dir)
        [[ $# -ge 2 ]] || die "missing value for --build-dir"
        build_dir="$2"
        shift 2
        ;;
      --output-dir)
        [[ $# -ge 2 ]] || die "missing value for --output-dir"
        output_dir="$2"
        shift 2
        ;;
      --staging-dir)
        [[ $# -ge 2 ]] || die "missing value for --staging-dir"
        staging_dir="$2"
        shift 2
        ;;
      --dashboard-dir)
        [[ $# -ge 2 ]] || die "missing value for --dashboard-dir"
        dashboard_dir="$2"
        shift 2
        ;;
      --skip-dashboard)
        skip_dashboard=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  if [[ -n "$root_dir" ]]; then
    ROOT_DIR="$root_dir"
  fi
  root_dir="$(find_repo_root)"

  if [[ -z "$build_dir" ]]; then
    build_dir="${root_dir}/build-armhf"
  fi

  require_dir "$build_dir"
  require_dir "$root_dir/persistence"
  require_dir "$staging_dir/lib"

  require_file "$build_dir/neuron"
  require_file "$build_dir/libneuron-base.so"
  require_file "$root_dir/default_plugins.json"
  require_file "$root_dir/dev.conf"
  require_file "$root_dir/zlog.conf"
  require_file "$root_dir/sdk-zlog.conf"
  require_file "$root_dir/neuron.json"

  echo "Preparing RK3506 bundle at $output_dir"
  rm -rf "$output_dir"
  mkdir -p \
    "$output_dir/lib" \
    "$output_dir/plugins/schema" \
    "$output_dir/config" \
    "$output_dir/persistence" \
    "$output_dir/logs" \
    "$output_dir/certs"

  cp -a "$build_dir/neuron" "$output_dir/"
  cp -a "$build_dir/libneuron-base.so" "$output_dir/lib/"
  copy_matches "$build_dir/plugins/*.so" "$output_dir/plugins"
  copy_matches "$build_dir/plugins/schema/*.json" "$output_dir/plugins/schema"

  cp -a "$root_dir/default_plugins.json" "$output_dir/config/"
  cp -a "$root_dir/dev.conf" "$output_dir/config/"
  cp -a "$root_dir/zlog.conf" "$output_dir/config/"
  cp -a "$root_dir/sdk-zlog.conf" "$output_dir/config/"
  cp -a "$root_dir/neuron.json" "$output_dir/config/"

  copy_matches "$root_dir/persistence/*.sql" "$output_dir/persistence"
  copy_matches "$root_dir/persistence/*.sql" "$output_dir/config"

  printf '{"plugins":[]}\n' > "$output_dir/persistence/plugins.json"

  copy_matches "$staging_dir/lib/*.so*" "$output_dir/lib"

  if [[ $skip_dashboard -eq 0 ]]; then
    if [[ -d "$dashboard_dir" ]]; then
      cp -a "$dashboard_dir" "$output_dir/dist"
    else
      echo "warning: dashboard dist not found at $dashboard_dir, skipping /web assets" >&2
    fi
  fi

  echo
  echo "Bundle ready:"
  echo "  Output:     $output_dir"
  echo "  Repo root:  $root_dir"
  echo "  Build dir:  $build_dir"
  echo "  Staging:    $staging_dir"
  echo "  Executable: $output_dir/neuron"
  echo "  Libs:       $output_dir/lib"
  echo "  Plugins:    $output_dir/plugins"
  echo "  Config:     $output_dir/config"
  echo "  SQL:        $output_dir/persistence"
  if [[ -d "$output_dir/dist" ]]; then
    echo "  Dashboard:  $output_dir/dist"
  fi
  echo
  echo "Next step:"
  echo "  sshpass -p root scp -o StrictHostKeyChecking=no -r $output_dir/* root@<rk3506-ip>:/opt/neuron/"
}

run_main() {
  ( main "$@" )
}

run_main "$@"
status=$?

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  exit "$status"
fi

return "$status" 2>/dev/null || true
