#!/usr/bin/env bash
## zfs-replicate.sh
set -e -o pipefail

############################################
##### warning gremlins live below here #####
############################################

## handle logging to file or syslog
writeLog() {
  local line
  read -r line
  ## always echo the line to stdout
  echo "$line"
  ## if a log base and file has been configured append log
  if [[ -n "$LOG_BASE" ]] && [[ -n "$LOG_FILE" ]]; then
    printf "%s %s: %s\n" "$(date "+%b %d %T")" "$SCRIPT" "$line" >> "${LOG_BASE}/${LOG_FILE}"
  fi
  ## if syslog has been enabled write to syslog via logger
  if [[ -n "$SYSLOG" ]] && [[ "$SYSLOG" -eq 1 ]] && [[ -n "$LOGGER" ]]; then
    $LOGGER -p "${SYSLOG_FACILITY}.info" -t "$SCRIPT" "$line"
  fi
}

## logging helper function
logit() {
  echo "$1" | writeLog
}

## logging helper function
logitf() {
  # shellcheck disable=SC2059
  # shellcheck disable=SC2145
  printf "$@" | writeLog
}

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
    logs+=("${fstat}\t${log}\n")
  done
  ## output logs in descending age order
  for log in $(echo -e "${logs[@]:0}" | sort -rn | cut -f2); do
    echo "$log"
  done
}

## check log count and delete old logs
pruneLogs() {
  local logs
  mapfile -t logs < <(sortLogs)
  ## check count and delete old logs
  if [[ "${#logs[@]}" -gt "$LOG_KEEP" ]]; then
    logitf "Deleting OLD logs: %s\n" "${logs[@]:${LOG_KEEP}}"
    rm -rf "${logs[@]:${LOG_KEEP}}"
  fi
}

## delete lock files
clearLock() {
  local lockFile=$1
  if [ -f "$lockFile" ]; then
    logitf "Deleting lockfile: %s\n" "$lockFile"
    rm "$lockFile"
  fi
}

## exit and cleanup
exitClean() {
  local exitCode=${1:-0} extraMsg=$2 logMsg status="SUCCESS"
  ## set status to warning if we skipped any datasets
  if [[ $__SKIP_COUNT -gt 0 ]]; then
    status="WARNING"
  fi
  logMsg=$(printf "%s: Total datasets: %d Skipped: %d" "$status" "$__PAIR_COUNT" "$__SKIP_COUNT")
  ## build and print error message
  if [[ $exitCode -ne 0 ]]; then
    status="ERROR"
    logMsg=$(printf "%s: Operation exited unexpectedly: code=%d" "$status" "$exitCode")
    if [[ -n "$extraMsg" ]]; then
      logMsg=$(printf "%s msg=%s" "$logMsg" "$extraMsg")
    fi
  fi
  ## append extra message if available
  if [[ $exitCode -eq 0 ]] && [[ -n "$extraMsg" ]]; then
    logMsg+=": $extraMsg"
  fi
  ## cleanup old logs and clear locks
  pruneLogs
  clearLock "${TMPDIR}"/.replicate.snapshot.lock
  clearLock "${TMPDIR}"/.replicate.send.lock
  ## print log message and exit
  logit "$logMsg"
  exit 0
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
      logitf "ERROR: Script is already running as: %s\n" "$ps"
    else
      ## stale lock file?
      logitf "ERROR: Stale lockfile: %s\n" "$lockFile"
    fi
    ## cleanup and exit
    exitClean 90 "confirm script is not running and delete lockfile: $lockFile"
  else
    ## well no lockfile..let's make a new one
    logitf "Creating lockfile: %s\n" "$lockFile"
    echo $$ > "$lockFile"
  fi
}

