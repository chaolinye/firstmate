#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake. Two signals decide ownership, either one sufficient: the recorded pid
# is a member of this process's contiguous harness ancestry, or the trusted
# Claude session id below matches the id recorded beside a live lock. Neither
# signal ever fails open: no id, no sidecar, an untrusted id, or a different
# recorded id leaves the ancestry verdict exactly as it was.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
_FM_SESSION_LOCK_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_SESSION_LOCK_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_SESSION_LOCK_LIB_DIR=.
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-cursor-lib.sh"
unset _FM_SESSION_LOCK_LIB_DIR

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp)

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

# Portable single-pid process introspection.
#
# procps/BSD `ps -o comm=/args=/ppid=` custom-format columns are the primary
# path and cover Linux and macOS. Cygwin's ps, which Git for Windows ships, has
# no -o option at all and exits with "unknown option -- o", so the primary path
# fails outright there and the ancestry walk aborts on its first hop. The
# fallbacks parse Cygwin's fixed columns instead:
#   ps -p PID     PID PPID PGID WINPID TTY UID STIME COMMAND   (executable path)
#   ps -f -p PID  UID PID PPID TTY STIME COMMAND               (full argv)
# A genuinely dead or inaccessible pid still fails both paths, so this widens
# nothing: it only stops a supported platform from failing on ps syntax alone.
fm_ps_comm() {  # <pid> -> executable name or path
  local pid=$1 out
  out=$(ps -o comm= -p "$pid" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out=$(ps -p "$pid" 2>/dev/null | awk 'NR == 2 { for (i = 8; i <= NF; i++) printf "%s%s", (i > 8 ? " " : ""), $i; exit }')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

fm_ps_args() {  # <pid> -> full command line
  local pid=$1 out
  out=$(ps -o args= -p "$pid" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out=$(ps -f -p "$pid" 2>/dev/null | awk 'NR == 2 { for (i = 6; i <= NF; i++) printf "%s%s", (i > 6 ? " " : ""), $i; exit }')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

fm_ps_ppid() {  # <pid> -> parent pid
  local pid=$1 out
  out=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out=$(ps -f -p "$pid" 2>/dev/null | awk 'NR == 2 { print $3; exit }')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
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
      # The Pi CLI runs as a bare node interpreter whose harness identity lives
      # only in its script path (@earendil-works/pi-coding-agent). Neither the
      # process name (node) nor a path component matches the exact-name tables
      # above, so this package marker is the one recognition a Pi session's
      # lock identity uses. Narrow to the package path so an unrelated node
      # script that merely mentions pi in its own name cannot claim a Pi
      # identity.
      if printf '%s' "$args" | grep -qE "$FM_PI_MARKER_RE"; then
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

# --- Windows process-boundary bridge -----------------------------------------
#
# On Cygwin (Git for Windows) the harness is a native Windows process, and the
# parent link from a shell it spawns does NOT cross the Cygwin boundary: Cygwin
# reports that shell's PPID as 1. So no amount of walking ppid can ever reach the
# harness, and the contiguous-run model below cannot be satisfied by the Cygwin
# process table alone. The Windows process table does hold the real parent chain,
# and `ps -W` lists Windows processes keyed by WINPID, so identity is recovered
# from there instead.
#
# Windows pids live in a DIFFERENT namespace from Cygwin pids: `kill -0` on a
# Windows pid reports "No such process" even while that process is running, and a
# Windows pid can collide with an unrelated live Cygwin pid. A bare number is
# therefore ambiguous and unsafe to store. Every pid resolved through this bridge
# is tagged, which makes the namespace explicit for readers and makes the value
# non-numeric so that any consumer treating it as a Cygwin pid - including a
# future `kill` - refuses it instead of acting on the wrong process.
FM_WIN_PID_PREFIX='win:'

# True on a Cygwin-family userspace, where the boundary above applies.
fm_win_boundary_applies() {
  case "$(uname -s 2>/dev/null)" in
    CYGWIN*|MINGW*|MSYS*) return 0 ;;
  esac
  return 1
}

# Strip the namespace tag from $1, or return 1 when $1 is not a tagged pid.
# The tag is only meaningful where the boundary applies; anywhere else it is
# rejected exactly like any other non-numeric lock value.
fm_win_untag_pid() {  # <pid>
  local winpid
  case "$1" in
    "$FM_WIN_PID_PREFIX"*) winpid=${1#"$FM_WIN_PID_PREFIX"} ;;
    *) return 1 ;;
  esac
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_win_boundary_applies || return 1
  printf '%s' "$winpid"
}

# True when $1 is a well-formed session-lock identity: a local pid, or a tagged
# Windows pid. Every reader of state/.lock decides "is this value usable at all"
# through this one predicate, because the readers are spread across several
# scripts and a private numeric test in any one of them silently rejects a valid
# holder - which reads as "startup never completed" and repeats the whole
# sequence on every clear or compact.
fm_session_pid_valid() {  # <value>
  fm_win_untag_pid "$1" >/dev/null && return 0
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# Windows command paths are backslash-separated and .exe-suffixed, neither of
# which the path-component matcher above understands. Normalizing here is what
# keeps that matcher's whole-component safety intact: without it the harness
# regex would fall back to matching the entire unsplit path, so an unrelated
# C:\claude-notes\tool.exe would read as a harness process.
fm_win_normalize_command() {  # <windows path>
  local path=${1//\\//}
  printf '%s' "${path%.exe}"
}

# Print the full command line of live Windows process $1, or return 1. The
# executable path alone cannot name a node-bundle harness such as Pi, whose
# identity lives in its script path, so liveness checks that need the full
# command line use this instead of fm_win_command.
# shellcheck disable=SC2317 # Not all consumers exist in every sourced context.
fm_win_command_line() {  # <winpid>
  local winpid=$1 cmd
  case "$winpid" in
    ''|*[!0-9]*) return 2 ;;
  esac
  cmd=$(powershell -NoProfile -NonInteractive -Command \
    "(Get-CimInstance Win32_Process -Filter 'ProcessId=$winpid').CommandLine" 2>/dev/null) || return 2
  cmd=${cmd%$'\r'}
  [ -n "$cmd" ] || return 1
  printf '%s' "$cmd"
}

# Print the normalized executable path of live Windows process $1, or return 1.
# Presence in `ps -W` is also this bridge's liveness test, because kill -0 cannot
# answer that question across the namespace boundary.
fm_win_command() {  # <winpid>
  local winpid=$1 table out
  case "$winpid" in
    ''|*[!0-9]*) return 2 ;;
  esac
  # Return 1 only when a readable table proves the pid absent, and 2 when the
  # table itself could not be read, so a caller can tell gone from unknown.
  table=$(ps -W 2>/dev/null) || return 2
  case "$table" in
    *WINPID*) ;;
    *) return 2 ;;
  esac
  out=$(printf '%s\n' "$table" | awk -v w="$winpid" '$4 == w { for (i = 8; i <= NF; i++) printf "%s%s", (i > 8 ? " " : ""), $i; exit }')
  [ -n "$out" ] || return 1
  fm_win_normalize_command "$out"
}

# Environment variables through which a verified harness publishes the pid of
# its own session process. Extend only with a variable confirmed to name the
# session-long harness process on Windows, because the identity check below is
# only as narrow as this table.
#
# Walking the real Windows parent chain is deliberately NOT the fallback here.
# Two properties of this platform make it unusable for identity:
#   - MSYS emulates exec by spawning a fresh Windows process and exiting the old
#     one, so intermediate shells vanish constantly and a child's recorded parent
#     is routinely a pid that no longer exists. The chain simply breaks.
#   - Windows never reparents an orphan, so that dangling parent id stays on the
#     child and Windows is free to reissue it. Following it can therefore land on
#     an unrelated live process and bind a home's session lock to it, which is
#     the wrong-process-binding failure this file exists to prevent.
# A harness that publishes nothing is reported as unresolved instead, which
# leaves the session read-only exactly as before - the safe direction.
FM_WIN_HARNESS_PID_VARS=(CLAUDE_PID)

# The Pi CLI ships as a node bundle under the pi-coding-agent package; its
# Windows process name is node.exe, so neither the process name nor a path
# component can name it. The package marker below is that identity, and the
# session id the Pi process publishes (PI_SESSION_ID) locates the live process.
FM_PI_MARKER_RE='@earendil-works/pi-coding-agent|pi-coding-agent/(dist|bundle)'

# Pi publishes no session pid variable, only PI_SESSION_ID (the conversation
# id of the current session). When the engine is launched with --session the id
# is on its command line and fm_win_pi_harness_pid finds it there; an
# interactive TUI session launches the engine with no arguments, so the id is
# only in the tool-shell environment (PI_SESSION_ID) and never on any command
# line. In that case the engine is found by the pi-coding-agent marker alone
# and disambiguated among concurrent engines by nearest creation time to the
# session start timestamp embedded in the session file name (PI_SESSION_FILE).
# The found pid is confirmed live in the Windows table and matched as a harness
# before it is printed.

# Print this session's start time as a UTC epoch, derived from the session file
# name in $PI_SESSION_FILE (<YYYY-MM-DD>T<HH-MM-SS>-<mmm>Z_<sid>.jsonl), or
# return 1. The embedded timestamp is the session start, minted when the
# session id was generated, so it is close to the engine process creation time
# for a freshly launched session and far from it for a resumed one.
FM_PI_SESSION_EPOCH_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}'
# A freshly launched engine is created within a few seconds of the session
# start; anything farther is treated as no match rather than a guess.
FM_PI_ENGINE_MAX_AGE=300
# The nearest engine must be clearly nearer than the second-nearest, so two
# sessions launched within seconds of each other refuse rather than risk
# attributing one session's engine to the other. Refusing leaves both read-only,
# which is the safe direction for an ambiguous Windows identity.
FM_PI_ENGINE_GAP=10

