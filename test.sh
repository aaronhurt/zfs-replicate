#!/usr/bin/env bash
# shellcheck disable=SC2317
## test.sh contains zfs-replicate test cases
set -e -o pipefail

_fakeLogger() {
  return 0
}

_fakeFind() {
  return 0
}

_fakeSSH() {
  return 0
}

_fakeZFS() {
  local cmd=$1
  local args=("$@")
  local target="${args[-1]}"

  case "$cmd" in
    list)
      printf "%s@autorep-test1\n" "${target}"
      printf "%s@autorep-test2\n" "${target}"
      printf "%s@autorep-test3\n" "${target}"
      ;;
  esac
  return 0
}

_fakeCheck() {
  return 0
}

_testSimpleSetNoConfig() {
  ## define test conditions
  export FIND=_fakeFind
  export ZFS=_fakeZFS
  export DEST_PIPE_WITHOUT_HOST="echo receive -vFd"
  export SYSLOG=0
  export REPLICATE_SETS="srcPool/srcFS:dstPool/dstFS"

  ## set output
  local configOut snapOut exitOut line idx match

  ## source script and run test
  . ./zfs-replicate.sh || true
  mapfile -t configOut < <(loadConfig)
  mapfile -t snapOut < <(snapCreate)
  mapfile -t exitOut < <(exitClean 0 "test message")

  line="${configOut[0]}"
  printf "%d %s\n" 0 "$line"
  [[ ! "$line" == *"loading configuration from defaults"* ]] && exit 1

  for idx in "${!snapOut[@]}"; do
    line="${snapOut[idx]}"
    printf "%d %s\n" "$idx" "$line"
    case $idx in
      1)
        match="cmd=_fakeZFS list -H -o name srcPool/srcFS"
        [[ ! "$line" == *"$match" ]] && exit 1
        ;;
      5)
        match="cmd=_fakeZFS list -H -o name dstPool/dstFS"
        [[ ! "$line" == *"$match" ]] && exit 1
        ;;
      10)
        match="cmd=_fakeZFS destroy srcPool/srcFS@autorep-test1"
        [[ ! "$line" == *"$match" ]] && exit 1
        ;;
      12)
        match="cmd=_fakeZFS destroy srcPool/srcFS@autorep-test2"
        [[ ! "$line" == *"$match" ]] && exit 1
        ;;
      14)
        match="cmd=_fakeZFS destroy srcPool/srcFS@autorep-test3"
        [[ ! "$line" == *"$match" ]] && exit 1
        ;;
      15)
        match="cmd=_fakeZFS snapshot srcPool/srcFS@autorep-"
        [[ ! "$line" == *"$match" ]] && exit 1
        ;;
      17)
        match="cmd=_fakeZFS send -Rs -I srcPool/srcFS@autorep-test3 srcPool/srcFS@autorep- | "
        match+="echo receive -vFd dstPool/dstFS"
        [[ ! "$line" == *"$match" ]] && exit 1
        ;;
    esac
  done

  for idx in "${!exitOut[@]}"; do
    line="${exitOut[idx]}"
    printf "%d %s\n" "$idx" "$line"
    case $idx in
      0)
        match="deleting lockfile "
        [[ ! "$line" == "$match"* ]] && exit 1
        ;;
      1)
        match="success total sets 0 skipped 0: test message" ## bug in test
        [[ ! "$line" == "$match" ]] && exit 1
        ;;
    esac
  done
}

_testSimpleSetNoConfig
