#!/usr/bin/env sh
## test/zfs.sh
set -eu

# check pipefail in a subshell and set if supported
# shellcheck disable=SC3040
(set -o pipefail 2> /dev/null) && set -o pipefail

_fakeFIND() {
  printf "find %s\n" "$*"
  return 0
}

_fakeZFS "$@"
