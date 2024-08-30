#!/usr/bin/env sh
## zfs-replicate.sh
set -e

############################################
##### warning gremlins live below here #####
############################################

## output log files in decreasing age order
sortLogs() {
  ## check if file logging is enabled
  if [ -z "$LOG_BASE" ] || [ ! -d "$LOG_BASE" ]; then
    return
  fi
  ## find existing logs
  logs=$(find "$LOG_BASE" -maxdepth 1 -type f -name 'autorep-*')
  ## get file change time via stat (platform specific)
  if [ "$(uname -s)" = "Linux" ] || [ "$(uname -s)" = "SunOS" ]; then
    fstat='stat -c %Z'
  else
    fstat='stat -f %c'
  fi
  ## output logs in descending age order
  for log in $logs; do
    printf "%s\t%s\n" "$($fstat "$log")" "$log"
  done | sort -rn | cut -f2
}

## check log count and delete old logs
pruneLogs() {
  logs=$(sortLogs)
  logCount=0
  if [ -n "$logs" ]; then
    logCount=$(printf "%s" "$logs" | wc -l)
  fi
  if [ "$logCount" -gt "$LOG_KEEP" ]; then
    prune="$(echo "$logs" | sed -n "$((LOG_KEEP + 1)),\$p")"
    printf "pruning %d logs\n" "$((logCount - LOG_KEEP + 1))"
    echo "$prune" | xargs rm -vf
  fi
}

## delete lock files
clearLock() {
  lockFile=$1
  if [ -f "$lockFile" ]; then
    printf "deleting lockfile %s\n" "$lockFile"
    rm "$lockFile"
  fi
}

## exit and cleanup
exitClean() {
  exitCode=${1:-0}
  extraMsg=$2
  status="success"
  ## set status to warning if we skipped any datasets
  if [ "$__SKIP_COUNT" -gt 0 ]; then
    status="WARNING"
  fi
  logMsg=$(printf "%s total sets %d skipped %d" "$status" "$__PAIR_COUNT" "$__SKIP_COUNT")
  ## build and print error message
  if [ "$exitCode" -ne 0 ]; then
    status="ERROR"
    logMsg=$(printf "%s: operation exited unexpectedly: code=%d" "$status" "$exitCode")
    if [ -n "$extraMsg" ]; then
      logMsg=$(printf "%s msg=%s" "$logMsg" "$extraMsg")
    fi
  fi
  ## append extra message if available
  if [ "$exitCode" -eq 0 ] && [ -n "$extraMsg" ]; then
    logMsg=$(printf "%s: %s" "$logMsg" "$extraMsg")
  fi
  ## cleanup old logs and clear locks
  pruneLogs
  clearLock "${TMPDIR}/.replicate.snapshot.lock"
  clearLock "${TMPDIR}/.replicate.send.lock"
  ## print log message and exit
  printf "%s\n" "$logMsg"
  exit "$exitCode"
}

## lockfile creation and maintenance
checkLock() {
  lockFile=$1
  ## check our lockfile status
  if [ -f "$lockFile" ]; then
    ## see if this pid is still running
    if ps -p "$(cat "$lockFile")" > /dev/null 2>&1; then
      ## looks like it's still running
      printf "ERROR: script is already running as: %d\n" "$(cat "$lockFile")"
    else
      ## stale lock file?
      printf "ERROR: stale lockfile %s\n" "$lockFile"
    fi
    ## cleanup and exit
    exitClean 128 "confirm script is not running and delete lockfile $lockFile"
  fi
  ## well no lockfile..let's make a new one
  printf "creating lockfile %s\n" "$lockFile"
  printf "%d\n" "$$" > "$lockFile"
}

## check remote host status
checkHost() {
  ## do we have a host check defined
  if [ -z "$HOST_CHECK" ]; then
    return
  fi
  host=$1
  cmd=$(echo "$HOST_CHECK" | sed "s/%HOST%/$host/g")
  printf "checking host cmd=%s\n" "$cmd"
  ## run the check
  if ! $cmd > /dev/null 2>&1; then
    exitClean 128 "host check failed"
  fi
}

