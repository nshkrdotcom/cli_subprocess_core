#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/home/home/p/g/n"
DEFAULT_TASK="ci"
TASK=""
REPO_FILTER=()
TAG_FILTER=()

ALL_REPOS=(
  "cli_subprocess_core"
  "agent_session_manager"
  "codex_sdk"
  "gemini_cli_sdk"
  "claude_agent_sdk"
  "amp_sdk"
)

ALL_TASKS=(
  format
  compile
  test
  credo
  dialyzer
)

usage() {
  cat <<'USAGE'
Usage: model_selection_ci.sh [TASK] [--repo <repo>[,<repo>...]] [--tag <tag>[,<tag>...]]

TASK:
  format     -> mix format --check-formatted
  compile    -> mix compile
  test       -> mix test
  credo      -> MIX_ENV=test mix credo --strict
  dialyzer   -> MIX_ENV=dev mix dialyzer
  all        -> run all five checks in order
  ci         -> same as all (default when omitted)

Optional selectors:
  --repo    one or more repo names or absolute paths, comma-separated
  --tag     one or more tags, comma-separated

Aliases:
  core -> cli_subprocess_core
  asm -> agent_session_manager
  codex -> codex_sdk
  gemini -> gemini_cli_sdk
  claude -> claude_agent_sdk
  amp -> amp_sdk
  sdk -> codex_sdk,gemini_cli_sdk,claude_agent_sdk,amp_sdk

Examples:
  ./model_selection_ci.sh ci
  ./model_selection_ci.sh all --repo cli_subprocess_core
  ./model_selection_ci.sh compile --repo codex_sdk,amp_sdk
  ./model_selection_ci.sh test --tag sdk
USAGE
}

normalize_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --repo)
        if [[ $# -lt 2 ]]; then
          echo "[ERROR] --repo requires a comma-separated list" >&2
          exit 2
        fi
        IFS=',' read -r -a REPO_FILTER <<< "$2"
        shift 2
        ;;
      --tag)
        if [[ $# -lt 2 ]]; then
          echo "[ERROR] --tag requires a comma-separated list" >&2
          exit 2
        fi
        IFS=',' read -r -a TAG_FILTER <<< "$2"
        shift 2
        ;;
      format|compile|test|credo|dialyzer|all|ci)
        if [[ -n "$TASK" ]]; then
          echo "[ERROR] task must be specified once" >&2
          exit 2
        fi
        TASK="$1"
        shift
        ;;
      *)
        echo "[ERROR] unknown argument: $1" >&2
        usage
        exit 2
        ;;
    esac
  done
}

resolve_repo() {
  local repo_input="$1"
  case "$repo_input" in
    core|cli_subprocess_core) echo "cli_subprocess_core" ;;
    asm|agent_session_manager|agent|manager) echo "agent_session_manager" ;;
    codex|codex_sdk) echo "codex_sdk" ;;
    gemini|gemini_cli_sdk) echo "gemini_cli_sdk" ;;
    claude|claude_agent_sdk) echo "claude_agent_sdk" ;;
    amp|amp_sdk) echo "amp_sdk" ;;
    *)
      if [[ "$repo_input" == "$ROOT_DIR"/* ]]; then
        local base="${repo_input##*/}"
        resolve_repo "$base"
      else
        echo ""
      fi
      ;;
  esac
}

repos_for_tag() {
  case "$1" in
    core) echo "cli_subprocess_core" ;;
    asm|agent|manager) echo "agent_session_manager" ;;
    codex) echo "codex_sdk" ;;
    gemini) echo "gemini_cli_sdk" ;;
    claude) echo "claude_agent_sdk" ;;
    amp) echo "amp_sdk" ;;
    sdk) echo "codex_sdk"; echo "gemini_cli_sdk"; echo "claude_agent_sdk"; echo "amp_sdk" ;;
    all) printf '%s\n' "${ALL_REPOS[@]}" ;;
    *)
      echo ""
      ;;
  esac
}

