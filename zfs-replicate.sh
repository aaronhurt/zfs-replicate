#!/usr/bin/env bash
## zfs-replicate.sh
set -e -o pipefail

############################################
##### warning gremlins live below here #####
############################################

## output log files in decreasing age order
sortLogs() {
  ## check if file logging is enabled
  if [[ -z "$LOG_BASE" ]] || [[ ! -d "$LOG_BASE" ]]; then
    return
  fi
  ## find existing logs
  local logs=()
  for log in $("$FIND" "$LOG_BASE" -maxdepth 1 -type f -name autorep-\*); do
    ## get file change time via stat (platform specific)
    local fstat
    case "$(uname -s)" in
      Linux | SunOS)
        fstat=$(stat -c %Z "$log")
        ;;
      *)
        fstat=$(stat -f %c "$log")
        ;;
    esac
    ## append logs to array with creation time
    logs+=("${fstat}\t${log}")
  done
  ## output logs in descending age order
  for log in $(printf "%b\n" "${logs[@]}" | sort -rn | cut -f2); do
    printf "%s\n" "$log"
  done
}

## check log count and delete old logs
pruneLogs() {
  local logs
  mapfile -t logs < <(sortLogs)
  ## check count and delete old logs
  if [[ "${#logs[@]}" -gt "$LOG_KEEP" ]]; then
    printf "pruning logs %s\n" "${logs[*]:${LOG_KEEP}}"
    rm -rf "${logs[@]:${LOG_KEEP}}"
  fi
}

## delete lock files
clearLock() {
  local lockFile=$1
  if [ -f "$lockFile" ]; then
    printf "deleting lockfile %s\n" "$lockFile"
    rm "$lockFile"
  fi
}

## exit and cleanup
exitClean() {
  local exitCode=${1:-0} extraMsg=$2 logMsg status="success"
  ## set status to warning if we skipped any datasets
  if [[ $__SKIP_COUNT -gt 0 ]]; then
    status="WARNING"
  fi
  printf -v logMsg "%s total sets %d skipped %d" "$status" "$__PAIR_COUNT" "$__SKIP_COUNT"
  ## build and print error message
  if [[ $exitCode -ne 0 ]]; then
    status="ERROR"
    printf -v logMsg "%s: operation exited unexpectedly: code=%d" "$status" "$exitCode"
    if [[ -n "$extraMsg" ]]; then
      printf -v logMsg "%s msg=%s" "$logMsg" "$extraMsg"
    fi
  fi
  ## append extra message if available
  if [[ $exitCode -eq 0 ]] && [[ -n "$extraMsg" ]]; then
    printf -v logMsg "%s: %s" "$logMsg" "$extraMsg"
  fi
  ## cleanup old logs and clear locks
  pruneLogs
  clearLock "${TMPDIR}"/.replicate.snapshot.lock
  clearLock "${TMPDIR}"/.replicate.send.lock
  ## print log message and exit
  printf "%s\n" "$logMsg"
  exit "$exitCode"
}

## lockfile creation and maintenance
checkLock() {
  local lockFile=$1
  ## check our lockfile status
  if [[ -f "$lockFile" ]]; then
    ## see if this pid is still running
    local ps
    if ps=$(pgrep -lx -F "$lockFile"); then
      ## looks like it's still running
      printf "ERROR: script is already running as: %s\n" "$ps"
    else
      ## stale lock file?
      printf "ERROR: stale lockfile %s\n" "$lockFile"
    fi
    ## cleanup and exit
    exitClean 128 "confirm script is not running and delete lockfile $lockFile"
  else
    ## well no lockfile..let's make a new one
    printf "creating lockfile %s\n" "$lockFile"
    printf "%d\n" "$$" > "$lockFile"
  fi
}

## check remote host status
checkHost() {
  ## do we have a host check defined
  if [[ -z "$HOST_CHECK" ]]; then
    return
  fi
  local host=$1 cmd=()
  ## substitute host
  read -r -a cmd <<< "${HOST_CHECK//%HOST%/$host}"
  printf "checking host cmd=%s\n" "${cmd[*]}"
  ## run the check
  if ! "${cmd[@]}" > /dev/null 2>&1; then
    exitClean 128 "host check failed"
  fi
}

