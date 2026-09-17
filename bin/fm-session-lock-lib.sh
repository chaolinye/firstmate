#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp)

# Portable process-field reads used by the ancestry walk and liveness check.
# Capability detection must not key on uname: Git Bash/MSYS exposes
# Linux-compatible /proc/<pid>/stat and /proc/<pid>/cmdline while its Cygwin
# ps rejects the -o fields this file's fallback needs (the same contract
# fm_pid_identity in fm-wake-lib.sh documents). Prefer /proc when present,
# fall back to ps -o elsewhere.
#
# fm_harness_proc_comm_args <pid> -> sets FM_HARNESS_PROC_COMM FM_HARNESS_PROC_ARGS
fm_harness_proc_comm_args() {  # <pid>
  local pid=$1 stat_line proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  FM_HARNESS_PROC_COMM=''
  FM_HARNESS_PROC_ARGS=''
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  if [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # stat line: <pid> (<comm>) <state> <ppid> <pgrp> ... - comm is the first
    # parenthesized run; the kernel escapes ')' inside comm as hex so the last
    # ')' in the line still terminates it, matching fm_pid_identity's parsing.
    FM_HARNESS_PROC_COMM=${stat_line#*\(}
    FM_HARNESS_PROC_COMM=${FM_HARNESS_PROC_COMM%%\)*}
    # Join the full NUL-separated cmdline exactly like ps -o args= would.
    FM_HARNESS_PROC_ARGS=$(tr '\0' ' ' < "$proc_root/$pid/cmdline" 2>/dev/null)
    return 0
  fi
  FM_HARNESS_PROC_COMM=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  FM_HARNESS_PROC_ARGS=$(ps -o args= -p "$pid" 2>/dev/null || true)
  return 0
}

# fm_harness_proc_ppid <pid> -> prints the parent pid, or nothing.
fm_harness_proc_ppid() {  # <pid>
  local pid=$1 stat_line proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # Field 4 is the parent pid; strip the comm run first so field numbering
    # starts after the closing paren: <pid> (<comm>) <state> <ppid> <pgrp> ...
    printf '%s\n' "${stat_line#*)}" | awk '{print $2}'
    return 0
  fi
  ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '
  return 0
}

# Git Bash/MSYS fallback session identity: bash children of a native-Windows
# harness (node.exe running pi) are re-parented to pid 1 in the Cygwin process
# model, so no ancestry walk - /proc or ps - can reach the harness. The
# fallback scans /proc for the live interpreter process whose cmdline names the
# harness script path AND whose environ carries THIS session's HERDR pane
# runtime id. HERDR_PANE_RUNTIME_ID is session-unique and is not inherited by
# unrelated processes, so it keys the scan to this exact session even when a
# sibling pi process (e.g. `pi -c` continued session or an in-process branch
# sharing the pane) is also live. This mirrors fm-harness.sh's marker+ancestry
# two-layer design for the platform where ancestry is structurally unavailable.
#
# fm_harness_scan_msys <env-marker> <cmdline-fragment> -> prints one pid, or nothing.
# The marker must match an environ line exactly (grep-style), because the
# environ is NUL-joined into newlines, not spaces. The target must also be an
# interpreter (node/python/bun) whose cmdline names the harness script path,
# so a bash whose command text merely echoes the fragment is never matched.
fm_harness_scan_msys() {  # <env-marker> <cmdline-fragment>
  local marker=$1 fragment=$2 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} pid cmd env comm
  [ -n "$marker" ] && [ -n "$fragment" ] || return 1
  [ -d "$proc_root" ] || return 1
  for stat_file in "$proc_root"/[0-9]*/stat; do
    [ -r "$stat_file" ] || continue
    pid=${stat_file%/stat}
    pid=${pid##*/}
    [ "$pid" != "$$" ] || continue
    env=$(tr '\0' '\n' < "$proc_root/$pid/environ" 2>/dev/null) || continue
    printf '%s\n' "$env" | grep -qx "$marker" || continue
    cmd=$(tr '\0' ' ' < "$proc_root/$pid/cmdline" 2>/dev/null) || continue
    case " $cmd " in
      *"$fragment"*) ;;
      *) continue ;;
    esac
    comm=$(sed -n 's/^[0-9]* (//p' "$stat_file" | sed 's/).*//')
    case "$comm" in
      *node* | *python* | *bun*) printf '%s\n' "$pid"; return 0 ;;
    esac
  done
  return 1
}

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args ppid extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    fm_harness_proc_comm_args "$pid" || break
    comm=$FM_HARNESS_PROC_COMM
    args=$FM_HARNESS_PROC_ARGS
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    ppid=$(fm_harness_proc_ppid "$pid")
    pid=$ppid
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# One pid that identifies this session, with a Git Bash/MSYS fallback: when the
# ancestry walk cannot reach a harness (native-Windows harness re-parents its
# bash children to pid 1), scan /proc for the live harness process carrying
# this session's verified marker, and return that pid as the session identity.
# Only pi has a verified marker; other harnesses stay read-only on this
# platform until their marker is verified and added here.
fm_harness_session_pid() {
  local pid fallback
  pid=$(fm_harness_ancestry_pid 2>/dev/null) && { printf '%s\n' "$pid"; return 0; }
  # pi on Git Bash/MSYS: cmdline names the pi bundle and environ carries this
  # session's HERDR pane runtime id. The pane id is the session-unique cross-
  # process identity available on this platform; AI_AGENT and PI_CODING_AGENT
  # are inherited by every child and cannot key a single session.
  if [ -n "${HERDR_PANE_RUNTIME_ID:-}" ]; then
    fallback=$(fm_harness_scan_msys "HERDR_PANE_RUNTIME_ID=$HERDR_PANE_RUNTIME_ID" 'pi-coding-agent' 2>/dev/null) \
      && { printf '%s\n' "$fallback"; return 0; }
  fi
  return 1
}

