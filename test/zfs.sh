#!/usr/bin/env sh
## test/zfs.sh
set -eu

# check pipefail in a subshell and set if supported
# shellcheck disable=SC3040
(set -o pipefail 2> /dev/null) && set -o pipefail

_fakeZFS() {
  cmd=$1

  for arg in "$@"; do
    target=$arg
  done

  case "$cmd" in
    list)
      ## this should probably check for dataset or snapshot list, but it works for testing
      printf "%s@autorep-test1\n" "${target}"
      printf "%s@autorep-test2\n" "${target}"
      printf "%s@autorep-test3\n" "${target}"
      ;;
    receive)
      printf "%s\n" "$*"
      ;;
    destroy | snapshot) ;;
    *)
      printf "zfs %s\n" "$*"
      ;;
  esac
  return 0
}

_fakeZFS "$@"