fm_pi_session_start_epoch() {  # -> epoch, or 1
  local file=${PI_SESSION_FILE:-} base ts iso epoch
  [ -n "$file" ] || return 1
  base=${file##*[\\/]}
  ts=$(printf '%s' "$base" | grep -oE "$FM_PI_SESSION_EPOCH_RE") || return 1
  # The captured form is <YYYY-MM-DD>T<HH-MM-SS>; date needs colons and a Z
  # suffix to treat the timestamp as UTC.
  iso="${ts:0:10}T${ts:11:2}:${ts:14:2}:${ts:17:2}Z"
  epoch=$(date -d "$iso" +%s 2>/dev/null) || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$epoch"
}

# Print "pid epoch" lines for every live Windows process whose command line
# carries the pi-coding-agent package marker, or return 1 when the table cannot
# be read. Each line is one pi engine: the pid and its creation time as a UTC
# epoch, so a caller can pick the engine nearest this session's start.
# shellcheck disable=SC2317 # Not all consumers exist in every sourced context.
FM_PI_EPOCH_EPOCH='1970-01-01'
fm_pi_marker_engine_table() {  # -> "pid epoch" lines
  local out
  # The marker filter also matches the query's own spawned processes, whose
  # command line carries this very -Command text; exclude them so a transient
  # powershell or bash cannot be picked as the session's engine.
  out=$(powershell -NoProfile -NonInteractive -Command \
    "Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*pi-coding-agent*' -and \$_.CommandLine -notlike '*Get-CimInstance*' } | ForEach-Object { \$epoch = \$_.CreationDate.ToUniversalTime().Subtract([datetime]::ParseExact('$FM_PI_EPOCH_EPOCH','yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)).TotalSeconds; Write-Output (\$_.ProcessId.ToString() + ' ' + [int64]\$epoch) }" 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

# Print the tagged Windows pid of the pi engine whose creation time is nearest
# this session's start epoch $1, given "pid epoch" lines $2, or return 1. The
# nearest match must fall within FM_PI_ENGINE_MAX_AGE seconds of the session
# start and be clearly nearer than the second-nearest (FM_PI_ENGINE_GAP), so a
# resumed session or a near-simultaneous pair refuses instead of guessing.
fm_pi_nearest_engine_pid() {  # <session-epoch> <pid-epoch-lines> -> win:<pid>
  local target=$1 lines=$2 pid epoch best='' best_delta='' second='' delta
  while read -r pid epoch; do
    pid=${pid%$'\r'}  # PowerShell emits CRLF; strip the carriage return.
    epoch=${epoch%$'\r'}
    case "$pid:$epoch" in
      *[!0-9]:*|*:*[!0-9]) continue ;;
    esac
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    delta=$(( epoch - target ))
    [ "$delta" -lt 0 ] && delta=$(( -delta ))
    if [ -z "$best" ] || [ "$delta" -lt "$best_delta" ]; then
      second=$best_delta
      best=$pid
      best_delta=$delta
    elif [ -z "$second" ] || [ "$delta" -lt "$second" ]; then
      second=$delta
    fi
  done <<EOF
$lines
EOF
  [ -n "$best" ] || return 1
  [ "$best_delta" -le "$FM_PI_ENGINE_MAX_AGE" ] || return 1
  if [ -n "$second" ]; then
    # A second engine that is nearly as close as the best is ambiguous;
    # refuse rather than risk attributing another session's engine to this one.
    [ $(( second - best_delta )) -ge "$FM_PI_ENGINE_GAP" ] || return 1
  fi
  printf '%s%s\n' "$FM_WIN_PID_PREFIX" "$best"
}

# Print the tagged Windows pid of this session's live Pi harness process, or
# return 1. The command line is scanned for the exact session id AND the
# pi-coding-agent marker first, so a --session launch resolves exactly; when
# that finds nothing (an interactive TUI session carries the id only in the
# environment), the marker-only engine table is disambiguated by nearest
# creation time to the session start. The found pid is then confirmed live in
# the Windows table and matched as a harness before it is printed.
fm_win_pi_harness_pid() {  # -> tagged win:<pid>, or 1
  local sid=${PI_SESSION_ID:-} pids pid line target table
  [ -n "$sid" ] || return 1
  # Session ids are conversational UUIDs; refuse anything that could break out
  # of the PowerShell filter below.
  case "$sid" in
    *[!A-Za-z0-9-]*) return 1 ;;
  esac
  pids=$(powershell -NoProfile -NonInteractive -Command \
    "Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*$sid*' -and \$_.CommandLine -like '*pi-coding-agent*' } | ForEach-Object { Write-Output \$_.ProcessId }" 2>/dev/null) || return 1
  for pid in $pids; do
    pid=${pid%$'\r'}  # PowerShell emits CRLF; strip the carriage return.
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    # Confirm the full command line carries both the session id and the Pi
    # package marker; fm_win_command (exe path) cannot prove a node harness.
    line=$(fm_win_command_line "$pid") || continue
    fm_harness_process_matches "$(fm_win_command "$pid")" "$line" || continue
    printf '%s%s\n' "$FM_WIN_PID_PREFIX" "$pid"
    return 0
  done
  # Interactive TUI sessions launch the engine with no arguments, so the
  # session id is never on a command line; fall back to the marker table
  # disambiguated by nearest creation time to the session start.
  target=$(fm_pi_session_start_epoch) || return 1
  table=$(fm_pi_marker_engine_table) || return 1
  fm_pi_nearest_engine_pid "$target" "$table"
}

# Print this session's harness as one tagged Windows pid, or return 1.
#
# The published pid is a claim, not evidence, so it is never trusted on its own:
# it is confirmed against the Windows process table, and accepted only when that
# pid is still live AND its executable independently identifies a verified
# harness by the same rules every other platform uses. A value that is absent,
# malformed, stale, or naming a non-harness process is discarded rather than
# used, so a wrong or recycled pid fails closed instead of binding the lock.
fm_win_harness_ancestry_pids() {
  local var winpid comm
  for var in "${FM_WIN_HARNESS_PID_VARS[@]}"; do
    winpid=${!var:-}
    case "$winpid" in
      ''|*[!0-9]*) continue ;;
    esac
    comm=$(fm_win_command "$winpid") || continue
    fm_harness_process_matches "$comm" "$comm" || continue
    printf '%s%s\n' "$FM_WIN_PID_PREFIX" "$winpid"
    return 0
  done
  # Pi publishes no session pid, so its harness is located by session id and
  # package marker instead of by a published pid variable.
  fm_win_pi_harness_pid && return 0
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
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(fm_ps_comm "$pid") || break
    args=$(fm_ps_args "$pid")
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(fm_ps_ppid "$pid")
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  # A harness living in the same process table is always preferred, so an
  # ordinary POSIX ancestry keeps resolving to plain pids and nothing about the
  # existing platforms changes. The Windows bridge is consulted only after that
  # walk finds nothing, which on Cygwin is what the severed parent link
  # guarantees it will do.
  if [ "$printed" -eq 0 ] && fm_win_boundary_applies; then
    fm_win_harness_ancestry_pids && return 0
  fi
  [ "$printed" -eq 1 ]
}