## ensure dataset exists
checkDataset() {
  set=$1
  host=$2
  cmd=""
  ## build command
  if [ -n "$host" ]; then
    cmd="$SSH $host "
  fi
  cmd="$cmd$ZFS list -H -o name $set"
  printf "checking dataset cmd=%s\n" "$cmd"
  ## execute command
  if ! $cmd; then
    exitClean 128 "failed to list dataset: $set"
  fi
}

## small wrapper around zfs destroy
snapDestroy() {
  snap=$1
  host=$2
  cmd=""
  ## build command
  if [ -n "$host" ]; then
    cmd="$SSH $host "
  fi
  cmd="$cmd$ZFS destroy"
  if [ "$RECURSE_CHILDREN" -eq 1 ]; then
    cmd="$cmd -r"
  fi
  cmd="$cmd $snap"
  printf "destroying snapshot cmd=%s\n" "$cmd"
  ## ignore error from destroy and count on logging to alert the end-user
  ## destroying recursive snapshots can lead to "snapshot not found" errors
  $cmd || true
}

## main replication function
snapSend() {
  base=$1
  snap=$2
  src=$3
  srcHost=$4
  dst=$5
  dstHost=$6
  ## check our send lockfile
  checkLock "${TMPDIR}/.replicate.send.lock"
  ## begin building send command
  cmd=""
  if [ -n "$srcHost" ]; then
    cmd="$SSH $srcHost "
  fi
  cmd="$cmd$ZFS send -Rs"
  ## if first snap name is not empty generate an incremental
  if [ -n "$base" ]; then
    cmd="$cmd -I $base"
  fi
  cmd="$cmd ${src}@${snap}"
  ## set destination pipe based on destination host
  pipe="$DEST_PIPE_WITHOUT_HOST"
  if [ -n "$dstHost" ]; then
    pipe=$(echo "$DEST_PIPE_WITH_HOST" | sed "s/%HOST%/$dstHost/g")
  fi
  pipe="$pipe $dst"
  printf "sending snapshot cmd=%s | %s\n" "$cmd" "$pipe"
  ## execute send and check return
  if ! $cmd | $pipe; then
    snapDestroy "${src}@${name}" "$srcHost"
    exitClean 128 "failed to send snapshot: ${src}@${name}"
  fi
  ## clear lockfile
  clearLock "${TMPDIR}/.replicate.send.lock"
}

## list replication snapshots
snapList() {
  set=$1
  host=$2
  depth=${3:-0}
  cmd=""
  ## build send command
  if [ -n "$host" ]; then
    cmd="$SSH $host "
  fi
  cmd="$cmd$ZFS list -Hr -o name -s creation -t snapshot"
  if [ "$depth" -gt 0 ]; then
    cmd="$cmd -d $depth"
  fi
  cmd="$cmd $set"
  ## get snapshots from host
  if ! snaps=$($cmd); then
    exitClean 128 "failed to list snapshots for dataset: $set"
  fi
  ## filter snaps matching our pattern
  echo "$snaps" | grep "@autorep-" || true
}

## helper function to check if substring is within string
contains() {
  string="$1"
  substring="$2"
  if [ "${string#*"$substring"}" != "$string" ]; then
    return 0
  fi
  return 1
}