## ensure dataset exists
checkDataset() {
  local set=$1 host=$2 cmd=()
  ## build command
  if [[ -n "$host" ]]; then
    read -r -a cmd <<< "$SSH"
    cmd+=("$host")
  fi
  cmd+=("$ZFS" "list" "-H" "-o" "name" "$set")
  printf "checking dataset cmd=%s\n" "${cmd[*]}"
  ## execute command
  if ! "${cmd[@]}"; then
    exitClean 128 "failed to list dataset: ${set}"
  fi
}

## small wrapper around zfs destroy
snapDestroy() {
  local snap=$1 host=$2 cmd=()
  ## build command
  if [[ -n "$host" ]]; then
    read -r -a cmd <<< "$SSH"
    cmd+=("$host")
  fi
  cmd+=("$ZFS" "destroy")
  if [[ $RECURSE_CHILDREN -eq 1 ]]; then
    cmd+=("-r")
  fi
  cmd+=("$snap")
  printf "destroying snapshot cmd=%s\n" "${cmd[*]}"
  ## ignore error from destroy and count on logging to alert the end-user
  ## destroying recursive snapshots can lead to "snapshot not found" errors
  "${cmd[@]}" || true
}

## main replication function
snapSend() {
  local base=$1 snap=$2 src=$3 srcHost=$4 dst=$5 dstHost=$6 cmd=() pipe=()
  ## check our send lockfile
  checkLock "${TMPDIR}/.replicate.send.lock"
  ## begin building send command
  if [[ -n "$srcHost" ]]; then
    read -r -a cmd <<< "$SSH"
    cmd+=("$srcHost")
  fi
  cmd+=("$ZFS" "send" "-Rs")
  ## if first snap name is not empty generate an incremental
  if [ -n "$base" ]; then
    cmd+=("-I" "$base")
  fi
  cmd+=("${src}@${snap}")
  ## set destination pipe based on destination host
  read -r -a pipe <<< "$DEST_PIPE_WITHOUT_HOST"
  if [[ -n "$dstHost" ]]; then
    read -r -a pipe <<< "${DEST_PIPE_WITH_HOST//%HOST%/$dstHost}"
  fi
  pipe+=("$dst")
  printf "sending snapshot cmd=%s | %s\n" "${cmd[*]}" "${pipe[*]}"
  ## execute send and check return
  if ! "${cmd[@]}" | "${pipe[@]}"; then
    snapDestroy "${src}@${name}" "$srcHost"
    exitClean 128 "failed to send snapshot: ${src}@${name}"
  fi
  ## clear lockfile
  clearLock "${TMPDIR}/.replicate.send.lock"
}

## list replication snapshots
snapList() {
  local set=$1 host=$2 depth=${3:-0} cmd=() snaps snap
  ## build send command
  if [[ -n "$host" ]]; then
    read -r -a cmd <<< "$SSH"
    cmd+=("$host")
  fi
  cmd+=("$ZFS" "list" "-Hr" "-o" "name" "-s" "creation" "-t" "snapshot")
  if [[ $depth -gt 0 ]]; then
    cmd+=("-d" "$depth")
  fi
  cmd+=("$set")
  ## get snapshots from host
  if ! snaps="$("${cmd[@]}")"; then
    exitClean 128 "failed to list snapshots for dataset: ${set}"
  fi
  ## filter snaps matching our pattern
  for snap in $snaps; do
    if [[ "$snap" == *"@autorep-"* ]]; then
      printf "%s\n" "$snap"
    fi
  done
}