## check remote host status
checkHost() {
  ## do we have a host check defined
  if [[ -z "$HOST_CHECK" ]]; then
    return
  fi
  local host=$1 cmd
  ## substitute host
  cmd=${HOST_CHECK//%HOST%/$host}
  logitf "Checking host %s: %s\n" "$host" "$cmd"
  ## run the check
  if ! $cmd > /dev/null 2>&1; then
    exitClean 90 "host check '$cmd' failed!"
  fi
}

## small wrapper around zfs destroy
snapDestroy() {
  local snap=$1 host=$2 args prefix
  if [[ -n "$host" ]]; then
    prefix="$SSH $host "
  fi
  if [[ "$RECURSE_CHILDREN" -eq 1 ]]; then
    args="-r "
  fi
  logitf "Deleting snapshot: %s\n" "$snap"
  # shellcheck disable=SC2086
  $prefix$ZFS destroy $args"$snap"
}

## main replication function
snapSend() {
  local base=$1 snap=$2 src=$3 srcHost=$4 dst=$5 dstHost=$6
  ## check our send lockfile
  checkLock "${TMPDIR}/.replicate.send.lock"
  ## create initial send command based on arguments
  ## if first snap name is not empty generate an incremental
  local args="-R"
  if [ -n "$base" ]; then
    args="-R -I $base"
  fi
  ## set the command prefix based on source host
  local prefix
  if [[ -n "$srcHost" ]]; then
    prefix="$SSH $srcHost "
  fi
  ## set destination pipe based on destination host
  local pipe="$DEST_PIPE_WITHOUT_HOST"
  if [[ -n "$dstHost" ]]; then
    pipe=${DEST_PIPE_WITH_HOST//%HOST%/$dstHost}
  fi
  logitf "Sending snapshot %s@%s via %s %s\n" "$src" "$snap" "$pipe" "$dst"
  ## execute send and check return
  # shellcheck disable=SC2086
  if ! $prefix$ZFS send $args "${src}@${snap}" | $pipe "$dst"; then
    snapDestroy "${src}@${name}" "$srcHost"
    exitClean 30 "failed to send snapshot: ${src}@${name}"
  fi
  ## clear lockfile
  clearLock "${TMPDIR}/.replicate.send.lock"
}

## list replication snapshots
snapList() {
  local set=$1 host=$2 args prefix snaps snap
  ## limit depth to 1 if not recursive
  if [[ "$RECURSE_CHILDREN" -ne 1 ]]; then
    args="-d 1 "
  fi
  ## set prefix based on host
  if [[ -n "$host" ]]; then
    prefix="$SSH $host "
  fi
  ## get snapshots from host that match our pattern
  # shellcheck disable=SC2086
  mapfile -t snaps < <($prefix$ZFS list -Hr -o name -s creation -t snapshot "$set")
  ## filter snaps matching our pattern
  local idx
  for idx in "${!snaps[@]}"; do
    if [[ ${snaps[idx]} == *@autorep-* ]]; then
      echo "${snaps[idx]}"
    fi
  done
}

## create and manage source snapshots
snapCreate() {
  ## make sure we aren't ever creating simultaneous snapshots
  checkLock "${TMPDIR}/.replicate.snapshot.lock"
  ## set our snap name
  local name="autorep-${TAG}"
  ## generate snapshot list and cleanup old snapshots
  local pair
  __PAIR_COUNT=0 __SKIP_COUNT=0 ## these are used in exitClean
  for pair in $REPLICATE_SETS; do
    local src dst temps
    ((__PAIR_COUNT++)) || true
    ## split dataset into source and destination parts and trim trailing slashes
    mapfile -d " " -t temps <<< "${pair//:/ }"
    src="${temps[0]}"
    src="${src%"${src##*[![:space:]]}"}"
    dst="${temps[1]}"
    dst="${dst%"${dst##*[![:space:]]}"}"
    ## check for root datasets
    if [[ "$ALLOW_ROOT_DATASETS" -ne 1 ]]; then
      if [ "$src" == "$(basename "$src")" ] ||
        [ "$dst" == "$(basename "$dst")" ]; then
        logitf "WARNING: Replicating root datasets can lead to data loss.\n"
        logitf "To allow root dataset replication and disable this warning "
        logitf "set ALLOW_ROOT_DATASETS=1 in config or environment. Skipping: %s\n" "$pair"
        ((__SKIP_COUNT++)) || true
        continue
      fi
    fi
    ## look for host options on source and destination
    local srcHost dstHost temps
    if [[ "$src" == *@* ]]; then
      ## split and trim trailing spaces
      mapfile -d " " -t temps <<< "${src//@/ }"
      src="${temps[0]}"
      src="${src%"${src##*[![:space:]]}"}"
      srcHost="${temps[1]}"
      srcHost="${srcHost%"${srcHost##*[![:space:]]}"}"
      checkHost "$srcHost" ## we only check the host once per set
    fi
    if [[ "$dst" == *@* ]]; then
      ## split and trim trailing spaces
      mapfile -d " " -t temps <<< "${dst//@/ }"
      dst="${temps[0]}"
      dst="${dst%"${dst##*[![:space:]]}"}"
      dstHost="${temps[1]}"
      dstHost="${dstHost%"${dstHost##*[![:space:]]}"}"
      checkHost "$dstHost" ## we only check the host once per set
    fi
    ## get source and destination snapshots
    local srcSnaps dstSnaps snap
    mapfile -t srcSnaps < <(snapList "$src" "$srcHost")
    mapfile -t dstSnaps < <(snapList "$dst" "$dstHost")
    for snap in "${srcSnaps[@]}"; do
      ## while we are here...check for our current snap name
      if [[ "$snap" == "${src}@${name}" ]]; then
        ## looks like it's here...we better kill it
        logitf "Destroying DUPLICATE snapshot: %s@%s\n" "$src" "$name"
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
      mapfile -d " " -t temps <<< "${ss//@/ }"
      sn="${temps[1]}"
      sn="${sn%"${sn##*[![:space:]]}"}"
      ## loop over base snaps and check for a match
      for snap in "${dstSnaps[@]}"; do
        mapfile -d " " -t temps <<< "${snap//@/ }"
        dn="${temps[1]}"
        dn="${dn%"${dn##*[![:space:]]}"}"
        if [[ "$dn" == "$sn" ]]; then
          base="$ss"
        fi
      done
      ## no matching base, are we allowed to fallback?
      if [[ -z "$base" ]] && [[ $ALLOW_RECONCILIATION -ne 1 ]]; then
        logit "WARNING: Unable to find base snapshot '%s' in destination dataset: %s" "${srcSnaps[-1]}" "$dst"
        logitf "Set 'ALLOW_RECONCILIATION=1' to fallback to a full send. Skipping: %s\n" "$pair"
        ((__SKIP_COUNT++)) || true
        continue
      fi
    fi
    ## without a base snapshot, the destination must be clean
    if [[ -z "$base" ]] && [[ ${#dstSnaps[@]} -gt 0 ]]; then
      ## allowed to prune remote dataset?
      if [[ $ALLOW_RECONCILIATION -ne 1 ]]; then
        logitf "WARNING: Destination contains snapshots not in source."
        logitf "Set 'ALLOW_RECONCILIATION=1' to remove destination snapshots. Skipping: %s\n" "$pair"
        ((__SKIP_COUNT++)) || true
        continue
      fi
      ## prune destination snapshots
      logitf "Pruning destination snapshots: %s\n" "${dstSnaps[@]}"
      for snap in "${dstSnaps[@]}"; do
        snapDestroy "$snap" "$dstHost"
      done
    fi
    ## cleanup old snapshots
    local idx
    for idx in "${!srcSnaps[@]}"; do
      if [[ ${#srcSnaps[@]} -ge $SNAP_KEEP ]]; then
        ## snaps are sorted above by creation in ascending order
        logitf "Found OLD snapshot: %s\n" "${srcSnaps[idx]}"
        snapDestroy "${srcSnaps[idx]}" "$srcHost"
        unset 'srcSnaps[idx]'
      fi
    done
    ## set the command prefix based on source host
    local prefix
    if [[ -n "$srcHost" ]]; then
      prefix="$SSH $srcHost "
    fi
    ## check if we are supposed to be recursive
    local args
    if [[ $RECURSE_CHILDREN -eq 1 ]]; then
      args="-r "
    fi
    ## come on already...make that snapshot
    logitf "Creating source snapshot: %s@%s\n" "$src" "$name"
    # shellcheck disable=SC2086
    if ! $prefix$ZFS snapshot $args$src@$name; then
      exitClean 20 "failed to create snapshot: ${src}@${name}"
    fi
    ## send snapshot to destination
    snapSend "$base" "$name" "$src" "$srcHost" "$dst" "$dstHost"
  done
  ## clear our lockfile
  clearLock "${TMPDIR}/.snapshot.lock"
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
  echo "$m"
}

## dump latest log to stdout and exit
showStatus() {
  local logs
  mapfile -t logs < <(sortLogs)
  if [[ -n "${logs[0]}" ]]; then
    printf "Last output from %s:\n%s\n" "$SCRIPT" "$(cat "${logs[0]}")"
  else
    printf "Unable to find most recent logfile, cannot print status."
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
loadConfig() {
  ## read flags
  local status=0 configFile opt OPTARG OPTIND
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
        printf "%s: illegal option -%s\n" "${BASH_SOURCE[0]}" "$OPTARG" >&2
        exit 2
        ;;
      *) # bad long option
        printf "%s: illegal option --%s\n" "${BASH_SOURCE[0]}" "$opt" >&2
        exit 2
        ;;
    esac
  done
  # remove parsed options and args from $@ list
  shift $((OPTIND - 1))
  ## allow config file to be passed as argument without a flag for backwards compat
  [[ -z "$configFile" ]] && configFile=$1
  ## attempt to load configuration
  if [[ -f "$configFile" ]]; then
    logitf "Sourcing config file: %s\n" "$configFile"
    # shellcheck disable=SC1090
    source "$configFile"
  elif configFile="$(dirname "${BASH_SOURCE[0]}")/config.sh" && [[ -f "$configFile" ]]; then
    logitf "Sourcing config file: %s\n" "$configFile"
    # shellcheck disable=SC1090
    source "$configFile"
  else
    logitf "Loading configuration from defaults and environmental settings.\n"
  fi
  declare -A DATE_MACROS=(
    ["DOW"]=$(date "+%a") ["DOM"]=$(date "+%d") ["MOY"]=$(date "+%m")
    ["CYR"]=$(date "+%Y") ["NOW"]=$(date "+%s")
  )
  SCRIPT=$(basename "${BASH_SOURCE[0]}")
  readonly SCRIPT
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
    exitClean 10 "missing required setting: REPLICATE_SETS"
  fi
  if [[ -z "$ZFS" ]]; then
    exitClean 11 "unable to locate system zfs binary"
  fi
  if [[ $SNAP_KEEP -lt 2 ]]; then
    exitClean 12 "a minimum of 2 snaps are required for incremental sending"
  fi
  ## show status if toggled
  if [[ $status -eq 1 ]]; then
    showStatus
  fi
}

## it all starts here...
main() {
  ## load configuration
  loadConfig "$@"
  ## do snapshots and send
  snapCreate
  ## that's it, sending is called from doSnap
  exitClean 0
}

## start main if we weren't sourced
[[ "$0" == "${BASH_SOURCE[0]}" ]] && main "$@"