## create and manage source snapshots
snapCreate() {
  ## make sure we aren't ever creating simultaneous snapshots
  checkLock "${TMPDIR}/.replicate.snapshot.lock"
  ## set our snap name
  name="autorep-${TAG}"
  ## generate snapshot list and cleanup old snapshots
  for pair in $REPLICATE_SETS; do
    __PAIR_COUNT=$((__PAIR_COUNT + 1))
    ## split dataset into source and destination parts and trim any trailing space
    src=$(echo "$pair" | cut -f1 -d: | sed 's/[[:space:]]*$//')
    dst=$(echo "$pair" | cut -f2 -d: | sed 's/[[:space:]]*$//')
    ## check for root dataset destination
    if [ "$ALLOW_ROOT_DATASETS" -ne 1 ]; then
      if [ "$dst" = "$(basename "$dst")" ] || [ "$dst" = "$(basename "$dst")/" ]; then
        temps="replicating root datasets can lead to data loss - set ALLOW_ROOT_DATASETS=1 to override"
        printf "WARNING: %s\n" "$temps"
        __SKIP_COUNT=$((__SKIP_COUNT + 1))
        continue
      fi
    fi
    ## look for host options on source
    if contains "$src" "@"; then
      srcHost=$(echo "$src" | cut -f2 -d@)
      src=$(echo "$src" | cut -f1 -d@)
    fi
    ## look for host options on destination
    if contains "$dst" "@"; then
      dstHost=$(echo "$dst" | cut -f2 -d@)
      dst=$(echo "$dst" | cut -f1 -d@)
    fi
    ## check source and destination datasets
    checkDataset "$src" "$srcHost"
    checkDataset "$dst" "$dstHost"
    ## get source and destination snapshots
    srcSnaps=$(snapList "$src" "$srcHost" 1)
    dstSnaps=$(snapList "$dst" "$dstHost" 0)
    for snap in $srcSnaps; do
      ## while we are here...check for our current snap name
      if [ "$snap" = "${src}@${name}" ]; then
        ## looks like it's here...we better kill it
        printf "destroying duplicate snapshot: %s@%s\n" "$src" "$name"
        snapDestroy "${src}@${name}" "$srcHost"
      fi
    done
    ## get source and destination snap count
    srcSnapCount=0
    dstSnapCount=0
    if [ -n "$srcSnaps" ]; then
      srcSnapCount=$(printf "%s\n" "$srcSnaps" | wc -l)
    fi
    if [ -n "$dstSnaps" ]; then
      dstSnapCount=$(printf "%s\n" "$dstSnaps" | wc -l)
    fi
    ## set our base snap for incremental generation if src contains a sufficient
    ## number of snapshots and the base source snapshot exists in destination dataset
    base=""
    if [ "$srcSnapCount" -ge 1 ]; then
      ## get most recent source snapshot
      ss=$(printf "%s\n" "$srcSnaps" | tail -n 1)
      ## get source snapshot name
      sn=$(echo "$ss" | cut -f2 -d@)
      ## loop over destinations snaps and look for a match
      for ds in $dstSnaps; do
        dn=$(echo "$ds" | cut -f2 -d@)
        if [ "$dn" = "$sn" ]; then
          base="$ss"
        fi
      done
      ## no matching base, are we allowed to fallback?
      if [ -z "$base" ] && [ "$dstSnapCount" -ge 1 ] && [ "$ALLOW_RECONCILIATION" -ne 1 ]; then
        temps=$(printf "source snapshot '%s' not in destination dataset: %s" "$ss" "$dst")
        temps=$(printf "%s - set 'ALLOW_RECONCILIATION=1' to fallback to a full send" "$temps")
        printf "WARNING: skipping replication set '%s' - %s\n" "$pair" "$temps"
        __SKIP_COUNT=$((__SKIP_COUNT + 1))
        continue
      fi
    fi
    ## without a base snapshot, the destination must be clean
    if [ -z "$base" ] && [ "$dstSnapCount" -gt 0 ]; then
      ## allowed to prune remote dataset?
      if [ "$ALLOW_RECONCILIATION" -ne 1 ]; then
        temps="destination contains snapshots not in source - set 'ALLOW_RECONCILIATION=1' to prune snapshots"
        printf "WARNING: skipping replication set '%s' - %s\n" "$pair" "$temps"
        __SKIP_COUNT=$((__SKIP_COUNT + 1))
        continue
      fi
      ## prune destination snapshots
      printf "pruning destination snapshots: %s\n" "$dstSnaps"
      for snap in $dstSnaps; do
        snapDestroy "$snap" "$dstHost"
      done
    fi
    ## cleanup old snapshots
    if [ "$srcSnapCount" -ge "$SNAP_KEEP" ]; then
      ## snaps are sorted above by creation in ascending order
      echo "$srcSnaps" | sed -n "1,$((srcSnapCount - SNAP_KEEP))p" | while read -r snap; do
        printf "found old snapshot %s\n" "$snap"
        snapDestroy "$snap" "$srcHost"
      done
    fi
    ## build snapshot create command
    cmd=""
    if [ -n "$srcHost" ]; then
      cmd="$SSH $srcHost "
    fi
    cmd="$cmd$ZFS snapshot"
    ## check if we are supposed to be recursive
    if [ "$RECURSE_CHILDREN" -eq 1 ]; then
      cmd="$cmd -r"
    fi
    cmd="$cmd ${src}@${name}"
    ## come on already...take that snapshot
    printf "creating snapshot cmd=%s\n" "$cmd"
    if ! $cmd; then
      snapDestroy "${src}@${name}" "$srcHost"
      exitClean 128 "failed to create snapshot: ${src}@${name}"
    fi
    ## send snapshot to destination
    snapSend "$base" "$name" "$src" "$srcHost" "$dst" "$dstHost"
  done
  ## clear snapshot lockfile
  clearLock "${TMPDIR}/.replicate.snapshot.lock"
}