# Print the outermost pid of this session's contiguous harness run for callers
# that need that ancestry identity. This is not necessarily the pid written to
# the session lock: fm_session_lock_anchor_pid owns that choice and uses a
# trusted Claude session's model-loop pid instead. Every non-Claude harness
# reports a single pid, so this remains its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  _fm_harness_outermost_pid "$pids"
}

# Print the last (outermost) pid of ancestry list $1, or return 1 when empty.
_fm_harness_outermost_pid() {  # <ancestry-pids>
  local pid outermost=''
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$1
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
# A tagged Windows pid is answered from the Windows process table, because
# kill -0 cannot see across that boundary and would report a live harness as
# dead - which would hand a running session's home to a second one.
fm_harness_pid_alive() {
  local pid=$1 comm args winpid line
  if winpid=$(fm_win_untag_pid "$pid"); then
    comm=$(fm_win_command "$winpid") || return 1
    fm_harness_process_matches "$comm" "$comm" && return 0
    # A node-bundle harness (Pi) is not named by its executable path; its
    # identity lives in the full command line's script path.
    line=$(fm_win_command_line "$winpid") || return 1
    fm_harness_process_matches "$comm" "$line"
    return
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(fm_ps_comm "$pid") || return 1
  args=$(fm_ps_args "$pid")
  fm_harness_process_matches "$comm" "$args"
}

# --- trusted same-session identity -------------------------------------------
# Claude Code hands every hook and tool shell CLAUDE_CODE_SESSION_ID (the
# session's conversation id) and CLAUDE_PID (the pid of the process running the
# model loop). A background session runs that model loop in a transient helper
# bridged to its front-end by a shared daemon, and when that bridge is recycled
# the contiguous claude-named ancestry from a hook to the recorded lock owner
# breaks while the owner pid stays alive, so ancestry alone reads the session's
# own lock as another live session's. The id is the one identity that survives
# the recycling, so it is accepted as a second ownership signal - but only from
# an environment proven to belong to the current Claude run.
#
# Trust gate: CLAUDE_PID must be a Claude-shaped member of this process's
# contiguous harness ancestry. An id merely retained in a helper environment
# fails that membership and is ignored: a hand-started Pi or codex primary under
# a Claude pane still carries the pane's CLAUDE_CODE_SESSION_ID and CLAUDE_PID,
# and must never own a lock with them. Ids are read from the environment only,
# never from ps argv, where prompts and briefs are visible.
#
# A --fork-session successor mints a new id, so it stays a foreign live owner
# until the pre-fork process exits; that is the safe direction and a documented
# non-goal. Two genuinely different live sessions sharing one id is not a
# supported state (Claude refuses to resume a running session under its id).

# Print the Claude session id this process may own with, or return 1. $1 is the
# ancestry list an earlier walk already produced, so a caller that walked once
# need not walk again.
fm_session_lock_trusted_session_id() {  # [<ancestry-pids>]
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-} pids=${1:-} pid comm args
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$claude_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids) || return 1
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$claude_pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" || return 1
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
    printf '%s\n' "$id"
    return 0
  done <<EOF
