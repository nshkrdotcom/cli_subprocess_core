#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_SOURCE="$REPO_DIR/test/fixtures/prepared_release_graph"
WORKSPACE_ROOT=""

PACKAGES=(
  ground_plane_contracts
  ground_plane_persistence_policy
  execution_plane
  cli_subprocess_core
  codex_sdk
  claude_agent_sdk
  amp_sdk
  cursor_cli_sdk
  antigravity_cli_sdk
  agent_session_manager
  prompt_runner_sdk
  inference
)

VERSIONS=(
  0.1.0
  0.1.0
  0.1.0
  0.2.0
  0.17.0
  0.18.0
  0.6.0
  0.1.0
  0.1.0
  0.10.0
  0.7.0
  0.1.0
)

usage() {
  printf '%s\n' \
    "Usage: $0 --workspace-root /absolute/path" \
    "" \
    "Build and test the prepared release graph in source and isolated-package modes."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root)
      [[ $# -ge 2 ]] || { printf 'missing value for --workspace-root\n' >&2; exit 2; }
      WORKSPACE_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$WORKSPACE_ROOT" ]] || { usage >&2; exit 2; }
[[ "$WORKSPACE_ROOT" = /* ]] || { printf 'workspace root must be absolute\n' >&2; exit 2; }
[[ -d "$WORKSPACE_ROOT" ]] || { printf 'workspace root does not exist: %s\n' "$WORKSPACE_ROOT" >&2; exit 2; }
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd -P)"

PROJECT_PATHS=(
  "$WORKSPACE_ROOT/ground_plane/core/ground_plane_contracts"
  "$WORKSPACE_ROOT/ground_plane/core/persistence_policy"
  "$WORKSPACE_ROOT/execution_plane/dist/monolith/execution_plane"
  "$WORKSPACE_ROOT/cli_subprocess_core"
  "$WORKSPACE_ROOT/codex_sdk"
  "$WORKSPACE_ROOT/claude_agent_sdk"
  "$WORKSPACE_ROOT/amp_sdk"
  "$WORKSPACE_ROOT/cursor_cli_sdk"
  "$WORKSPACE_ROOT/antigravity_cli_sdk"
  "$WORKSPACE_ROOT/agent_session_manager"
  "$WORKSPACE_ROOT/prompt_runner_sdk"
  "$WORKSPACE_ROOT/inference/apps/inference"
)

SOURCE_PATHS=(
  "$WORKSPACE_ROOT/ground_plane/core/ground_plane_contracts"
  "$WORKSPACE_ROOT/ground_plane/core/persistence_policy"
  "$WORKSPACE_ROOT/execution_plane/dist/monolith/execution_plane"
  "$WORKSPACE_ROOT/cli_subprocess_core"
  "$WORKSPACE_ROOT/codex_sdk"
  "$WORKSPACE_ROOT/claude_agent_sdk"
  "$WORKSPACE_ROOT/amp_sdk"
  "$WORKSPACE_ROOT/cursor_cli_sdk"
  "$WORKSPACE_ROOT/antigravity_cli_sdk"
  "$WORKSPACE_ROOT/agent_session_manager"
  "$WORKSPACE_ROOT/prompt_runner_sdk"
  "$WORKSPACE_ROOT/inference/apps/inference"
)

SOURCE_REPOS=(
  "$WORKSPACE_ROOT/ground_plane"
  "$WORKSPACE_ROOT/ground_plane"
  "$WORKSPACE_ROOT/execution_plane"
  "$WORKSPACE_ROOT/cli_subprocess_core"
  "$WORKSPACE_ROOT/codex_sdk"
  "$WORKSPACE_ROOT/claude_agent_sdk"
  "$WORKSPACE_ROOT/amp_sdk"
  "$WORKSPACE_ROOT/cursor_cli_sdk"
  "$WORKSPACE_ROOT/antigravity_cli_sdk"
  "$WORKSPACE_ROOT/agent_session_manager"
  "$WORKSPACE_ROOT/prompt_runner_sdk"
  "$WORKSPACE_ROOT/inference"
)

for path in "${PROJECT_PATHS[@]}" "${SOURCE_PATHS[@]}"; do
  [[ -f "$path/mix.exs" ]] || { printf 'missing package project: %s\n' "$path" >&2; exit 1; }
done

WORK_DIR="$(mktemp -d /tmp/prepared-release-graph.XXXXXX)"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

on_exit() {
  local status="$1"

  if [[ "$status" -ne 0 ]]; then
    local receipt
    receipt="/tmp/prepared_release_graph_failure_$(date +%Y%m%d_%H%M%S)_$$"
    mkdir -p "$receipt"
    cp -R "$LOG_DIR/." "$receipt/" 2>/dev/null || true
    printf 'result=failed\nworkspace_root=%s\n' "$WORKSPACE_ROOT" >"$receipt/receipt.txt"
    printf 'prepared-release-graph: failed; logs retained at %s\n' "$receipt" >&2
  fi

  rm -rf "$WORK_DIR"
}
trap 'on_exit $?' EXIT

declare -A STATUS_BEFORE

snapshot_source_statuses() {
  local repo

  for repo in "${SOURCE_REPOS[@]}"; do
    [[ -n "${STATUS_BEFORE[$repo]+x}" ]] && continue
    STATUS_BEFORE[$repo]="$(git -C "$repo" status --porcelain=v1 --untracked-files=all)"
  done
}

assert_source_statuses_unchanged() {
  local repo current

  for repo in "${!STATUS_BEFORE[@]}"; do
    current="$(git -C "$repo" status --porcelain=v1 --untracked-files=all)"

    if [[ "$current" != "${STATUS_BEFORE[$repo]}" ]]; then
      printf 'source worktree changed during fixture run: %s\n' "$repo" >&2
      diff -u <(printf '%s\n' "${STATUS_BEFORE[$repo]}") <(printf '%s\n' "$current") || true
      return 1
    fi
  done
}

write_fixture_config() {
  local destination="$1"
  local mode="$2"
  shift 2

  elixir -e '
    [destination, mode_string, workspace_root | paths] = System.argv()
    apps = ~w(
      ground_plane_contracts
      ground_plane_persistence_policy
      execution_plane
      cli_subprocess_core
      codex_sdk
      claude_agent_sdk
      amp_sdk
      cursor_cli_sdk
      antigravity_cli_sdk
      agent_session_manager
      prompt_runner_sdk
      inference
    )a
    mode = if mode_string == "package", do: :package, else: :source
    config = %{
      mode: mode,
      canonical_workspace_root: workspace_root,
      paths: Map.new(Enum.zip(apps, paths))
    }
    File.write!(destination, inspect(config, pretty: true, limit: :infinity) <> "\n")
  ' "$destination" "$mode" "$WORKSPACE_ROOT" "$@"
}

run_fixture() {
  local mode="$1"
  shift
  local fixture_dir="$WORK_DIR/fixture-$mode"
  local log_file="$LOG_DIR/$mode.log"

  mkdir -p "$fixture_dir"
  cp -R "$FIXTURE_SOURCE/." "$fixture_dir/"
  mv "$fixture_dir/mix.exs.template" "$fixture_dir/mix.exs"
  mv \
    "$fixture_dir/lib/prepared_release_graph.ex.template" \
    "$fixture_dir/lib/prepared_release_graph.ex"
  mv \
    "$fixture_dir/test/prepared_release_graph_test.exs.template" \
    "$fixture_dir/test/prepared_release_graph_test.exs"
  write_fixture_config "$fixture_dir/workspace_paths.exs" "$mode" "$@"

  printf 'prepared-release-graph: mode=%s\n' "$mode"

  (
    cd "$fixture_dir"
    mix deps.get
    env MIX_ENV=test mix deps.tree
    env MIX_ENV=test mix compile --warnings-as-errors
    env MIX_ENV=test mix run --no-start -e '
      receipt = PreparedReleaseGraph.dependency_receipt()
      ownership = PreparedReleaseGraph.module_ownership()
      apps = PreparedReleaseGraph.first_party_application_files()
      IO.puts("resolved first-party paths:")
      Enum.each(Enum.sort(receipt.first_party_paths), &IO.puts("  #{&1}"))
      IO.puts("effective git dependencies: #{inspect(receipt.git_dependencies)}")
      IO.puts("ExecutionPlane module owners: #{map_size(ownership.execution_plane)} unique")
      IO.puts("GroundPlane module owners: #{map_size(ownership.ground_plane)} unique")
      IO.puts("first-party OTP applications: #{inspect(apps)}")
    '
    printf 'mix.lock sha256=%s\n' "$(sha256sum mix.lock | awk '{print $1}')"
    env MIX_ENV=test mix test
  ) 2>&1 | tee "$log_file"

  [[ ! -e "$FIXTURE_SOURCE/workspace_paths.exs" ]] || {
    printf 'generated fixture config leaked into the repository\n' >&2
    return 1
  }
}

build_package_sources() {
  local tarball_dir="$WORK_DIR/tarballs"
  local package_source_root="$WORK_DIR/package-sources"
  local index package version project tarball metadata_dir source_dir digest
  PACKAGE_PATHS=()
  mkdir -p "$tarball_dir" "$package_source_root"

  for index in "${!PACKAGES[@]}"; do
    package="${PACKAGES[$index]}"
    version="${VERSIONS[$index]}"
    project="${PROJECT_PATHS[$index]}"
    tarball="$tarball_dir/$package-$version.tar"
    metadata_dir="$package_source_root/$package/metadata"
    source_dir="$package_source_root/$package/source"
    mkdir -p "$metadata_dir" "$source_dir"

    (cd "$project" && mix hex.build --output "$tarball") >"$LOG_DIR/hex-build-$package.log" 2>&1
    tar -xf "$tarball" -C "$metadata_dir"
    tar -xzf "$metadata_dir/contents.tar.gz" -C "$source_dir"
    digest="$(sha256sum "$tarball" | awk '{print $1}')"
    printf 'tarball %s %s sha256=%s\n' "$package" "$version" "$digest"
    PACKAGE_PATHS+=("$source_dir")
  done
}

print_source_receipt() {
  local index package version repo commit

  printf 'prepared-release-graph: source receipt\n'
  for index in "${!PACKAGES[@]}"; do
    package="${PACKAGES[$index]}"
    version="${VERSIONS[$index]}"
    repo="${SOURCE_REPOS[$index]}"
    commit="$(git -C "$repo" rev-parse HEAD)"
    printf 'package %s %s commit=%s\n' "$package" "$version" "$commit"
  done

  printf 'execution projection commit=%s\n' \
    "$(git -C "$WORKSPACE_ROOT/execution_plane" ls-remote origin refs/heads/projection/execution_plane | awk '{print $1}')"
  printf 'execution projection lock sha256=%s\n' \
    "$(sha256sum "$WORKSPACE_ROOT/execution_plane/dist/monolith/execution_plane/projection.lock.json" | awk '{print $1}')"
}

snapshot_source_statuses
print_source_receipt
run_fixture source "${SOURCE_PATHS[@]}"
build_package_sources
run_fixture package "${PACKAGE_PATHS[@]}"
assert_source_statuses_unchanged

printf 'prepared-release-graph: source and isolated-package modes passed\n'
