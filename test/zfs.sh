#!/usr/bin/env sh
## test/zfs.sh
set -eu

# check pipefail in a subshell and set if supported
# shellcheck disable=SC3040
(set -o pipefail 2> /dev/null) && set -o pipefail

_fakeZFS() {
  cmd=$1
  shift
  showSnaps=0

  ## check arguments
  for arg in "$@"; do
    case "$arg" in
      -H)
        ## nothing for now
        ;;
      -o)
        ## nothing for now
        ;;
      -t)
        ## assume snapshots for tests
        showSnaps=1
        ;;
    esac
    ## cheap way to get the last arg
    target=$arg
  done

  case "$cmd" in
    list)
      if [ $showSnaps -eq 1 ]; then
        printf "%s@autorep-test1\n" "$target"
        printf "%s@autorep-test2\n" "$target"
        printf "%s@autorep-test3\n" "$target"
        return 0
      fi
      ## allow selective failures in tests
      if [ "$(expr "$target" : 'fail')" -gt 0 ]; then
        printf "cannot open '%s': dataset does not exist\n" "$target"
        return 1
      fi
      ## just print target
      printf "%s\n" "$target"
      ;;
    receive)
      printf "%s %s\n" "$cmd" "$*"
      ;;
    destroy | snapshot | send) ;;
    *)
      printf "%s %s\n" "$cmd" "$*"
      ;;
  esac
  return 0
}

_fakeZFS "$@"