$pids
EOF
  return 1
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(head -n 1 "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

# True when the lock in state dir $1 was recorded by this same Claude session:
# the trusted id equals the id recorded beside the lock. No trusted id, no
# sidecar, or a different recorded id is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 trusted recorded
  trusted=$(fm_session_lock_trusted_session_id "${2:-}") || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  [ "$recorded" = "$trusted" ]
}

# Print the pid bin/fm-lock.sh records on lock line 1 for this session. For a
# Claude session with a trusted id that is CLAUDE_PID, the model-loop process:
# never the shared transient daemon and never a front-end that outlives the
# session, so "recorded pid dead" keeps meaning "session gone" instead of
# wedging a home behind a live daemon whose session died. A replaced background
# helper leaves a dead pid that its own session's next hook reclaims, because
# the sidecar still names that session. Every other session records the
# outermost pid of its contiguous run, exactly as before.
fm_session_lock_anchor_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_trusted_session_id "$pids" >/dev/null; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi
  _fm_harness_outermost_pid "$pids"
}

# True when state dir $1 holds a session lock that this process's session owns:
# the recorded pid is ANY harness ancestor of the current process, or the lock
# was recorded by this same trusted Claude session and its recorded pid is still
# a live harness. Membership is the honest ancestry test, because the lock owner
# sits at an unknown depth in a contiguous Claude run - it is the outermost pid
# when the hook fires inside the session's own nested worker chain, and an inner
# pid when a harness-named daemon parents the session. The same-session path
# requires the recorded pid alive so that a dead one is reclaimed through
# bin/fm-lock.sh's ordinary stale-owner path, which refreshes line 1, rather than
# silently owned with a dead anchor. A missing lock, a malformed lock, a lock
# held by a harness outside this ancestry under another (or no) session id, or
# an ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" || return 1
  fm_harness_pid_alive "$lock_pid"
}

