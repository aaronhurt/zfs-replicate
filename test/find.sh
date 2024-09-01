#!/usr/bin/env sh
## test/zfs.sh
set -eu

# check pipefail in a subshell and set if supported
# shellcheck disable=SC3040
(set -o pipefail 2> /dev/null) && set -o pipefail

_fakeFIND() {
  path="$1"
  printf "%s/autorep-test1.log\n" "$path"
  printf "%s/autorep-test2.log\n" "$path"
  printf "%s/autorep-test3.log\n" "$path"
  return 0
}

_fakeFIND "$@"
