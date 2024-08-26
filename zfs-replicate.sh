#!/usr/bin/env bash
## zfs-replicate.sh
set -e -o pipefail

############################################
##### warning gremlins live below here #####
############################################

## logging helper function
logit() {
  ## TODO finish file and syslog logging
  echo "zfs-replicate: $1"
}

## logging helper function
logitf() {
  ## TODO finish file and syslog logging
  # shellcheck disable=SC2059
  # shellcheck disable=SC2145
  printf "zfs-replicate: $@"
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
    logs+=("$fstat\t$log\n")
  done
  ## output logs in descending age order
  for log in $(echo -e "${logs[@]:0}" | sort -rn | cut -f2); do
    echo "$log"
  done
}

## check log count and delete old
pruneLogs() {
  local logs
  mapfile -t logs < <(sortLogs)
  ## check count and delete old logs
  if [[ "${#logs[@]}" -gt "$LOG_KEEP" ]]; then
    logitf "deleting old logs: %s ...\n" "${logs[@]:$LOG_KEEP}"
    rm -rf "${logs[@]:$LOG_KEEP}"
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
  local exitCode=${1:=0} errorMsg=$2
  local logMsg="SUCCESS: Operation completed normally."
  ## build and print error message
  if [[ $exitCode -ne 0 ]]; then
    logMsg=$(printf "ERROR: Operation exited unexpectedly: code=%d" "$exitCode")
    if [[ "$errorMsg" != "" ]]; then
      logMsg=$(printf "%s msg=%s" "$logMsg" "$errorMsg")
    fi
  fi
  ## check log files and clear locks
  pruneLogs
  clearLock "$TMPDIR"/.replicate.snapshot.lock
  clearLock "$TMPDIR"/.replicate.send.lock
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
    exitClean 99 "To run script please delete: $lockFile"
  else
    ## well no lockfile..let's make a new one
    logitf "Creating lockfile: %s\n" "$lockFile"
    echo $$ > "$lockFile"
  fi
}

