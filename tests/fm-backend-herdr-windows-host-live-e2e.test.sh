#!/usr/bin/env bash
# Native-Windows Herdr adapter proof: the process-host projections this adapter
# needs where Cygwin ps and MSYS kill cannot reach Herdr's native pid space.
#
# Skips off a Windows host. Every Herdr call runs in an isolated fm-lab- session
# (tests/herdr-test-safety.sh owns the refuse-default, tripwire, and teardown
# contract), so the developer's own session is never touched.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

ok() {
  printf 'ok - %s\n' "$*"
}

case "${FM_PROC_PLATFORM_OVERRIDE:-$(uname -s)}" in
  windows|MINGW*|MSYS*|CYGWIN*) ;;
  *)
    echo "skip: native Windows Git Bash host required"
    exit 0
    ;;
esac

for tool in herdr jq powershell; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "skip: $tool required"
    exit 0
  }
done

herdr_forget_inherited_pane
export FM_HOME="$ROOT"
export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

fm_backend_herdr_windows_host || fail "the Windows process host was not detected"

# 1. The native process table projects pid/ppid/comm/args/state for every
#    process, including this shell's own native pid.
table=$(fm_backend_herdr_windows_proc_table) || fail "the Windows process table did not read"
printf '%s\n' "$table" | awk -F'\t' 'NF < 4 { exit 1 }' || fail "a table row is missing a field"
self_win=$(fm_windows_msys_root_winpid $$) || fail "could not resolve this shell's native pid"
printf '%s\n' "$table" | awk -F'\t' -v pid="$self_win" '$1 == pid { found = 1 } END { exit(found ? 0 : 1) }' \
  || fail "the process table omits this shell's own native pid ($self_win)"
ok "Windows process table carries every native row, including this shell"

# 2. A native pid resolves to its bare shell through the table, and the state
#    column answers the idle question the POSIX S/I check answers.
fm_backend_herdr_pid_is_bare_shell ps "$self_win" || fail "a bash pid did not prove as a bare shell"
state_col=$(printf '%s\n' "$table" | awk -F'\t' -v pid="$self_win" '$1 == pid { print $5; exit }')
[ -n "$state_col" ] || fail "the shell row carries no thread state"
fm_backend_herdr_shell_state_is_idle "$state_col" || fail "an idle shell state '$state_col' read as busy"
node_pid=$(printf '%s\n' "$table" | awk -F'\t' '$3 == "node" { print $1; exit }')
if [ -n "$node_pid" ]; then
  fm_backend_herdr_pid_is_bare_shell ps "$node_pid" && fail "a node pid read as a bare shell"
fi
ok "bare-shell proof and idle-state proof read the native pid space"

# 3. Harness identity on Windows: the npm shim execs node against the bundle,
#    so the command line - not the kernel name - carries Pi's identity.
pi_line='D:\Application\nodejs\node.exe D:\Data\nodejs\node_global\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js --session 01a15e45'
verdict=$(fm_backend_herdr_windows_process_verdict node.exe "$pi_line")
[ "$verdict" = agent ] || fail "a Pi bundle command line read as '$verdict' instead of agent"
# Herdr hands over the command line AND argv0 as separate fields, so the shape
# below is exactly what a real pane answers: argv0 keeps the space-bearing path
# unambiguous.
verdict=$(fm_backend_herdr_windows_process_verdict bash.exe 'D:\Program Files\Git\usr\bin\bash.exe' 'D:\Program Files\Git\usr\bin\bash.exe')
[ "$verdict" = shell ] || fail "a bash.exe foreground read as '$verdict' instead of shell"
verdict=$(fm_backend_herdr_windows_process_verdict notepad.exe 'C:\Windows\notepad.exe')
[ "$verdict" = other ] || fail "a stranger process read as '$verdict' instead of other"
ok "Windows harness identity: Pi bundle is an agent, bash.exe is a shell, a stranger is other"