## handle logging to file or syslog
writeLog() {
  line=$1
  logf="/dev/null"
  ## if a log base and file has been configured set them
  if [ -n "$LOG_BASE" ] && [ -n "$LOG_FILE" ]; then
    logf="${LOG_BASE}/${LOG_FILE}"
  fi
  ## always print to stdout and copy to logfile if set
  printf "%s %s[%d]: %s\n" "$(date '+%b %d %T')" "$SCRIPT" "$$" "$line" | tee -a "$logf"
  ## if syslog has been enabled write to syslog via logger
  if [ -n "$SYSLOG" ] && [ "$SYSLOG" -eq 1 ] && [ -n "$LOGGER" ]; then
    $LOGGER -p "${SYSLOG_FACILITY}.info" -t "$SCRIPT" "$line"
  fi
}

## read from stdin till script exit
captureOutput() {
  while IFS= read -r line; do
    writeLog "$line"
  done
}

## perform macro substitution for tags
subTags() {
  m=$1
  ## do the substitutions
  m=$(echo "$m" | sed "s/%DOW%/${__DOW}/g")
  m=$(echo "$m" | sed "s/%DOM%/${__DOM}/g")
  m=$(echo "$m" | sed "s/%MOY%/${__MOY}/g")
  m=$(echo "$m" | sed "s/%CYR%/${__CYR}/g")
  m=$(echo "$m" | sed "s/%NOW%/${__NOW}/g")
  m=$(echo "$m" | sed "s/%TAG%/${TAG}/g")
  printf "%s\n" "$m"
}

## show last replication status
showStatus() {
  log=$(sortLogs | head -n 1)
  if [ -n "$log" ]; then
    printf "Last output from %s:\n%s\n" "$SCRIPT" "$(cat "${log}")"
  else
    printf "Unable to find most recent log file, cannot print status.\n"
  fi
  exit 0
}

## show usage and exit
showHelp() {
  printf "Usage: %s [options] [config]\n\n" "${SCRIPT}"
  printf "Bash script to automate ZFS Replication\n\n"
  printf "Options:\n"
  printf "  -c, --config <configFile>    bash configuration file\n"
  printf "  -s, --status                 print most recent log messages to stdout\n"
  printf "  -h, --help                   show this message\n"
  exit 0
}