## check remote host status
checkHost() {
  ## do we have a host check defined
  if [[ -z $HOST_CHECK ]]; then
    return
  fi
  local host=$1 cmd
  ## substitute host
  cmd=${HOST_CHECK//%HOST%/$host}
  logitf "Checking host %s via %s\n" "$host" "$cmd"
  ## run the check
  if ! $cmd > /dev/null 2>&1; then
    exitClean 99 "host check '$cmd' failed!"
  fi
}

## small wrapper around zfs destroy
snapDestroy() {
  local snap=$1
  local host=$2
  local args
  local prefix
  if [[ -n "$host" ]]; then
    prefix="$SSH $host "
  fi
  if [[ "$RECURSE_CHILDREN" -eq 1 ]]; then
    args="-r "
  fi
  logitf "Deleting source snapshot %s\n" "$snap"
  # shellcheck disable=SC2086
  $prefix$ZFS destroy $args"$snap"
}

## main replication function
snapSend() {
  local base=$1 snap=$2 src=$3 srcHost=$4 dst=$5 dstHost=$6
  ## check our send lockfile
  checkLock "$TMPDIR/.replicate.send.lock"
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
  logitf "Sending snapshots %s@%s via %s to %s\n" "$src" "$snap" "$pipe" "$dst"
  ## execute send and check return
  # shellcheck disable=SC2086
  if ! $prefix$ZFS send $args "$src@$snap" | $pipe "$dst"; then
    snapDestroy "$src" "$name" "$srcHost"
    logitf "ERROR: Failed to send snapshot %s@%s\n" "$src" "$snap"
  fi
  ## clear lockfile
  clearLock "$TMPDIR/.replicate.send.lock"
}

## create and manage source snapshots
snapCreate() {
  ## make sure we aren't ever creating simultaneous snapshots
  checkLock "$TMPDIR/.replicate.snapshot.lock"
  ## set our snap name
  local name="autorep-$TAG"
  ## generate snapshot list and cleanup old snapshots
  for pair in $REPLICATE_SETS; do
    local src dst
    ## split dataset into source and destination parts and trim trailing slashes
    src=$(echo "$pair" | cut -f1 -d: | sed 's/\/*$//')
    dst=$(echo "$pair" | cut -f2 -d: | sed 's/\/*$//')
    ## check for root datasets
    if [[ "$ALLOW_ROOT_DATASETS" -ne 1 ]]; then
      if [ "$src" == "$(basename "$src")" ] ||
        [ "$dst" == "$(basename "$dst")" ]; then
        logitf "WARNING: Replicating root datasets can lead to data loss.\n"
        logitf "To allow root dataset replication and disable this warning "
        logitf "set ALLOW_ROOT_DATASETS=1 in config or environment. Skipping: %s\n\n" "$pair"
        ## skip this set
        continue
      fi
    fi
    ## look for host options on source and destination
    local srcHost dstHost
    if [[ "$src" == *@* ]]; then
      srcHost=$(echo "$src" | cut -f2 -d@)
      checkHost "$srcHost" ## we only check the host once per set
      src=$(echo "$src" | cut -f1 -d@)
    fi
    if [[ "$dst" == *@* ]]; then
      dstHost=$(echo "$dst" | cut -f2 -d@)
      checkHost "$dstHost" ## we only check the host once per set
      dst=$(echo "$dst" | cut -f1 -d@)
    fi
    ## set the command prefix based on source host
    local prefix
    if [[ -n "$srcHost" ]]; then
      prefix="$SSH $srcHost "
    fi
    ## get existing source snapshots that look like they were made by this script
    local args temps
    if [[ "$RECURSE_CHILDREN" -ne 1 ]]; then
      args="-d 1 "
    fi
    # shellcheck disable=SC2086
    temps=$($prefix$ZFS list -Hr -o name -s creation -t snapshot $args$src | grep "$src\@autorep-" || true)
    ## our snapshot array
    local snaps
    declare -a snaps=()
    for sn in $temps; do
      ## while we are here...check for our current snap name
      if [[ "$sn" == "$src@$name" ]]; then
        ## looks like it's here...we better kill it
        logitf "Destroying DUPLICATE snapshot %s@%s\n" "$src" "$name"
        snapDestroy "$src@$name" "$srcHost"
      else
        ## add this snapshot to the array
        snaps+=("$sn")
      fi
    done
    ## init counting index and get snap count
    local index=0 count=${#snaps[@]}
    ## set our base snap for incremental generation below
    local base
    if [[ $count -ge 1 ]]; then
      base=${snaps[$count - 1]}
    fi
    ## how many snapshots did we end up with..
    if [[ $count -ge $SNAP_KEEP ]]; then
      ## cleanup old snapshots
      while [[ $count -ge $SNAP_KEEP ]]; do
        ## snaps are sorted above by creation in ascending order
        logitf "Destroying OLD snapshot %s\n" "${snaps[index]}"
        snapDestroy "${snaps[index]}" "$srcHost"
        ## decrease count and increase index
        ((count--))
        ((index++)) || true
      done

    fi
    ## check if we are supposed to be recursive
    local args="" ## reset args
    if [[ $RECURSE_CHILDREN -eq 1 ]]; then
      args="-r "
    fi
    ## come on already...make that snapshot
    logitf "Creating ZFS snapshot %s@%s\n" "$src" "$name"
    # shellcheck disable=SC2086
    if ! $prefix$ZFS snapshot $args$src@$name; then
      exitClean 99 "failed to create snapshot $src@$name"
    fi
    ## send snapshot to destination
    snapSend "$base" "$name" "$src" "$srcHost" "$dst" "$dstHost"
  done
  ## clear our lockfile
  clearLock "$TMPDIR/.snapshot.lock"
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

loadConfig() {
  local configFile=$1
  ## attempt to load configuration
  if [[ -f "$configFile" ]]; then
    logitf "Sourcing configuration from %s\n" "$configFile"
    # shellcheck disable=SC1090
    source "$configFile"
  elif configFile="$(dirname "${BASH_SOURCE[0]}")/config.sh" && [[ -f "$configFile" ]]; then
    logitf "Sourcing configuration from %s\n" "$configFile"
    # shellcheck disable=SC1090
    source "$configFile"
  else
    logitf "Loading configuration from defaults and environmental settings.\n"
  fi
  declare -A DATE_MACROS=(
    ["DOW"]=$(date "+%a") ["DOM"]=$(date "+%d") ["MOY"]=$(date "+%m")
    ["CYR"]=$(date "+%Y") ["NOW"]=$(date "+%s")
  )
  readonly DATE_MACROS
  readonly TMPDIR=${TMPDIR:-"/tmp"}
  readonly REPLICATE_SETS ## no default value
  readonly ALLOW_ROOT_DATASETS=${ALLOW_ROOT_DATASETS:-0}
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
  readonly HOST_CHECK=${HOST_CHECK:-"ping -c1 -q -W2 %HOST%"}
  readonly FORCE_REPLICATE=${FORCE_REPLICATE:-0}
  readonly LOGGER=${LOGGER:-$(which logger)}
  readonly FIND=${FIND:-$(which find)}
  readonly ZFS=${ZFS:-$(which zfs)}
  readonly SSH=${SSH:-$(which ssh)}
  readonly DEST_PIPE_WITH_HOST=${DEST_PIPE_WITH_HOST:-"$SSH %HOST% $ZFS receive -vFd"}
  readonly DEST_PIPE_WITHOUT_HOST=${DEST_PIPE_WITHOUT_HOST:-"$ZFS receive -vFd"}
  ## check configuration
  if [[ -n "$LOG_BASE" ]] && [[ ! -d "$LOG_BASE" ]]; then
    mkdir -p "$LOG_BASE"
  fi
  if [[ -z "$REPLICATE_SETS" ]]; then
    exitClean 99 "Missing required setting: REPLICATE_SETS"
  fi
  if [[ -z "$ZFS" ]]; then
    exitClean 99 "Unable to locate system zfs binary"
  fi
  if [[ $SNAP_KEEP -lt 2 ]]; then
    exit_clean 99 "You must keep at least 2 snaps for incremental sending."
  fi
}

printStatus() {
  ## Retrieve latest log status
  local logs
  mapfile -t logs < <(sortLogs)
  if [[ -n "${logs[0]}" ]]; then
    printf "Last output from zfs-replicate.sh:\n%s\n" "$(cat "${logs[0]}")"
  else
    echo "Unable to find most recent logfile, cannot print status."
  fi
  exit 0
}

## it all starts here...
main() {
  ## load configuration
  loadConfig "$@"
  ## check for status request - this is the only flag so it's a bit of a hack
  [[ "$2" == "--status" ]] && printStatus
  ## do snapshots and send
  snapCreate
  ## that's it, sending is called from doSnap
  exitClean 0
}

## start main if we weren't sourced
[[ "$0" == "${BASH_SOURCE[0]}" ]] && main "$@"