collect_selected_repos() {
  local -a selected=()

  if (( ${#REPO_FILTER[@]} > 0 )); then
    for repo in "${REPO_FILTER[@]}"; do
      local resolved
      resolved="$(resolve_repo "$repo")"
      if [[ -z "$resolved" ]]; then
        echo "[ERROR] unknown repo selector: $repo" >&2
        exit 2
      fi
      selected+=("$resolved")
    done
  fi

  if (( ${#TAG_FILTER[@]} > 0 )); then
    for tag in "${TAG_FILTER[@]}"; do
      local repo
      while IFS= read -r repo; do
        [[ -n "$repo" ]] && selected+=("$repo")
      done < <(repos_for_tag "$tag")
    done
  fi

  if (( ${#selected[@]} == 0 )); then
    selected=("${ALL_REPOS[@]}")
  fi

  # unique and preserve order
  local -a unique_selected=()
  local seen=" "
  for repo in "${selected[@]}"; do
    if [[ -z "${seen#* $repo }" ]]; then
      continue
    fi
    unique_selected+=("$repo")
    seen+="$repo "
  done

  printf '%s\n' "${unique_selected[@]}"
}

run_task() {
  local repo="$1"
  local task="$2"
  local repo_dir="$ROOT_DIR/$repo"
  local command

  if [[ ! -d "$repo_dir" ]]; then
    echo "[ERROR] repository missing: $repo_dir" >&2
    return 1
  fi

  case "$task" in
    format)
      command="mix format --check-formatted"
      ;;
    compile)
      command="mix compile"
      ;;
    test)
      command="mix test"
      ;;
    credo)
      command="MIX_ENV=test mix credo --strict"
      ;;
    dialyzer)
      command="MIX_ENV=dev mix dialyzer"
      ;;
    *)
      echo "[ERROR] unknown task $task" >&2
      return 1
      ;;
  esac

  local output
  if ! output=$(cd "$repo_dir" && eval "$command" 2>&1); then
    local rc=$?
    echo "$output" >&2
    return $rc
  fi

  return 0
}

run_repo() {
  local repo="$1"
  local task="$2"
  local -a steps

  if [[ "$task" == "all" || "$task" == "ci" ]]; then
    steps=("${ALL_TASKS[@]}")
  else
    steps=("$task")
  fi

  echo "=== repo: $repo ==="

  for step in "${steps[@]}"; do
    printf '  - %-10s ... ' "$step"
    if run_task "$repo" "$step" >/tmp/model_selection_ci_${repo}_${step}.log 2>&1; then
      echo "PASS"
    else
      local rc=$?
      echo "FAIL"
      cat "/tmp/model_selection_ci_${repo}_${step}.log" >&2
      return $rc
    fi
  done

  echo "[PASS] $repo"
  return 0
}

print_summary() {
  local -a passed=("$@")
  local passed_count=${#passed[@]}
  echo
  echo "=== summary ==="
  echo "Passed repos: $passed_count"
}

normalize_args "$@"
TASK="${TASK:-$DEFAULT_TASK}"

if [[ "$TASK" == "" ]]; then
  TASK="$DEFAULT_TASK"
fi

selected=()
mapfile -t selected < <(collect_selected_repos)

FAILED=()
PASSED=()

for repo in "${selected[@]}"; do
  if run_repo "$repo" "$TASK"; then
    PASSED+=("$repo")
  else
    FAILED+=("$repo")
    echo "[ABORT] Stopping on first failure in $repo"
    break
  fi
done

if ((${#FAILED[@]} > 0)); then
  echo "Failed repos: ${FAILED[*]}"
  echo "Passed repos: ${PASSED[*]-<none>}"
  exit 1
fi

echo "Passed repos: ${PASSED[*]-<none>}"

echo "[OK] all selected repos passed"
