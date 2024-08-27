#!/usr/bin/env bash
## test.sh contains zfs-replicate test cases
set -e -o pipefail

fakeLogger() {
  echo "LOGGER: " "$@"
}

fakeFind() {
  echo "FIND: " "$@"
}

fakeSSH() {
  echo "SSH: " "$@"
}

fakeZFS() {
  echo "ZFS: " "$@"
  if [[ $1 == "list" ]]; then
    echo pool/fs@autorep-08262024_1724726309
    echo pool/fs@autorep-08262024_1724726369
  fi
}

fakeCheck() {
  echo "CHECK: " "$@"
}

export LOGGER=fakeLogger
export FIND=fakeFind
export ZFS=fakeZFS
export SSH=fakeSSH
export HOST_CHECK=fakeCheck

## source the script
. ./zfs-replicate.sh || true

export REPLICATE_SETS="srcPool/srcFS:dstPool/dstFS"

loadConfig

snapCreate

exitClean 0 "testing"
