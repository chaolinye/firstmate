#!/usr/bin/env bash
# fm-path-lib.sh - fork-free pathname helpers with no source-time side effects,
# so read-only callers can load them without any library's state setup.
#
# Each assigns <output-variable> exactly what `$(dirname -- <path>)` or
# `$(basename -- <path>)` would: POSIX component rules, and the command
# substitution's removal of trailing newlines.

fm_dirname_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') fm_path=. ;;
    *[!/]*)
      fm_path=${fm_path%"${fm_path##*[!/]}"}
      case "$fm_path" in
        */*)
          fm_path=${fm_path%/*}
          fm_path=${fm_path%"${fm_path##*[!/]}"}
          [ -n "$fm_path" ] || fm_path=/
          ;;
        *) fm_path=. ;;
      esac
      ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

fm_basename_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') ;;
    *[!/]*) fm_path=${fm_path%"${fm_path##*[!/]}"}; fm_path=${fm_path##*/} ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

# fm_path_canonical_to <output-variable> <path>: fold path FORM differences for
# same-home comparisons. On Windows hosts a path can be recorded as the MSYS
# form (/d/Code/...), the Windows drive form (D:/Code/...), or with backslash
# separators (D:\Code\...), and two writers of the same home can disagree on
# the form (the Pi watcher extension injects a Windows-form FM_HOME while the
# turn-end guard derives the MSYS form). The comparison is always between two
# renderings of the SAME physical home, so canonicalizing separators, the drive
# prefix, and case folds the representations onto one another without changing
# what the comparison means on case-sensitive Linux paths.
fm_path_canonical_to() {  # <output-variable> <path>
  local fm_path=$2
  fm_path=${fm_path//\\//}
  case "$fm_path" in
    [A-Za-z]:/*) fm_path="/${fm_path%%:*}${fm_path#*:}" ;;
  esac
  printf -v "$1" '%s' "${fm_path,,}"
}