# True if $1 is a live process that looks like a verified harness.
# Process-shape matching (comm/args) plus the marker evidence fm-harness.sh
# also trusts: a native-Windows pi runs as node.exe, so comm=node never
# matches the anchored ^pi$ regex, but its environ carries this session's
# HERDR pane runtime id. /proc environ is unavailable on macOS and not readable
# for foreign uids, so the marker check is best-effort and only ADDS evidence
# when readable.
fm_harness_pid_alive() {
  local pid=$1 comm args env proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  kill -0 "$pid" 2>/dev/null || return 1
  if fm_harness_proc_comm_args "$pid"; then
    comm=$FM_HARNESS_PROC_COMM
    args=$FM_HARNESS_PROC_ARGS
    if fm_harness_process_matches "$comm" "$args"; then
      return 0
    fi
  fi
  # Marker fallback: a live pi harness carries this session's HERDR pane id
  # AND runs the pi bundle. The pane id alone is inherited by every child of
  # the session, so it must be combined with the cmdline fragment that only
  # the pi process itself carries.
  if [ -n "${HERDR_PANE_RUNTIME_ID:-}" ] && [ -r "$proc_root/$pid/environ" ]; then
    env=$(tr '\0' '\n' < "$proc_root/$pid/environ" 2>/dev/null) || return 1
    printf '%s\n' "$env" | grep -qx "HERDR_PANE_RUNTIME_ID=$HERDR_PANE_RUNTIME_ID" || return 1
    case " $args " in
      *pi-coding-agent*) return 0 ;;
    esac
  fi
  return 1
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || pids=
  if [ -n "$pids" ]; then
    while IFS= read -r pid; do
      [ "$pid" = "$lock_pid" ] && return 0
    done <<EOF
$pids
EOF
  fi
  # Git Bash/MSYS: bash children of the native-Windows pi harness are
  # re-parented to pid 1, so ancestry membership can never include the lock
  # pid even when the lock IS this session's own pi process. Fall back to
  # identity: the lock names this session's pi process when that pid carries
  # this session's HERDR pane runtime id AND the pi bundle cmdline. The pane
  # id is inherited by every child, so the cmdline fragment - which only the
  # pi process itself carries - prevents a child bash from matching.
  if [ -n "${HERDR_PANE_RUNTIME_ID:-}" ]; then
    if fm_harness_pid_alive "$lock_pid"; then
      local env args
      env=$(tr '\0' '\n' < "${FM_PROC_ROOT_OVERRIDE:-/proc}/$lock_pid/environ" 2>/dev/null) || return 1
      printf '%s\n' "$env" | grep -qx "HERDR_PANE_RUNTIME_ID=$HERDR_PANE_RUNTIME_ID" || return 1
      fm_harness_proc_comm_args "$lock_pid" || return 1
      args=$FM_HARNESS_PROC_ARGS
      case " $args " in
        *pi-coding-agent*) return 0 ;;
      esac
    fi
  fi
  return 1
}