## read and load config file
loadConfig() {
  ## set SCRIPT used by writeLog and showStatus
  readonly SCRIPT="${0##*/}"
  readonly SCRIPT_PATH="${0%/*}"
  configFile=""
  status=0
  ## process command-line options
  while [ $# -gt 0 ]; do
    case "$1" in
      -c | --config)
        configFile=$2
        shift
        ;;
      -s | --status)
        showStatus
        ;;
      -h | --help)
        showHelp
        ;;
      *) # bad long option
        writeLog "ERROR: illegal option ${1}" && exit 1
        ;;
    esac
    shift
  done
  ## attempt to load configuration
  if [ -f "$configFile" ]; then
    writeLog "sourcing config file $configFile"
    # shellcheck disable=SC1090
    . "$configFile"
  elif configFile="${SCRIPT_PATH}/config.sh" && [ -f "$configFile" ]; then
    writeLog "sourcing config file $configFile"
    # shellcheck disable=SC1090
    . "$configFile"
  else
    writeLog "loading configuration from defaults and environmental settings."
  fi
  ## set date substitutions for macros
  __DOW=$(date "+%a")
  readonly __DOW
  __DOM=$(date "+%d")
  readonly __DOM
  __MOY=$(date "+%m")
  readonly __MOY
  __CYR=$(date "+%Y")
  readonly __CYR
  __NOW=$(date "+%s")
  readonly __NOW
  ## complete configuration with values from environment or set defaults
  readonly TMPDIR="${TMPDIR:-"/tmp"}"
  readonly REPLICATE_SETS ## no default value
  readonly ALLOW_ROOT_DATASETS="${ALLOW_ROOT_DATASETS:-0}"
  readonly ALLOW_RECONCILIATION="${ALLOW_RECONCILIATION:-0}"
  readonly RECURSE_CHILDREN="${RECURSE_CHILDREN:-0}"
  readonly SNAP_KEEP="${SNAP_KEEP:-2}"
  readonly SYSLOG="${SYSLOG:-1}"
  readonly SYSLOG_FACILITY="${SYSLOG_FACILITY:-"user"}"
  TAG="${TAG:-"%MOY%%DOM%%CYR%_%NOW%"}"
  TAG="$(subTags "$TAG")"
  readonly TAG
  LOG_FILE="${LOG_FILE:-"autorep-%TAG%.log"}"
  LOG_FILE="$(subTags "$LOG_FILE")"
  readonly LOG_FILE
  readonly LOG_KEEP="${LOG_KEEP:-5}"
  readonly LOG_BASE ## no default value
  readonly LOGGER="${LOGGER:-$(which logger)}"
  readonly FIND="${FIND:-$(which find)}"
  readonly ZFS="${ZFS:-$(which zfs)}"
  readonly SSH="${SSH:-$(which ssh)}"
  readonly DEST_PIPE_WITH_HOST="${DEST_PIPE_WITH_HOST:-"$SSH %HOST% $ZFS receive -vFd"}"
  readonly DEST_PIPE_WITHOUT_HOST="${DEST_PIPE_WITHOUT_HOST:-"$ZFS receive -vFd"}"
  readonly HOST_CHECK="${HOST_CHECK:-"ping -c1 -q -W2 %HOST%"}"
  ## init values used in snapCreate and exitClean
  __PAIR_COUNT=0
  __SKIP_COUNT=0
  ## check configuration
  if [ -n "$LOG_BASE" ] && [ ! -d "$LOG_BASE" ]; then
    mkdir -p "$LOG_BASE"
  fi
  if [ -z "$REPLICATE_SETS" ]; then
    writeLog "ERROR: missing required setting REPLICATE_SETS" && exit 1
  fi
  if [ -z "$ZFS" ]; then
    writeLog "ERROR: unable to locate system zfs binary" && exit 1
  fi
  if [ "$SNAP_KEEP" -lt 2 ]; then
    writeLog "ERROR: a minimum of 2 snapshots are required for incremental sending" && exit 1
  fi
  ## show status if toggled
  if [ "$status" -eq 1 ]; then
    showStatus
  fi
}

main() {
  ## do snapshots and send
  snapCreate
  ## that's it, sending is called from doSnap
  exitClean 0
}

## process config and start main if we weren't sourced
if [ "${0##*/}" != "sh" ] && [ "${0##*/}" != "dash" ] && [ "${0##*/}" != "-bash" ]; then
  loadConfig "$@" && main 2>&1 | captureOutput
fi
