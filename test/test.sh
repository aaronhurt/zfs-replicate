#!/usr/bin/env sh
# shellcheck disable=SC2030,SC2031,SC2034
## ^^ tests are intentionally run in subshells
## variables that appear unused here are used by main script

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
  ## hack to match blank lines
  if [ "$match" = "null" ]; then
    if [ -n "$line" ]; then
      printf "FAILED '%s' != ''\n" "$line" && exit 1
    fi
    return 0
  fi
  case "$line" in
    *"$match"*) ;;
    *) printf "FAILED '%s' != '*%s*'\n" "$line" "$match" && exit 1 ;;
  esac
  return 0
}

_testZFSReplicate() {
  ## wrapper for easy matching
  ECHO="echo"
  ## disable syslog for tests
  SYSLOG=0

  ## test loadConfig without error
  (
    FIND="fakeFIND"
    ZFS="fakeZFS"
    SSH="fakeSSH"
    REPLICATE_SETS="fakeSource:fakeDest"
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh
    printf "_testZFSReplicate/loadConfigWithoutError\n"
    line=$(loadConfig)
    _fail "$line" "null" ## we expect no output here
  )

  ## test loadConfig with missing values
  (
    FIND="fakeFIND"
    ZFS="fakeZFS"
    SSH="fakeSSH"
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh
    printf "_testZFSReplicate/loadConfigWithError\n"
    ! line=$(loadConfig) && true ## prevent tests from exiting
    _fail "$line" "missing required setting REPLICATE_SETS"
  )

  ## test config override of script defaults
  (
    ## likely default values at script load time
    FIND="/usr/bin/find"
    ZFS="/sbin/zfs"
    SSH="/usr/sbin/ssh"
    REPLICATE_SETS="fakeSource:fakeDest"
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh
    printf "_testZFSReplicate/loadConfigOverrideDefaults\n"
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

  ## test snapCreate with different set combinations
  (
    ## configure test parameters
    FIND="${SCRIPT_PATH}/find.sh"
    ZFS="${SCRIPT_PATH}/zfs.sh"
    SSH="${SCRIPT_PATH}/ssh.sh"
    HOST_CHECK="${ECHO} %HOST%"
    REPLICATE_SETS="srcPool0/srcFS0:dstPool0/dstFS0"
    REPLICATE_SETS="${REPLICATE_SETS} srcPool1/srcFS1/subFS1:dstPool1/dstFS1@dstHost1"
    REPLICATE_SETS="${REPLICATE_SETS} srcPool2/srcFS2:dstPool2/dstFS2@dstHost2"
    REPLICATE_SETS="${REPLICATE_SETS} srcPool3/srcFS3@srcHost3:dstPool3/dstFS3"
    REPLICATE_SETS="${REPLICATE_SETS} srcPool4/srcFS4@srcHost4:dstPool4/dstFS4@dstHost4"
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh && loadConfig
    printf "_testZFSReplicate/snapCreateWithoutErrors\n"
    idx=0
    snapCreate | while IFS= read -r line; do
      match=""
      printf "%d %s\n" "$idx" "$line"
      case $idx in
        0)
          match="creating lockfile ${TMPDIR}/.replicate.snapshot.lock"
          ;;
        1)
          match="cmd=${ZFS} list -H -o name srcPool0/srcFS0"
          ;;
        3)
          match="cmd=${ZFS} list -H -o name dstPool0/dstFS0"
          ;;
        6)
          match="cmd=${ZFS} destroy srcPool0/srcFS0@autorep-test1"
          ;;
        7)
          match="cmd=${ZFS} snapshot srcPool0/srcFS0@autorep-"
          ;;
        8)
          match="creating lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        9)
          match="cmd=${ZFS} send -Rs -I srcPool0/srcFS0@autorep-test3 srcPool0/srcFS0@autorep-${TAG} |"
          match="$match ${DEST_PIPE_WITHOUT_HOST} dstPool0/dstFS0"
          ;;
        10)
          match="receive -vFd dstPool0/dstFS0"
          ;;
        11)
          match="deleting lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        12)
          match="cmd=${ECHO} dstHost1"
          ;;
        13)
          match="cmd=${ZFS} list -H -o name srcPool1/srcFS1/subFS1"
          ;;
        15)
          match="cmd=${SSH} dstHost1 ${ZFS} list -H -o name dstPool1/dstFS1"
          ;;
        18)
          match="cmd=${ZFS} destroy srcPool1/srcFS1/subFS1@autorep-test1"
          ;;
        19)
          match="cmd=${ZFS} snapshot srcPool1/srcFS1/subFS1@autorep-${TAG}"
          ;;
        20)
          match="creating lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        21)
          match="cmd=${ZFS} send -Rs -I srcPool1/srcFS1/subFS1@autorep-test3 srcPool1/srcFS1/subFS1@autorep-${TAG} |"
          match="$match ${SSH} dstHost1 ${ZFS} receive -vFd dstPool1/dstFS1"
          ;;
        23)
          match="deleting lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        24)
          match="cmd=${ECHO} dstHost2"
          ;;
        25)
          match="cmd=${ZFS} list -H -o name srcPool2/srcFS2"
          ;;
        27)
          match="cmd=${SSH} dstHost2 ${ZFS} list -H -o name dstPool2/dstFS2"
          ;;
        30)
          match="cmd=${ZFS} destroy srcPool2/srcFS2@autorep-test1"
          ;;
        31)
          match="cmd=${ZFS} snapshot srcPool2/srcFS2@autorep-${TAG}"
          ;;
        32)
          match="creating lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        33)
          match="cmd=${ZFS} send -Rs -I srcPool2/srcFS2@autorep-test3 srcPool2/srcFS2@autorep-${TAG} |"
          match="$match ${SSH} dstHost2 ${ZFS} receive -vFd dstPool2/dstFS2"
          ;;
        35)
          match="deleting lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        36)
          match="cmd=${ECHO} srcHost3"
          ;;
        37)
          match=" cmd=${SSH} srcHost3 ${ZFS} list -H -o name srcPool3/srcFS3"
          ;;
        39)
          match="cmd=${ZFS} list -H -o name dstPool3/dstFS3"
          ;;
        42)
          match="cmd=${SSH} srcHost3 ${ZFS} destroy srcPool3/srcFS3@autorep-test1"
          ;;
        43)
          match="cmd=${SSH} srcHost3 ${ZFS} snapshot srcPool3/srcFS3@autorep-${TAG}"
          ;;
        44)
          match="creating lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        45)
          match="cmd=${SSH} srcHost3 ${ZFS} send -Rs -I srcPool3/srcFS3@autorep-test3 srcPool3/srcFS3@autorep-${TAG} |"
          match="$match ${ZFS} receive -vFd dstPool3/dstFS3"
          ;;
        47)
          match="deleting lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        48)
          match="cmd=${ECHO} srcHost4"
          ;;
        49)
          match="cmd=${ECHO} dstHost4"
          ;;
        50)
          match="cmd=${SSH} srcHost4 ${ZFS} list -H -o name srcPool4/srcFS4"
          ;;
        52)
          match="cmd=${SSH} dstHost4 ${ZFS} list -H -o name dstPool4/dstFS4"
          ;;
        55)
          match="cmd=${SSH} srcHost4 ${ZFS} destroy srcPool4/srcFS4@autorep-test1"
          ;;
        56)
          match="cmd=${SSH} srcHost4 ${ZFS} snapshot srcPool4/srcFS4@autorep-${TAG}"
          ;;
        57)
          match="creating lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        58)
          match="cmd=${SSH} srcHost4 ${ZFS} send -Rs -I srcPool4/srcFS4@autorep-test3 srcPool4/srcFS4@autorep-${TAG} |"
          match="$match ${SSH} dstHost4 ${ZFS} receive -vFd dstPool4/dstFS4"
          ;;
        60)
          match="deleting lockfile ${TMPDIR}/.replicate.send.lock"
          ;;
        61)
          match="deleting lockfile ${TMPDIR}/.replicate.snapshot.lock"
          ;;
      esac
      _fail "$line" "$match"
      idx=$((idx + 1))
    done
  )

  ## test snapCreate with host check errors
  (
    ## configure test parameters
    FIND="${SCRIPT_PATH}/find.sh"
    ZFS="${SCRIPT_PATH}/zfs.sh"
    SSH="${SCRIPT_PATH}/ssh.sh"
    HOST_CHECK="false"
    REPLICATE_SETS="srcPool0/srcFS0:dstPool0/dstFS0"
    REPLICATE_SETS="${REPLICATE_SETS} srcPool1/srcFS1/subFS1:dstPool1/dstFS1@dstHost1"
    REPLICATE_SETS="${REPLICATE_SETS} srcPool2/srcFS2:dstPool2/dstFS2@dstHost2"
    REPLICATE_SETS="${REPLICATE_SETS} srcPool3/srcFS3@srcHost3:dstPool3/dstFS3"
    REPLICATE_SETS="${REPLICATE_SETS} srcPool4/srcFS4@srcHost4:dstPool4/dstFS4@dstHost4"
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh && loadConfig
    printf "_testZFSReplicate/snapCreateWithHostCheckErrors\n"
    idx=0
    snapCreate | while IFS= read -r line; do
      match=""
      printf "%d %s\n" "$idx" "$line"
      case $idx in
        0)
          match="creating lockfile ${TMPDIR}/.replicate.snapshot.lock"
          ;;
        13)
          match="source or destination host check failed"
          ;;
        15)
          match="source or destination host check failed"
          ;;
        17)
          match="source or destination host check failed"
          ;;
        19)
          match="source or destination host check failed"
          ;;
        20)
          match="deleting lockfile ${TMPDIR}/.replicate.snapshot.lock"
          ;;
      esac
      _fail "$line" "$match"
      idx=$((idx + 1))
    done
  )

  ## test snapCreate with dataset check errors
  (
    ## configure test parameters
    FIND="${SCRIPT_PATH}/find.sh"
    ZFS="${SCRIPT_PATH}/zfs.sh"
    SSH="${SCRIPT_PATH}/ssh.sh"
    HOST_CHECK="${ECHO} %HOST%"
    REPLICATE_SETS="failPool0/srcFS0:dstPool0/dstFS0"
    REPLICATE_SETS="${REPLICATE_SETS} srcPool1/srcFS1:failPool1/dstFS1@dstHost1"
    REPLICATE_SETS="${REPLICATE_SETS} failPool2/srcFS2@srcHost2:dstPool2/dstFS2"
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh && loadConfig
    printf "_testZFSReplicate/snapCreateWithDatasetCheckErrors\n"
    idx=0
    snapCreate | while IFS= read -r line; do
      match=""
      printf "%d %s\n" "$idx" "$line"
      case $idx in
        0)
          match="creating lockfile ${TMPDIR}/.replicate.snapshot.lock"
          ;;
        1)
          match="cmd=${ZFS} list -H -o name failPool0/srcFS0"
          ;;
        2)
          match="dataset does not exist"
          ;;
        3)
          match="source or destination dataset check failed"
          ;;
        5)
          match="cmd=${ZFS} list -H -o name srcPool1/srcFS1"
          ;;
        6)
          match="srcPool1/srcFS1"
          ;;
        7)
          match="cmd=${SSH} dstHost1 ${ZFS} list -H -o name failPool1/dstFS1"
          ;;
        8)
          match="dataset does not exist"
          ;;
        9)
          match="source or destination dataset check failed"
          ;;
        11)
          match="cmd=${SSH} srcHost2 ${ZFS} list -H -o name failPool2/srcFS2"
          ;;
        12)
          match="dataset does not exist"
          ;;
        13)
          match="source or destination dataset check failed"
          ;;
        14)
          match="deleting lockfile ${TMPDIR}/.replicate.snapshot.lock"
          ;;
      esac
      _fail "$line" "$match"
      idx=$((idx + 1))
    done
  )

  ## test exitClean code=0 and extra message
  (
    FIND="fakeFIND"
    ZFS="fakeZFS"
    SSH="fakeSSH"
    REPLICATE_SETS="fakeSource:fakeDest"
    ## source script functions
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh && loadConfig
    printf "_testZFSReplicate/exitCleanSuccess\n"
    line=$(exitClean 0 "test message")
    match="success total sets 0 skipped 0: test message" ## counts are modified in snapCreate
    _fail "$line" "$match"
  )

  ## test exitClean code=99 with error message
  (
    FIND="fakeFIND"
    ZFS="fakeZFS"
    SSH="fakeSSH"
    REPLICATE_SETS="fakeSource:fakeDest"
    ## source script functions
    # shellcheck source=/dev/null
    . ../zfs-replicate.sh && loadConfig
    printf "_testZFSReplicate/exitCleanError\n"
    ! line=$(exitClean 99 "error message") && true ## prevent tests from exiting
    match="operation exited unexpectedly: code=99 msg=error message"
    _fail "$line" "$match"
  )

  ## yay, tests completed!
  printf "Tests Complete: No Error!\n"
  return 0
}

_testZFSReplicate
