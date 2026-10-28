#!/usr/bin/env bash
# Behavior tests for the two file-digest helpers that gate trust decisions:
# bin/fm-check-lib.sh fm_custom_check_sha256 and bin/fm-pr-lib.sh fm_pr_sha256.
# Both must report the bare hex digest for a path that contains a backslash,
# because GNU coreutils prefixes its whole output line with one when the
# filename does, and a Windows-form FM_HOME puts backslashes in the path of
# every state/<id>.check.sh. A prefixed digest never matches a recorded one, so
# every trusted check looked unauthenticated on MSYS hosts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-check-lib)

# A digest computed through stdin is the reference reading: the name is "-", so
# no platform quoting rule can reach it.
expected_sha256() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | awk '{print $1}'
  else
    sha256sum < "$1" | awk '{print $1}'
  fi
}

# The trigger path form differs by platform. MSYS hosts cannot name a file with
# a backslash, but they report a normal path in Windows form, which is the exact
# shape this home's watcher is launched with. POSIX hosts can hold a backslash
# in a filename, so the same escaping rule is still exercised there.
backslash_path() {  # <dir> <name>
  local dir=$1 name=$2
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$dir/$name"
    return 0
  fi
  mkdir -p "$dir/sub"
  printf '%s' "$dir/sub\\$name"
}

test_digests_ignore_backslash_path_escaping() {
  local dir name path expected check_digest pr_digest
  dir="$TMP_ROOT/state"
  name='fixture.check.sh'
  mkdir -p "$dir"
  printf 'printf "ready\\n"\n' > "$dir/$name"
  expected=$(expected_sha256 "$dir/$name")

  path=$(backslash_path "$dir" "$name")
  case "$path" in
    *\\*) ;;
    *) fail "platform produced no backslash in the digest fixture path" ;;
  esac

  check_digest=$(fm_custom_check_sha256 "$path") || fail "custom-check digest read failed"
  pr_digest=$(fm_pr_sha256 "$path") || fail "PR digest read failed"

  [ "$check_digest" = "$expected" ] \
    || fail "custom-check digest did not match the stdin reading for a backslash path"
  [ "$pr_digest" = "$expected" ] \
    || fail "PR digest did not match the stdin reading for a backslash path"
  case "$check_digest$pr_digest" in
    *\\*) fail "a digest carried coreutils' leading backslash escape" ;;
  esac
  case "$check_digest" in
    ''|*[!0-9a-f]*) fail "custom-check digest is not bare lowercase hex" ;;
  esac
  [ "${#check_digest}" -eq 64 ] || fail "custom-check digest is not 64 hex characters"
  pass "both digest helpers match the stdin reading for a backslash path"
}

test_missing_file_fails_instead_of_hashing_nothing() {
  local status
  status=0
  fm_custom_check_sha256 "$TMP_ROOT/absent.check.sh" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "custom-check digest accepted a missing file"
  status=0
  fm_pr_sha256 "$TMP_ROOT/absent.check.sh" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "PR digest accepted a missing file"
  pass "both digest helpers fail for a missing file"
}

test_digests_ignore_backslash_path_escaping
test_missing_file_fails_instead_of_hashing_nothing
