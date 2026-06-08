# Mwoham terminal command tracking for zsh.
# Source this file from ~/.zshrc to record command metadata as DevEvent.

MWOHAM_ZSH_TRACKING_LOADED=1

zmodload zsh/datetime 2>/dev/null || true
autoload -Uz add-zsh-hook 2>/dev/null || true

: "${MWOHAM_BACKEND_DIR:=${${(%):-%N}:A:h:h}}"
: "${MWOHAM_COMMAND_TRACKING_INTERVAL_MIN_MS:=0}"

typeset -g MWOHAM_CMD_TRACKING_COMMAND=""
typeset -g MWOHAM_CMD_TRACKING_CWD=""
typeset -g MWOHAM_CMD_TRACKING_STARTED_AT=""
typeset -g MWOHAM_CMD_TRACKING_STARTED_EPOCH=""

_mwoham_now_epoch() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    print -r -- "$EPOCHREALTIME"
    return 0
  fi
  date +%s
}

_mwoham_iso_now() {
  python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())' 2>/dev/null
}

_mwoham_should_skip_command() {
  local command_text="$1"
  [[ -z "${command_text//[[:space:]]/}" ]] && return 0

  case "$command_text" in
    cd|cd\ *|pwd|pwd\ *|ls|ls\ *|clear|clear\ *|source\ ~/.zshrc|source\ .zshrc) return 0 ;;
    *scripts/record_command_result.py*|*mwoham_zsh_tracking.zsh*) return 0 ;;
    *install_command_tracking_hook.py*|*uninstall_command_tracking_hook.py*) return 0 ;;
  esac

  if [[ "$command_text" == (cat|less|more|tail|head|sed|awk|grep|rg)\ *(.env|.env.*|*/.env|*/.env.*)* ]]; then
    return 0
  fi

  return 1
}

_mwoham_is_multiline_command_block() {
  local command_text="$1"
  local non_empty_count=0
  local line

  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    non_empty_count=$((non_empty_count + 1))
    (( non_empty_count >= 2 )) && return 0
  done <<< "$command_text"

  return 1
}

_mwoham_normalize_command_text() {
  local command_text="$1"
  command_text="${command_text//$'\n'/ }"
  command_text="${command_text//$'\r'/ }"
  print -r -- "$command_text"
}

_mwoham_command_tracking_clear_state() {
  MWOHAM_CMD_TRACKING_COMMAND=""
  MWOHAM_CMD_TRACKING_CWD=""
  MWOHAM_CMD_TRACKING_STARTED_AT=""
  MWOHAM_CMD_TRACKING_STARTED_EPOCH=""
}

_mwoham_is_dev_validation_command() {
  local command_text="$1"
  case "$command_text" in
    uv\ run\ pytest*|uv\ run\ python\ scripts/run_dev_checks.py*|uv\ run\ alembic\ check*|\
ruff*|uv\ run\ ruff*|xcodebuild*|git\ diff\ --check*) return 0 ;;
  esac
  return 1
}

_mwoham_command_tracking_preexec() {
  if _mwoham_is_multiline_command_block "$1"; then
    _mwoham_command_tracking_clear_state
    return 0
  fi

  local command_text="$(_mwoham_normalize_command_text "$1")"
  if _mwoham_should_skip_command "$command_text"; then
    _mwoham_command_tracking_clear_state
    return 0
  fi

  MWOHAM_CMD_TRACKING_COMMAND="$command_text"
  MWOHAM_CMD_TRACKING_CWD="$PWD"
  MWOHAM_CMD_TRACKING_STARTED_EPOCH="$(_mwoham_now_epoch)"
  MWOHAM_CMD_TRACKING_STARTED_AT="$(_mwoham_iso_now)"
}

_mwoham_command_tracking_precmd() {
  local exit_code="$?"
  local command_text="$MWOHAM_CMD_TRACKING_COMMAND"
  local command_cwd="$MWOHAM_CMD_TRACKING_CWD"
  local started_at="$MWOHAM_CMD_TRACKING_STARTED_AT"
  local started_epoch="$MWOHAM_CMD_TRACKING_STARTED_EPOCH"
  _mwoham_command_tracking_clear_state
  [[ -z "$command_text" ]] && return 0

  local ended_at="$(_mwoham_iso_now)"
  local ended_epoch="$(_mwoham_now_epoch)"
  local duration_ms="0"
  if [[ -n "$started_epoch" && -n "$ended_epoch" ]]; then
    duration_ms=$(printf "%.0f" "$(( (ended_epoch - started_epoch) * 1000 ))" 2>/dev/null)
  fi

  if (( duration_ms < MWOHAM_COMMAND_TRACKING_INTERVAL_MIN_MS )) && \
    ! _mwoham_is_dev_validation_command "$command_text"; then
    return 0
  fi

  (
    cd "$MWOHAM_BACKEND_DIR" 2>/dev/null || exit 0
    uv run python scripts/record_command_result.py \
      --command "$command_text" \
      --exit-code "$exit_code" \
      --duration-ms "$duration_ms" \
      --cwd "$command_cwd" \
      --started-at "$started_at" \
      --ended-at "$ended_at" \
      --shell "zsh" \
      --source "terminal" \
      --session-current >/dev/null 2>&1
  ) &!

  return 0
}

mwoham_command_tracking_disable() {
  add-zsh-hook -d preexec _mwoham_command_tracking_preexec 2>/dev/null || true
  add-zsh-hook -d precmd _mwoham_command_tracking_precmd 2>/dev/null || true
  _mwoham_command_tracking_clear_state
  unset MWOHAM_ZSH_TRACKING_LOADED
}

mwoham_command_tracking_status() {
  local record_script="$MWOHAM_BACKEND_DIR/scripts/record_command_result.py"
  local preexec_registered="no"
  local precmd_registered="no"

  if (( ${preexec_functions[(Ie)_mwoham_command_tracking_preexec]} )); then
    preexec_registered="yes"
  fi
  if (( ${precmd_functions[(Ie)_mwoham_command_tracking_precmd]} )); then
    precmd_registered="yes"
  fi

  print -r -- "Mwoham command tracking loaded: ${MWOHAM_ZSH_TRACKING_LOADED:-0}"
  print -r -- "preexec hook registered: $preexec_registered"
  print -r -- "precmd hook registered: $precmd_registered"
  print -r -- "backend path: $MWOHAM_BACKEND_DIR"
  if [[ -f "$record_script" ]]; then
    print -r -- "record script exists: yes"
  else
    print -r -- "record script exists: no ($record_script)"
  fi
}

add-zsh-hook -d preexec _mwoham_command_tracking_preexec 2>/dev/null || true
add-zsh-hook -d precmd _mwoham_command_tracking_precmd 2>/dev/null || true
add-zsh-hook preexec _mwoham_command_tracking_preexec
add-zsh-hook precmd _mwoham_command_tracking_precmd