# True when state dir $1 records a live verified harness outside this process's
# contiguous harness ancestry that was not recorded by this same trusted Claude
# session. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a diagnostic caller.
# Malformed, missing, dead, and ancestry-uncertain locks are not foreign-owner
# evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid pids pid
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$lock_pid" || return 1
  fm_harness_pid_alive "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 1
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" && return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}

# Read-only classification of state/.lock for machine-readable callers.
# Never acquires the lock. A held lock is not proof the holder is consuming
# wakes; that question belongs to the inbox readiness projection.
#
# Sets:
#   FM_LOCK_INSPECT_STATE         free|held|stale|unreadable|unknown
#   FM_LOCK_INSPECT_PID           recorded pid, or empty
#   FM_LOCK_INSPECT_LIVE_HARNESS  true|false|unknown
#
# held: the recorded pid is a live verified harness.
# stale: the recorded pid is gone.
# unknown: the file or pid cannot be classified without guessing, including a
# live process that is not a verified harness. Existence of a lock file, a
# session record, or a pane is never treated as liveness.
# shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
FM_LOCK_INSPECT_STATE=unknown
FM_LOCK_INSPECT_PID=
FM_LOCK_INSPECT_LIVE_HARNESS=unknown
fm_session_lock_inspect() {  # <state>
  local state=$1 lock pid winpid win_rc
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=unknown
  lock="$state/.lock"
  if [ ! -e "$lock" ]; then
    FM_LOCK_INSPECT_STATE=free
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  }
  pid=${pid%%$'\n'*}
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=$pid
  fm_session_pid_valid "$pid" || return 0
  if winpid=$(fm_win_untag_pid "$pid"); then
    # The same verdicts as a local pid below, read from the Windows table.
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
      return 0
    fi
    win_rc=0
    fm_win_command "$winpid" >/dev/null || win_rc=$?
    case "$win_rc" in
      0) FM_LOCK_INSPECT_LIVE_HARNESS=false ;;
      1)
        FM_LOCK_INSPECT_STATE=stale
        FM_LOCK_INSPECT_LIVE_HARNESS=false
        ;;
    esac
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
    else
      FM_LOCK_INSPECT_STATE=unknown
      FM_LOCK_INSPECT_LIVE_HARNESS=false
    fi
    return 0
  fi
  if ps -o comm= -p "$pid" >/dev/null 2>&1; then
    FM_LOCK_INSPECT_STATE=unknown
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=stale
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=false
}