## create and manage source snapshots
snapCreate() {
  ## make sure we aren't ever creating simultaneous snapshots
  checkLock "${TMPDIR}/.replicate.snapshot.lock"
  ## set our snap name
  local name="autorep-${TAG}" temps="" tempa=() src dst pair
  ## generate snapshot list and cleanup old snapshots
  __PAIR_COUNT=0 __SKIP_COUNT=0 ## these are used in exitClean
  for pair in $REPLICATE_SETS; do
    ((__PAIR_COUNT++)) || true
    ## split dataset into source and destination parts and trim any trailing space
    read -r -a tempa <<< "${pair//:/ }"
    src="${tempa[0]}"
    src="${src%"${src##*[![:space:]]}"}"
    dst="${tempa[1]}"
    dst="${dst%"${dst##*[![:space:]]}"}"
    ## check for root dataset destination
    if [[ "$ALLOW_ROOT_DATASETS" -ne 1 ]]; then
      if [[ "$dst" == "$(basename "$dst")" ]] || [[ "$dst" == "$(basename "$dst")/" ]]; then
        temps="replicating root datasets can lead to data loss - set 'ALLOW_ROOT_DATASETS=1' to disable warning"
        printf "WARNING: skipping replication set '%s' - %s\n" "$pair" "$temps"
        ((__SKIP_COUNT++)) || true
        continue
      fi
    fi
    ## look for host options on source and destination
    local srcHost dstHost
    if [[ "$src" == *@* ]]; then
      ## split and trim trailing spaces
      read -r -a tempa <<< "${src//@/ }"
      src="${tempa[0]}"
      src="${src%"${src##*[![:space:]]}"}"
      srcHost="${tempa[1]}"
      srcHost="${srcHost%"${srcHost##*[![:space:]]}"}"
      checkHost "$srcHost" ## we only check the host once per set
    fi
    if [[ "$dst" == *@* ]]; then
      ## split and trim trailing spaces
      read -r -a tempa <<< "${dst//@/ }"
      dst="${tempa[0]}"
      dst="${dst%"${dst##*[![:space:]]}"}"
      dstHost="${tempa[1]}"
      dstHost="${dstHost%"${dstHost##*[![:space:]]}"}"
      checkHost "$dstHost" ## we only check the host once per set
    fi
    ## ensure datasets exist
    checkDataset "$src" "$srcHost"
    checkDataset "$dst" "$dstHost"
    ## get source and destination snapshots
    local srcSnaps dstSnaps
    mapfile -t srcSnaps < <(snapList "$src" "$srcHost" 1)
    mapfile -t dstSnaps < <(snapList "$dst" "$dstHost" 0)
    for snap in "${srcSnaps[@]}"; do
      ## while we are here...check for our current snap name
      if [[ "$snap" == "${src}@${name}" ]]; then
        ## looks like it's here...we better kill it
        printf "destroying duplicate snapshot: %s@%s\n" "$src" "$name"
        snapDestroy "${src}@${name}" "$srcHost"
      fi
    done
    ## set our base snap for incremental generation if src contains a sufficient
    ## number of snapshots and the base source snapshot exists in destination data set.
    local base
    if [[ ${#srcSnaps[@]} -ge 1 ]]; then
      ## set source snap base candidate
      ss="${srcSnaps[-1]}"
      ## split snap into fs and snap name
      read -r -a tempa <<< "${ss//@/ }"
      sn="${tempa[1]}"
      sn="${sn%"${sn##*[![:space:]]}"}"
      ## loop over base snaps and check for a match
      for snap in "${dstSnaps[@]}"; do
        read -r -a tempa <<< "${snap//@/ }"
        dn="${tempa[1]}"
        dn="${dn%"${dn##*[![:space:]]}"}"
        if [[ "$dn" == "$sn" ]]; then
          base="$ss"
        fi
      done
      ## no matching base, are we allowed to fallback?
      if [[ -z "$base" ]] && [[ ${#dstSnaps[@]} -ge 1 ]] && [[ $ALLOW_RECONCILIATION -ne 1 ]]; then
        printf -v temps "source snapshot '%s' not in destination dataset: %s" "${srcSnaps[-1]}" "$dst"
        printf -v temps "%s - set 'ALLOW_RECONCILIATION=1' to fallback to a full send" "$temps"
        printf "WARNING: skipping replication set '%s' - %s\n" "$pair" "$temps"
        ((__SKIP_COUNT++)) || true
        continue
      fi
    fi
    ## without a base snapshot, the destination must be clean
    if [[ -z "$base" ]] && [[ ${#dstSnaps[@]} -gt 0 ]]; then
      ## allowed to prune remote dataset?
      if [[ $ALLOW_RECONCILIATION -ne 1 ]]; then
        temps="destination contains snapshots not in source - set 'ALLOW_RECONCILIATION=1' to prune snapshots"
        printf "WARNING: skipping replication set '%s' - %s\n" "$pair" "$temps"
        ((__SKIP_COUNT++)) || true
        continue
      fi
      ## prune destination snapshots
      printf "pruning destination snapshots: %s\n" "${dstSnaps[*]}"
      for snap in "${dstSnaps[@]}"; do
        snapDestroy "$snap" "$dstHost"
      done
    fi
    ## cleanup old snapshots
    local idx
    for idx in "${!srcSnaps[@]}"; do
      if [[ ${#srcSnaps[@]} -ge $SNAP_KEEP ]]; then
        ## snaps are sorted above by creation in ascending order
        printf "found old snapshot %s\n" "${srcSnaps[idx]}"
        snapDestroy "${srcSnaps[idx]}" "$srcHost"
        unset 'srcSnaps[idx]'
      fi
    done
    ## come on already...make that snapshot
    if [[ -n "$srcHost" ]]; then
      read -r -a cmd <<< "$SSH"
      cmd+=("$srcHost")
    fi
    cmd+=("$ZFS" "snapshot")
    ## check if we are supposed to be recursive
    if [[ $RECURSE_CHILDREN -eq 1 ]]; then
      cmd+=("-r")
    fi
    cmd+=("$src@$name")
    printf "taking snapshot cmd=%s\n" "${cmd[*]}"
    if ! "${cmd[@]}"; then
      exitClean 128 "failed to create snapshot: ${src}@${name}"
    fi
    ## send snapshot to destination
    snapSend "$base" "$name" "$src" "$srcHost" "$dst" "$dstHost"
  done
  ## clear our lockfile
  clearLock "${TMPDIR}/.replicate.snapshot.lock"
}

## handle logging to file or syslog
writeLog() {
  local line=$1 logf="/dev/null"
  ## if a log base and file has been configured set them
  if [[ -n "$LOG_BASE" ]] && [[ -n "$LOG_FILE" ]]; then
    logf="${LOG_BASE}/${LOG_FILE}"
  fi
  ## always print to stdout and copy to logfile if set
  printf "%s %s[%d]: %s\n" "$(date '+%b %d %T')" "$SCRIPT" "$$" "$line" | tee -a "$logf"
  ## if syslog has been enabled write to syslog via logger
  if [[ -n "$SYSLOG" ]] && [[ "$SYSLOG" -eq 1 ]] && [[ -n "$LOGGER" ]]; then
    $LOGGER -p "${SYSLOG_FACILITY}.info" -t "$SCRIPT" "$line"
  fi
}

## read from stdin till script exit
captureOutput() {
  local line
  while IFS= read -r line; do
    writeLog "$line"
  done
}

## perform macro substitution for tags
subTags() {
  local m=$1
  ## do the substitutions
  m=${m//%DOW%/${DATE_MACROS[DOW]}}
  m=${m//%DOM%/${DATE_MACROS[DOM]}}
  m=${m//%MOY%/${DATE_MACROS[MOY]}}
  m=${m//%CYR%/${DATE_MACROS[CYR]}}
  m=${m//%NOW%/${DATE_MACROS[NOW]}}
  m=${m//%TAG%/$TAG}
  printf "%s\n" "$m"
}

## dump latest log to stdout and exit
showStatus() {
  local logs
  mapfile -t logs < <(sortLogs)
  if [[ -n "${logs[0]}" ]]; then
    printf "Last output from %s:\n%s\n" "$SCRIPT" "$(cat "${logs[0]}")"
  else
    printf "Unable to find most recent log file, cannot print status."
  fi
  exit 0
}

## show usage and exit
showHelp() {
  printf "Usage: %s [options] [config]\n\n" "${BASH_SOURCE[0]}"
  printf "Bash script to automate ZFS Replication\n\n"
  printf "Options:\n"
  printf "  -c, --config <configFile>    bash configuration file\n"
  printf "  -s, --status                 print most recent log messages to stdout\n"
  printf "  -h, --help                   show this message\n"
  exit 0
}

## load configuration defaults, parse flags, config, and environment
## captureOutput is not running yet, so use writeLog directly in loadConfig
loadConfig() {
  ## set SCRIPT used by writeLog and showStatus
  SCRIPT="$(basename "${BASH_SOURCE[0]}")"
  readonly SCRIPT
  ## local variables only used in loadConfig
  local status=0 configFile opt OPTARG OPTIND line
  ## read command line flags
  while getopts ":shc:-:" opt; do
    if [[ "$opt" == "-" ]]; then
      opt="${OPTARG%%=*}"                  # extract long option name
      opt="${opt#"${opt%%[![:space:]]*}"}" # remove leading whitespace characters
      opt="${opt%"${opt##*[![:space:]]}"}" # remove trailing whitespace characters
      OPTARG="${OPTARG#"$opt"}"            # extract long option argument (may be empty)
      OPTARG="${OPTARG#=}"                 # if long option argument, remove assigning `=`
    fi
    case "$opt" in
      c | config)
        configFile="${OPTARG}"
        ;;
      s | status)
        status=1
        ;;
      h | help)
        showHelp
        ;;
      \?) # bad short option
        writeLog "ERROR: illegal option -${OPTARG}" && exit 1
        ;;
      *) # bad long option
        writeLog "ERROR: illegal option --${opt}" && exit 1
        ;;
    esac
  done
  # remove parsed options and args from $@ list
  shift $((OPTIND - 1))
  ## allow config file to be passed as argument without a flag for backwards compat
  [[ -z "$configFile" ]] && configFile=$1
  ## attempt to load configuration
  if [[ -f "$configFile" ]]; then
    writeLog "sourcing config file $configFile"
    # shellcheck disable=SC1090
    source "$configFile"
  elif configFile="$(dirname "${BASH_SOURCE[0]}")/config.sh" && [[ -f "$configFile" ]]; then
    writeLog "sourcing config file $configFile"
    # shellcheck disable=SC1090
    source "$configFile"
  else
    writeLog "loading configuration from defaults and environmental settings."
  fi
  declare -A DATE_MACROS=(
    ["DOW"]=$(date "+%a") ["DOM"]=$(date "+%d") ["MOY"]=$(date "+%m")
    ["CYR"]=$(date "+%Y") ["NOW"]=$(date "+%s")
  )
  readonly DATE_MACROS
  readonly TMPDIR=${TMPDIR:-"/tmp"}
  readonly REPLICATE_SETS ## no default value
  readonly ALLOW_ROOT_DATASETS=${ALLOW_ROOT_DATASETS:-0}
  readonly ALLOW_RECONCILIATION=${ALLOW_RECONCILIATION:-0}
  readonly RECURSE_CHILDREN=${RECURSE_CHILDREN:-0}
  readonly SNAP_KEEP=${SNAP_KEEP:-2}
  readonly SYSLOG=${SYSLOG:-1}
  readonly SYSLOG_FACILITY=${SYSLOG_FACILITY:-"user"}
  TAG=${TAG:-"%MOY%%DOM%%CYR%_%NOW%"}
  TAG=$(subTags "$TAG")
  readonly TAG
  LOG_FILE=${LOG_FILE:-"autorep-%TAG%.log"}
  LOG_FILE=$(subTags "$LOG_FILE")
  readonly LOG_FILE
  readonly LOG_KEEP=${LOG_KEEP:-5}
  readonly LOG_BASE ## no default value
  readonly LOGGER=${LOGGER:-$(which logger)}
  readonly FIND=${FIND:-$(which find)}
  readonly ZFS=${ZFS:-$(which zfs)}
  readonly SSH=${SSH:-$(which ssh)}
  readonly DEST_PIPE_WITH_HOST=${DEST_PIPE_WITH_HOST:-"$SSH %HOST% $ZFS receive -vFd"}
  readonly DEST_PIPE_WITHOUT_HOST=${DEST_PIPE_WITHOUT_HOST:-"$ZFS receive -vFd"}
  readonly HOST_CHECK=${HOST_CHECK:-"ping -c1 -q -W2 %HOST%"}
  ## check configuration
  if [[ -n "$LOG_BASE" ]] && [[ ! -d "$LOG_BASE" ]]; then
    mkdir -p "$LOG_BASE"
  fi
  if [[ -z "$REPLICATE_SETS" ]]; then
    writeLog "ERROR: missing required setting REPLICATE_SETS" && exit 1
  fi
  if [[ -z "$ZFS" ]]; then
    writeLog "ERROR: unable to locate system zfs binary" && exit 1
  fi
  if [[ $SNAP_KEEP -lt 2 ]]; then
    writeLog "ERROR: a minimum of 2 snapshots are required for incremental sending" && exit 1
  fi
  ## show status if toggled
  if [[ $status -eq 1 ]]; then
    showStatus
  fi
}

## it all starts here...
main() {
  ## do snapshots and send
  snapCreate
  ## that's it, sending is called from doSnap
  exitClean 0
}

## start main if we weren't sourced
[[ "$0" == "${BASH_SOURCE[0]}" ]] && loadConfig "$@" && main 2>&1 | captureOutput