# 4. Live pane proof in an isolated session: an idle bash tab proves as a lone
#    idle shell, then the same pane-death close path removes it.
session=$(bash "$ROOT/bin/fm-herdr-lab.sh" name winhost)
bash "$ROOT/bin/fm-herdr-lab.sh" provision "$session" >/dev/null 2>&1 \
  || fail "the lab session did not provision"
cleanup() {
  bash "$ROOT/bin/fm-herdr-lab.sh" teardown "$session" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ws=
while IFS=$'\t' read -r ws_id ws_tab ws_pane; do
  [ -n "$ws_id" ] || continue
  ws=$ws_id
  pane=$ws_pane
done <<EOF
$(fm_backend_herdr_cli "$session" workspace create --cwd "$ROOT" --label fm-winhost --no-focus 2>/dev/null \
  | jq -r '[.result.workspace.workspace_id, .result.tab.tab_id, .result.root_pane.pane_id] | @tsv' 2>/dev/null)
EOF
[ -n "${ws:-}" ] && [ -n "${pane:-}" ] || fail "the lab workspace did not create"

shell_pid=
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if shell_pid=$(fm_backend_herdr_pane_idle_shell_pid "$session" "$pane" 2>/dev/null); then
    break
  fi
  shell_pid=
  sleep 0.5
done
[ -n "$shell_pid" ] || fail "the idle-shell proof did not settle on a fresh bash tab"
ok "idle-shell proof settles on a native Windows bash pane (pid $shell_pid)"

state=$(fm_backend_herdr_pane_process_state "$session" "$pane")
[ "$state" = shell ] || fail "an idle bash pane read as '$state' instead of shell"
ok "agent-free pane proof reads an idle bash pane as shell"

# 5. The foreground verdict on this host is driven by the Windows identity
#    rule, not by ps-shaped surfaces: a Pi launched through the npm shim
#    (foreground comm `node.exe`) reads as an agent, and any non-shell
#    foreground never reads as a shell-only pane. Canned process-info is enough
#    here because the rule under test is the classification, not Herdr's IPC;
#    the live pane proofs above already exercise the real read path.
fake_info() {  # <name> <argv0> <cmdline>
  jq -cn --arg name "$1" --arg argv0 "$2" --arg cmdline "$3" '{
    result: {
      type: "pane_process_info",
      process_info: {
        pane_id: "wX:p9",
        shell_pid: 100,
        foreground_process_group_id: 200,
        foreground_processes: [{pid: 200, name: $name, argv0: $argv0, cmdline: $cmdline}]
      }
    }
  }'
}

(
  # The canned verdict checks shadow the CLI, so they run in a subshell: the
  # live pane proofs below must keep the real adapter client.
  fm_backend_herdr_cli() {
    printf '%s' "$FAKE_INFO"
  }

  FAKE_INFO=$(fake_info node.exe 'D:\Application\nodejs\node.exe'     'D:\Application\nodejs\node.exe D:\Data\nodejs\node_global\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js --session 01a15e45')
  verdict=$(fm_backend_herdr_pane_process_state_sample default wX:p9)
  [ "$verdict" = agent ] || { printf 'shim-launched Pi foreground read as %s
' "$verdict" >&2; exit 1; }

  FAKE_INFO=$(fake_info sleep.exe 'C:\Windows\System32\sleep.exe' 'sleep 60')
  verdict=$(fm_backend_herdr_pane_process_state_sample default wX:p9)
  [ "$verdict" = other ] || { printf 'non-shell foreground read as %s
' "$verdict" >&2; exit 1; }
) || fail "foreground verdicts did not route through the Windows harness identity rule"
ok "foreground verdicts route through the Windows harness identity rule"

# 6. Pane-death close: the proved lone idle shell is ended with the host's own
#    signal delivery and Herdr drops the pane.
fm_backend_herdr_death_close_pane "$session" "$pane" "$shell_pid" \
  || fail "the pane-death close did not confirm the pane gone"
presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane")
[ "$presence" = dead ] || fail "the pane survived the close (presence=$presence)"
ok "pane-death close ends a native Windows shell and Herdr drops the pane"

printf 'all Windows-host Herdr adapter proofs passed\n'
