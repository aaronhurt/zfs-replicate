#!/usr/bin/env bash
# shellcheck disable=SC2317
## test.sh contains zfs-replicate test cases
set -e -o pipefail

outFile="$(mktemp)"
captureOutput() {
  local line
  while IFS= read -r line; do
    printf "%s\n" "$line" >> "$outFile"
  done
}

resetOutput() {
  : > "$outFile"
}

cleanOutput() {
  rm -f "$outFile"
}

dumpOutput() {
  cat "$outFile"
}

fakeLogger() {
  printf "LOGGER: %s\n" "$@"
  return 0
}

fakeFind() {
  printf "FIND: %s\n" "$@"
  return 0
}

fakeSSH() {
  printf "SSH: %s\n" "$@"
  return 0
}

fakeZFS() {
  local cmd=$1
  local args=("$@")
  local target="${args[-1]}"

  printf "ZFS: %s\n" "$@"

  case "$cmd" in
    list)
      printf "%s@autorep-test1\n" "${target}"
      printf "%s@autorep-test2\n" "${target}"
      printf "%s@autorep-test3\n" "${target}"
      ;;
  esac
  return 0
}

fakeCheck() {
  printf "CHECK: %s\n" "$@"
  return 0
}

## define test conditions
export LOGGER=fakeLogger
export FIND=fakeFind
export ZFS=fakeZFS
export SSH=fakeSSH
export HOST_CHECK=fakeCheck
export SYSLOG=0

## source main script
. ./zfs-replicate.sh || true

export REPLICATE_SETS="srcPool/srcFS:dstPool/dstFS"

loadConfig 2>&1 | captureOutput

## TODO check for expected output
dumpOutput
resetOutput

snapCreate 2>&1 | captureOutput

## TODO check for expected output
dumpOutput
resetOutput

exitClean 0 "testing" 2>&1 | captureOutput

## TODO check for expected output
dumpOutput
cleanOutput
