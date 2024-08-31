#!/usr/bin/env dash
## test.sh contains zfs-replicate test cases
set -eu ## fail on errors and undefined variables

# check pipefail in a subshell and set if supported
# shellcheck disable=SC3040
(set -o pipefail 2> /dev/null) && set -o pipefail

## set self identification values
SCRIPT_PATH="${0%/*}"

## check line against match and exit on failure
_fail() {
  line=$1
  match=$2
  ## verbose testing
  ## hack to match blank lines
  if [ "$match" = "null" ] && [ -n "$line" ]; then
    printf "FAILED '%s' != ''\n" "$line" && exit 1
  fi
  case "$line" in
    *"$match"*) ;;
    *) printf "FAILED '%s' != '*%s*'\n" "$line" "$match" && exit 1 ;;
  esac
  return 0
}

_testZFSReplicate() {
  ## wrapper for easy matching
  export ECHO="echo"
  ## define test conditions
  export FIND="${SCRIPT_PATH}/find.sh"
  export ZFS="${SCRIPT_PATH}/zfs.sh"
  export SSH="${SCRIPT_PATH}/ssh.sh"
  export HOST_CHECK="${ECHO} %HOST%"
  export SYSLOG=0
  REPLICATE_SETS="srcPool0/srcFS0:dstPool0/dstFS0"
  REPLICATE_SETS="${REPLICATE_SETS} srcPool1/srcFS1/subFS1:dstPool1/dstFS1@dstHost1"
  REPLICATE_SETS="${REPLICATE_SETS} srcPool2/srcFS2:dstPool2/dstFS2@dstHost2"
  REPLICATE_SETS="${REPLICATE_SETS} srcPool3/srcFS3@srcHost3:dstPool3/dstFS3"
  REPLICATE_SETS="${REPLICATE_SETS} srcPool4/srcFS4@srcHost4:dstPool4/dstFS4@dstHost4"

  ## test loadConfig
  (
    ## source script functions
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh
    printf "_testSetsNoConfig/loadConfig\n" ## we expect no output and clean exit
    loadConfig | awk '{ print NR-1, $0 }' | while read -r idx line; do
      printf "%d %s\n" "$idx" "$line"
      case $idx in
        *)
          _fail "$line" "null"
          ;;
      esac
    done
  )

  ## test config override
  (
    ## likely default values at script load time
    ZFS="/sbin/zfs"
    SSH="/usr/sbin/ssh"
    ## source script functions
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh
    printf "_testSetsNoConfig/loadConfigOverrideDefaults\n"
    _fail "/usr/sbin/ssh %HOST% /sbin/zfs receive -vFd" "$DEST_PIPE_WITH_HOST"
    _fail "/sbin/zfs receive -vFd" "$DEST_PIPE_WITHOUT_HOST"
    ## generate config
    config="$(mktemp)"
    printf "ZFS=\"myZFS\"\n" >> "$config"
    ## set SSH via environment
    SSH="mySSH"
    loadConfig "$config" && rm -f "$config"
    ## values should match config and environment
    _fail "mySSH %HOST% myZFS receive -vFd" "$DEST_PIPE_WITH_HOST"
    _fail "myZFS receive -vFd" "$DEST_PIPE_WITHOUT_HOST"
  )

  ## test snapCreate
  (
    ## source script functions
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh && loadConfig
    printf "_testSetsNoConfig/snapCreate\n"
    snapCreate | awk '{ print NR-1, $0 }' | while read -r idx line; do
      match=""
      printf "%d %s\n" "$idx" "$line"
      case $idx in
        0)
          match="creating lockfile ${TMPDIR}/.replicate.snapshot.lock"
          ;;
        1)
          match="cmd=${ZFS} list -H -o name srcPool0/srcFS0"
          ;;
        5)
          match="cmd=${ZFS} list -H -o name dstPool0/dstFS0"
          ;;
        10)
          match="cmd=${ZFS} destroy srcPool0/srcFS0@autorep-test1"
          ;;
        11)
          match="cmd=${ZFS} snapshot srcPool0/srcFS0@autorep-"
          ;;
        12)
          match="creating lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        13)
          match="cmd=${ZFS} send -Rs -I srcPool0/srcFS0@autorep-test3 srcPool0/srcFS0@autorep-${TAG} |"
          match="$match ${DEST_PIPE_WITHOUT_HOST} dstPool0/dstFS0"
          ;;
        14)
          match="receive -vFd dstPool0/dstFS0"
          ;;
        15)
          match="deleting lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        16)
          match="cmd=${ECHO} dstHost1"
          ;;
        17)
          match="cmd=${ZFS} list -H -o name srcPool1/srcFS1/subFS1"
          ;;
        21)
          match="cmd=${SSH} dstHost1 ${ZFS} list -H -o name dstPool1/dstFS1"
          ;;
        26)
          match="cmd=${ZFS} destroy srcPool1/srcFS1/subFS1@autorep-test1"
          ;;
        27)
          match="cmd=${ZFS} snapshot srcPool1/srcFS1/subFS1@autorep-${TAG}"
          ;;
        28)
          match="creating lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        29)
          match="cmd=${ZFS} send -Rs -I srcPool1/srcFS1/subFS1@autorep-test3 srcPool1/srcFS1/subFS1@autorep-${TAG} |"
          match="$match ${SSH} dstHost1 ${ZFS} receive -vFd dstPool1/dstFS1"
          ;;
        31)
          match="deleting lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        33)
          match="cmd=${ZFS} list -H -o name srcPool2/srcFS2"
          ;;
        37)
          match="cmd=${SSH} dstHost2 ${ZFS} list -H -o name dstPool2/dstFS2"
          ;;
        42)
          match="cmd=${ZFS} destroy srcPool2/srcFS2@autorep-test1"
          ;;
        43)
          match="cmd=${ZFS} snapshot srcPool2/srcFS2@autorep-${TAG}"
          ;;
        44)
          match="creating lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        45)
          match="cmd=${ZFS} send -Rs -I srcPool2/srcFS2@autorep-test3 srcPool2/srcFS2@autorep-${TAG} |"
          match="$match ${SSH} dstHost2 ${ZFS} receive -vFd dstPool2/dstFS2"
          ;;
        47)
          match="deleting lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        48)
          match="cmd=${ECHO} srcHost3"
          ;;
        49)
          match=" cmd=${SSH} srcHost3 ${ZFS} list -H -o name srcPool3/srcFS3"
          ;;
        53)
          match="cmd=${ZFS} list -H -o name dstPool3/dstFS3"
          ;;
        58)
          match="cmd=${SSH} srcHost3 ${ZFS} destroy srcPool3/srcFS3@autorep-test1"
          ;;
        59)
          match="cmd=${SSH} srcHost3 ${ZFS} snapshot srcPool3/srcFS3@autorep-${TAG}"
          ;;
        60)
          match="creating lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        61)
          match="cmd=${SSH} srcHost3 ${ZFS} send -Rs -I srcPool3/srcFS3@autorep-test3 srcPool3/srcFS3@autorep-${TAG} |"
          match="$match ${ZFS} receive -vFd dstPool3/dstFS3"
          ;;
        63)
          match="deleting lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        66)
          match="cmd=${SSH} srcHost4 ${ZFS} list -H -o name srcPool4/srcFS4"
          ;;
        70)
          match="cmd=${SSH} dstHost4 ${ZFS} list -H -o name dstPool4/dstFS4"
          ;;
        75)
          match="cmd=${SSH} srcHost4 ${ZFS} destroy srcPool4/srcFS4@autorep-test1"
          ;;
        76)
          match="cmd=${SSH} srcHost4 ${ZFS} snapshot srcPool4/srcFS4@autorep-${TAG}"
          ;;
        77)
          match="creating lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        78)
          match="cmd=${SSH} srcHost4 ${ZFS} send -Rs -I srcPool4/srcFS4@autorep-test3 srcPool4/srcFS4@autorep-${TAG} |"
          match="$match ${SSH} dstHost4 ${ZFS} receive -vFd dstPool4/dstFS4"
          ;;
        80)
          match="deleting lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        81)
          match="deleting lockfile ${TMPDIR}/.replicate.snapshot.lock"
          ;;
      esac
      _fail "$line" "$match"
    done
  )

  ## test exitClean
  (
    ## source script functions
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh && loadConfig
    printf "_testSetsNoConfig/exitClean\n"
    exitClean 0 "test message" | awk '{ print NR-1, $0 }' | while read -r idx line; do
      printf "%d %s\n" "$idx" "$line"
      case $idx in
        0)
          match="success total sets 0 skipped 0: test message"
          _fail "$line" "$match"
          ;;
      esac
    done
  )

  ## yay, tests completed!
  return 0
}

_testZFSReplicate
