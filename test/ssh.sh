#!/usr/bin/env sh
## test/zfs.sh
set -eu

# check pipefail in a subshell and set if supported
# shellcheck disable=SC3040
(set -o pipefail 2> /dev/null) && set -o pipefail

_fakeSSH() {
  host=$1
  shift
  cmd=$1
  shift
  case "$cmd" in
    *zfs*)
      ./zfs.sh "$@"
      ;;
    *)
      printf "ssh $host $cmd %s\n" "$(printf "%s\n" "$@" | tr "\n" " ")"
      ;;
  esac
  return 0
}

_fakeSSH "$@"
