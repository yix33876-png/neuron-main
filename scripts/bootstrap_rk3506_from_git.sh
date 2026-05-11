#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bootstrap_rk3506_from_git.sh --repo-url <url> [options] [-- deploy-options]

Clone or update the project from Git, then run build_deploy_start_rk3506.sh.

Options:
  --repo-url <url>       Git repository URL. Required
  --branch <name>        Git branch/tag. Default: main
  --work-dir <path>      Local checkout directory. Default: ~/neuron-main
  --fresh                Delete work-dir before clone
  -h, --help             Show this help

Everything after "--" is passed to build_deploy_start_rk3506.sh.

Examples:
  bash bootstrap_rk3506_from_git.sh \
    --repo-url https://codeup.aliyun.com/group/project/neuron-main.git \
    --branch main \
    -- \
    --host 192.168.9.10

  bash bootstrap_rk3506_from_git.sh \
    --repo-url git@codeup.aliyun.com:group/project/neuron-main.git \
    -- \
    --host 192.168.9.10 --plugins-only
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

repo_url=""
branch="main"
work_dir="$HOME/neuron-main"
fresh=0
deploy_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)
      [[ $# -ge 2 ]] || die "missing value for --repo-url"
      repo_url="$2"
      shift 2
      ;;
    --branch)
      [[ $# -ge 2 ]] || die "missing value for --branch"
      branch="$2"
      shift 2
      ;;
    --work-dir)
      [[ $# -ge 2 ]] || die "missing value for --work-dir"
      work_dir="$2"
      shift 2
      ;;
    --fresh)
      fresh=1
      shift
      ;;
    --)
      shift
      deploy_args=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option before --: $1"
      ;;
  esac
done

[[ -n "$repo_url" ]] || die "--repo-url is required"

require_cmd git

if [[ "$fresh" -eq 1 && -e "$work_dir" ]]; then
  rm -rf "$work_dir"
fi

if [[ -d "$work_dir/.git" ]]; then
  echo "==> Updating existing checkout: $work_dir"
  git -C "$work_dir" fetch --prune origin
  git -C "$work_dir" checkout "$branch"
  git -C "$work_dir" pull --ff-only origin "$branch"
else
  echo "==> Cloning $repo_url into $work_dir"
  git clone --branch "$branch" "$repo_url" "$work_dir"
fi

echo "==> Running RK3506 deploy script"
exec "$work_dir/scripts/build_deploy_start_rk3506.sh" "${deploy_args[@]}"
