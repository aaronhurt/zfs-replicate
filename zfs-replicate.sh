#!/usr/bin/env bash
## zfs-replicate.sh

############################################
##### warning gremlins live below here #####
############################################

## check log count and delete old
check_old_log() {
  ## declare log array
  local logs
  declare -a logs=()
  ## initialize index
  local index=0
  ## find existing logs
  for log in $("${C[find]}" "${C[logBase]}" -maxdepth 1 -type f -name autorep-\*); do
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
    logs[index]="$fstat\t$log\n"
    ## increase index
    (( index++ ))
  done
  ## set log count
  local lcount="${#logs[@]}"
  ## check count ... if greater than keep loop and delete
  if [[ "$lcount" -gt "${C[logKeep]}" ]]; then
    ## build new array in descending age order and reset index
    declare -a slogs=()
    local index=0
    ## loop through existing array
    for log in $(echo -e "${logs[@]:0}" | sort -rn | cut -f2); do
      ## append log to array
      slogs[index]="$log"
      ## increase index
      (( index++ ))
    done
    ## delete excess logs
    printf "deleting old logs: %s ...\n" "${slogs[@]:${C[logKeep]}}"
    rm -rf "${slogs[@]:${C[logKeep]}}"
  fi
}

## exit and cleanup
exit_clean() {
  local exitCode=${1:-0}
  local errorMsg=$2
  local logMsg="SUCCESS: Operation completed normally."

  ## build and print error message
  if [[ $exitCode -ne 0 ]]; then
    logMsg=$(printf "ERROR: Operation exited unexpectedly: code=%d" "$exitCode")
    if [[ "$errorMsg" != "" ]]; then
      logMsg=$(printf "%s msg=%s" "$logMsg" "$errorMsg")
    fi
  fi

  ## check log files
  check_old_log
  clear_lock "${LOGBASE}"/.push.lock
  clear_lock "${LOGBASE}"/.pull.lock
  clear_lock "${LOGBASE}"/.snapshot.lock

  ## print log message and exit
  printf "%s\n" "$logMsg"
  exit 0
}

## lockfile creation and maintenance
check_lock() {
  local lockFile=$1
  ## check our lockfile status
  if [[ -f "$lockFile" ]]; then
    ## see if this pid is still running
    local ps
    if ps=$(pgrep -lx -F "$lockFile"); then
      ## looks like it's still running
      printf "ERROR: This script is already running as: %s\n" "$ps"
    else
      ## well the lockfile is there...stale?
      printf "ERROR: Lockfile exists: %s\n" "$lockFile"
      printf "However, the contents do not match any "
      printf "currently running process...stale lockfile?\n"
    fi
    ## cleanup and exit
    exit_clean 99 "To run script please delete: $lockFile"
  else
    ## well no lockfile..let's make a new one
    printf "Creating lockfile: %s\n" "$lockFile"
    echo $$ > "$lockFile"
  fi
}

## delete lockfiles
clear_lock() {
  local lockFile=$1
  ## delete lockfiles...and that's all we do here
  if [ -f "$lockFile" ]; then
    printf "Deleting lockfile: %s\n" "$lockFile"
    rm -f "$lockFile"
  fi
}

## check remote system health
check_remote() {
  ## do we have a remote check defined
  if [ "${C[remoteCheck]}" == "" ]; then
    return
  fi
  
  ## TODO Perform macro sub

  ## run the check
  if ! ${C[remoteCheck]} > /dev/null 2>&1; then
    exit_clean $? "Remote check '${C[remoteCheck]}' failed!"
  fi
}

## push replication function
do_push() {
  ## check our push lockfile
  check_lock "${LOGBASE}/.push.lock"
  ## create initial push command based on arguments
  ## if first snapname is NULL we do not generate an incremental
  local dest_snap source_snap common_snap receiveargs
  if [[ "$MODE" == "PUSH" ]] && [[ "$TYPE" == "REMOTE" ]]; then
    dest_snap="$(ssh "${C[remoteServer]}" "$ZFS" list -t snapshot -o name | grep "${remote_set}" 2> /dev/null | grep autorep- 2> /dev/null | awk -F'@' '{print $2}' | tail -n 1)"
  elif [ "$MODE" == PUSH ] && [ "$TYPE" == LOCAL ]; then
    dest_snap="$(${ZFS} list -t snapshot -o name | grep ${remote_set} 2> /dev/null | grep autorep- 2> /dev/null | awk -F'@' '{print $2}' | tail -n 1)"
  fi
  local source_snap="$($ZFS list -t snapshot -o name | grep ${dest_snap} 2> /dev/null | awk -F'@' '{print $2}' | tail -n 1)"
  local common_snap="${local_set}@${dest_snap}"
  receiveargs="-vFd"
  if [ "${1}" == "NULL" ] && [ ${RECURSE_CHILDREN} -eq 1 ]; then
    local sendargs="-R"
  elif [ "${1}" == "NULL" ] && [ ${RECURSE_CHILDREN} -eq 0 ]; then
    local sendargs=""
  elif [ "${dest_snap}" == "${source_snap}" ] && [ ${RECURSE_CHILDREN} -eq 1 ]; then
    local sendargs="-R -I ${common_snap}"
  elif [ "${dest_snap}" == "${source_snap}" ] && [ ${RECURSE_CHILDREN} -eq 0 ]; then
    local sendargs="-I ${common_snap}"
  fi
  printf "Sending snapshots...\n"
  printf "RUNNING: %s %s %s | %s %s %s\n" "${SEND_PIPE}" "${sendargs}" "${2}" "${RECEIVE_PIPE}" "${receiveargs}" "${3}"
  if ! ${SEND_PIPE} ${sendargs} ${2} | ${RECEIVE_PIPE} ${receiveargs} ${3}; then
    if [ ${ALLOW_REPLICATE_FROM_SCRATCH} -eq 1 ]; then
      echo "No common snapshots found, but replication from scratch IS allowed."
      echo "Starting replication from scratch..."
      if [ ${RECURSE_CHILDREN} -eq 1 ]; then
        local sendargs="-R"
      elif [ ${RECURSE_CHILDREN} -eq 0 ]; then
        local sendargs=""
      fi
      if [ ${MODE} = PUSH ] && [ ${TYPE} = REMOTE ]; then
        ssh ${C[remoteServer]} "${ZFS} list -o name -t snapshot | grep ${remote_set} | xargs -n 1 ${ZFS} destroy"
      elif [ ${MODE} = PUSH ] && [ ${TYPE} = LOCAL ]; then
        ${ZFS} list -o name -t snapshot | grep ${remote_set} | xargs -n1 ${ZFS} destroy
      fi
      if ! ${SEND_PIPE} ${sendargs} ${2} | ${RECEIVE_PIPE} ${receiveargs} ${3}; then
        exit_clean $?
      fi
    elif [ ${ALLOW_REPLICATE_FROM_SCRATCH} -ne 1 ]; then
      exit_clean 99 "No common snapshots found, and replication from scratch IS NOT allowed."
    fi
  fi
  ## get status
  local status=$?
  ## clear lockfile
  clear_lock "${LOGBASE}/.push.lock"
  ## return status
  return $status
}

# pull replication function
do_pull() {
  ## check our pull lockfile
  check_lock "${LOGBASE}/.pull.lock"
  ## create initial receive command based on arguments
  ## if first snapname is NULL we do not generate an incremental
  local dest_snap="$($ZFS list -t snapshot -o name | grep ${local_set} 2> /dev/null | grep autorep- 2> /dev/null | awk -F'@' '{print $2}' | tail -n 1)"
  if [ ${MODE} = PULL ] && [ ${TYPE} = REMOTE ]; then
    local source_snap="$(ssh ${C[remoteServer]} $ZFS list -t snapshot -o name | grep ${dest_snap} 2> /dev/null | awk -F'@' '{print $2}' | tail -n 1)"
  elif [ ${MODE} = PULL ] && [ ${TYPE} = LOCAL ]; then
    local source_snap="$(${ZFS} list -t snapshot -o name | grep ${dest_snap} 2> /dev/null | awk -F'@' '{print $2}' | tail -n 1)"
  fi
  local common_snap="${remote_set}@${dest_snap}"
  local receiveargs="-vFd"
  if [ "${1}" == "NULL" ] && [ ${RECURSE_CHILDREN} -eq 1 ]; then
    local sendargs="-R"
  elif [ "${1}" == "NULL" ] && [ ${RECURSE_CHILDREN} -eq 0 ]; then
    local sendargs=""
  elif [ "${dest_snap}" == "${source_snap}" ] && [ ${RECURSE_CHILDREN} -eq 1 ]; then
    local sendargs="-R -I ${common_snap}"
  elif [ "${dest_snap}" == "${source_snap}" ] && [ ${RECURSE_CHILDREN} -eq 0 ]; then
    local sendargs="-I ${common_snap}"
  fi
  printf "Sending snapshots...\n"
  printf "RUNNING: %s %s %s | %s %s %s\n" "${SEND_PIPE}" "${sendargs}" "${2}" "${RECEIVE_PIPE}" "${receiveargs}" "${3}"
  if ! ${SEND_PIPE} ${sendargs} ${2} | ${RECEIVE_PIPE} ${receiveargs} ${3}; then
    if [ ${ALLOW_REPLICATE_FROM_SCRATCH} -eq 1 ]; then
      echo "No common snapshots found, but replication from scratch IS allowed."
      echo "Starting replication from scratch..."
      if [ ${RECURSE_CHILDREN} -eq 1 ]; then
        local sendargs="-R"
      elif [ ${RECURSE_CHILDREN} -eq 0 ]; then
        local sendargs=""
      fi
      if [ ${MODE} = PULL ] && [ ${TYPE} = REMOTE ]; then
        ${ZFS} list -o name -t snapshot | grep ${local_set} | xargs -n1 ${ZFS} destroy
      elif [ ${MODE} = PULL ] && [ ${TYPE} = LOCAL ]; then
        ${ZFS} list -o name -t snapshot | grep ${local_set} | xargs -n1 ${ZFS} destroy
      fi
      if ! ${SEND_PIPE} ${sendargs} ${2} | ${RECEIVE_PIPE} ${receiveargs} ${3}; then
        exit_error
      fi
    elif [ ${ALLOW_REPLICATE_FROM_SCRATCH} -ne 1 ]; then
      echo "No common snapshots found, and replication from scratch IS NOT allowed."
      exit_error
    fi
  fi
  ## get status
  local pull_status=$?
  ## clear lockfile
  clear_lock "${LOGBASE}/.pull.lock"
  ## return status
  return ${pull_status}
}

## small wrapper around zfs destroy
do_destroy() {
  ## get file set argument
  local snapshot="${1}"
  ## check settings
  if [ $RECURSE_CHILDREN -ne 1 ]; then
    local destroyargs=""
  else
    local destroyargs="-r"
  fi
  ## call zfs destroy
  if [ ${MODE} = PUSH ] && [ ${TYPE} = REMOTE ]; then
    ${ZFS} destroy ${destroyargs} ${snapshot}
  elif [ ${MODE} = PULL ] && [ ${TYPE} = REMOTE ]; then
    ssh ${C[remoteServer]} ${ZFS} destroy ${destroyargs} ${snapshot}
  elif [ ${MODE} = PUSH ] && [ ${TYPE} = LOCAL ]; then
    ${ZFS} destroy ${destroyargs} ${snapshot}
  elif [ ${MODE} = PULL ] && [ ${TYPE} = LOCAL ]; then
    ${ZFS} destroy ${destroyargs} ${snapshot}
  fi
}

## create and manage our zfs snapshots
do_snap() {
  ## make sure we aren't ever creating simultaneous snapshots
  check_lock "${LOGBASE}/.snapshot.lock"
  ## set our snap name
  local sname="autorep-${NAMETAG}"
  ## generate snapshot list and cleanup old snapshots
  for foo in $REPLICATE_SETS; do
    ## split dataset into local and remote parts and trim trailing slashes
    local local_set=$(echo $foo | cut -f1 -d: | sed 's/\/*$//')
    local remote_set=$(echo $foo | cut -f2 -d: | sed 's/\/*$//')
    ## check for root datasets
    if [ $ALLOW_ROOT_DATASETS -ne 1 ]; then
      if [ "${local_set}" == $(basename "${local_set}") ] &&
        [ "${remote_set}" == $(basename "${remote_set}") ]; then
        printf "WARNING: Replicating root datasets can lead to data loss.\n"
        printf "To allow root dataset replication and disable this warning "
        printf "set ALLOW_ROOT_DATASETS=1 in this script.  Skipping: %s\n\n" "${foo}"
        ## skip this set
        continue
      fi
    fi
    ## get current existing snapshots that look like
    ## they were made by this script
    if [ ${MODE} = PUSH ] && [ ${TYPE} = REMOTE ]; then
      if [ $RECURSE_CHILDREN -ne 1 ]; then
        local temps=$($ZFS list -Hr -o name -s creation -t snapshot -d 1 ${local_set} |
          grep "${local_set}\@autorep-")
      else
        local temps=$($ZFS list -Hr -o name -s creation -t snapshot ${local_set} |
          grep "${local_set}\@autorep-")
      fi
    elif [ ${MODE} = PULL ] && [ ${TYPE} = REMOTE ]; then
      if [ $RECURSE_CHILDREN -ne 1 ]; then
        local temps=$(ssh $REMOTE_SERVER $ZFS list -Hr -o name -s creation -t snapshot -d 1 ${remote_set} |
          grep "${remote_set}\@autorep-")
      else
        local temps=$(ssh $REMOTE_SERVER $ZFS list -Hr -o name -s creation -t snapshot ${remote_set} |
          grep "${remote_set}\@autorep-")
      fi
    elif [ ${MODE} = PUSH ] && [ ${TYPE} = LOCAL ]; then
      if [ $RECURSE_CHILDREN -ne 1 ]; then
        local temps=$($ZFS list -Hr -o name -s creation -t snapshot -d 1 ${local_set} |
          grep "${local_set}\@autorep-")
      else
        local temps=$($ZFS list -Hr -o name -s creation -t snapshot ${local_set} |
          grep "${local_set}\@autorep-")
      fi
    elif [ ${MODE} = PULL ] && [ ${TYPE} = LOCAL ]; then
      if [ $RECURSE_CHILDREN -ne 1 ]; then
        local temps=$($ZFS list -Hr -o name -s creation -t snapshot -d 1 ${remote_set} |
          grep "${remote_set}\@autorep-")
      else
        local temps=$($ZFS list -Hr -o name -s creation -t snapshot ${remote_set} |
          grep "${remote_set}\@autorep-")
      fi
    fi
    ## just a counter var
    local index=0
    ## our snapshot array
    declare -a snaps=()
    ## to the loop...
    for sn in $temps; do
      ## Check current snapshot name and destroy duplicates (if they exist)
      if [ ${MODE} == PUSH ]; then
        if [ "${sn}" == "${local_set}@${sname}" ]; then
          printf "Destroying DUPLICATE snapshot %s@%s\n" "${local_set}" "${sname}"
          do_destroy ${local_set}@${sname}
        fi
      elif [ ${MODE} == PULL ]; then
        if [ "${sn}" == "${remote_set}@${sname}" ]; then
          printf "Destroying DUPLICATE snapshot %s@%s\n" "${remote_set}" "${sname}"
          do_destroy ${remote_set}@${sname}
        fi
      fi
      ## append this snap to an array and increase count
      snaps[$index]=$sn
      let "index += 1"
    done
    ## set our snap count and reset our index
    local scount=${#snaps[@]}
    local index=0
    ## set our base snap for incremental generation below
    if [ $scount -ge 1 ]; then
      local base_snap=${snaps[$scount - 1]}
    fi
    ## how many snapshots did we end up with..
    if [ $scount -ge $SNAP_KEEP ]; then
      ## oops...too many snapshots laying around
      ## we need to destroy some of these
      while [ $scount -ge $SNAP_KEEP ]; do
        ## snaps are sorted above by creation in
        ## ascending order
        printf "Destroying OLD snapshot %s\n" "${snaps[$index]}"
        do_destroy ${snaps[$index]}
        ## decrease scount and increase index
        let "scount -= 1"
        let "index += 1"
      done
    fi

    ## Create snapshot and check for recursive setting
    if [ ${MODE} = PUSH ] && [ ${TYPE} = REMOTE ]; then
      printf "Creating ZFS snapshot %s@%s\n" "${local_set}" "${sname}"
      if [ $RECURSE_CHILDREN -ne 1 ]; then
        printf "RUNNING: %s snapshot %s@%s\n" "${ZFS}" "${local_set}" "${sname}"
        $ZFS snapshot ${local_set}@${sname}
        if [[ $? -ne 0 ]]; then
          exit_error
        fi
      else
        printf "RUNNING: %s snapshot -r %s@%s\n" "${ZFS}" "${local_set}" "${sname}"
        $ZFS snapshot -r ${local_set}@${sname}
        if [[ $? -ne 0 ]]; then
          exit_error
        fi
      fi
    elif [ ${MODE} = PULL ] && [ ${TYPE} = REMOTE ]; then
      printf "Creating ZFS snapshot %s@%s\n" "${remote_set}" "${sname}"
      if [ $RECURSE_CHILDREN -ne 1 ]; then
        printf "RUNNING: %s snapshot %s@%s\n" "${ZFS}" "${remote_set}" "${sname}"
        ssh $REMOTE_SERVER $ZFS snapshot ${remote_set}@${sname}
        if [[ $? -ne 0 ]]; then
          exit_error
        fi
      else
        printf "RUNNING: %s snapshot -r %s@%s\n" "${ZFS}" "${remote_set}" "${sname}"
        ssh $REMOTE_SERVER $ZFS snapshot -r ${remote_set}@${sname}
        if [[ $? -ne 0 ]]; then
          exit_error
        fi
      fi
    elif [ ${MODE} = PUSH ] && [ ${TYPE} = LOCAL ]; then
      printf "Creating ZFS snapshot %s@%s\n" "${local_set}" "${sname}"
      if [ $RECURSE_CHILDREN -ne 1 ]; then
        printf "RUNNING: %s snapshot %s@%s\n" "${ZFS}" "${local_set}" "${sname}"
        $ZFS snapshot ${local_set}@${sname}
        if [[ $? -ne 0 ]]; then
          exit_error
        fi
      else
        printf "RUNNING: %s snapshot -r %s@%s\n" "${ZFS}" "${local_set}" "${sname}"
        $ZFS snapshot -r ${local_set}@${sname}
        if [[ $? -ne 0 ]]; then
          exit_error
        fi
      fi
    elif [ ${MODE} = PULL ] && [ ${TYPE} = LOCAL ]; then
      printf "Creating ZFS snapshot %s@%s\n" "${remote_set}" "${sname}"
      if [ $RECURSE_CHILDREN -ne 1 ]; then
        printf "RUNNING: %s snapshot %s@%s\n" "${ZFS}" "${remote_set}" "${sname}"
        ${ZFS} snapshot ${remote_set}@${sname}
        if [[ $? -ne 0 ]]; then
          exit_error
        fi
      else
        printf "RUNNING: %s snapshot -r %s@%s\n" "${ZFS}" "${remote_set}" "${sname}"
        ${ZFS} snapshot -r ${remote_set}@${sname}
        if [[ $? -ne 0 ]]; then
          exit_error
        fi
      fi
    fi

    ## check return
    if [ $? -ne 0 ]; then
      ## oops...that's not right
      exit_error $?
    fi
    ## Send incremental snapshot if count is 1 or more, otherwise send full snapshot
    if [ ${MODE} == PUSH ]; then
      if [ $scount -ge 1 ]; then
        if ! do_push ${base_snap} ${local_set}@${sname} ${remote_set}; then
          do_destroy ${local_set}@${sname}
          exit_error
        fi
      else
        if ! do_push "NULL" ${local_set}@${sname} ${remote_set}; then
          do_destroy ${local_set}@${sname}
          exit_error
        fi
      fi
    elif [ ${MODE} == PULL ]; then
      if [ $scount -ge 1 ]; then
        if ! do_pull ${base_snap} ${remote_set}@${sname} ${local_set}; then
          do_destroy ${remote_set}@${sname}
          exit_error
        fi
      else
        if ! do_pull "NULL" ${remote_set}@${sname} ${local_set}; then
          do_destroy ${remote_set}@${sname}
          exit_error
        fi
      fi
    fi
    ## check return of replication
    if [ $? != 0 ]; then
      if [ ${MODE} = PUSH ]; then
        printf "ERROR: Failed to send snapshot %s@$%s\n" "${local_set}" "${sname}"
        printf "Deleting the local snapshot %s@$%s\n" "${local_set}" "${sname}"
        do_destroy ${local_set}@${sname}
        exit_error
      elif [ ${MODE} = PULL ]; then
        printf "ERROR: Failed to send snapshot %s@$%s\n" "${remote_set}" "${sname}"
        printf "Deleting the local snapshot %s@$%s\n" "${remote_set}" "${sname}"
        do_destroy ${remote_set}@${sname}
        exit_error
      fi
    fi
  done
  ## clear our lockfile
  clear_lock "${LOGBASE}/.snapshot.lock"
}

## it all starts here...
main() {
  ## initialize readonly config
  load_config "$@"
  ## set pipes depending on MODE
  if [ ${MODE} = PUSH ]; then
    if [ ${TYPE} = REMOTE ]; then
      RECEIVE_PIPE="ssh ${C[remoteServer]} zfs receive"
      SEND_PIPE="zfs send"
    elif [ ${TYPE} = LOCAL ]; then
      RECEIVE_PIPE="zfs receive"
      SEND_PIPE="zfs send"
      REMOTE_CHECK=""
    else
      echo "Replication type is not set. Please set the TYPE"
      echo "variable to REMOTE or LOCAL."
    fi
  elif [ ${MODE} = PULL ]; then
    if [ ${TYPE} = REMOTE ]; then
      RECEIVE_PIPE="zfs receive"
      SEND_PIPE="ssh ${C[remoteServer]} zfs send"
    elif [ ${TYPE} = LOCAL ]; then
      RECEIVE_PIPE="zfs receive"
      SEND_PIPE="zfs send"
      REMOTE_CHECK=""
    else
      echo "Replication type is not set. Please set the TYPE variable to REMOTE or LOCAL."
      exit_error
    fi
  else
    echo "Replication mode is not set. Please set the MODE variable to PUSH or PULL."
    exit_error
  fi
  if [ -z "${C[replicateSets]}" ] || [ "${C[replicateSets]}" == "localpool/localdataset:remotepool/remotedataset" ]; then
    echo "REPLICATE_SETS is not set properly. Please set it. See config.sample.sh file for examples."
    exit_error
  fi
  if [ $SNAP_KEEP -lt 2 ]; then
    printf "ERROR: You must keep at least 2 snaps for incremental sending.\n"
    printf "Please check the setting of 'SNAP_KEEP' in the script.\n"
    exit_error
  fi
  ## check remote health
  printf "Checking remote system...\n"
  check_remote
  ## do snapshots and send
  printf "Creating snapshots...\n"
  do_snap
  ## that's it...sending called from do_snap
  printf "Finished all operations for...\n"
  ## show a nice message and exit...
  exit_clean
}

load_config() {
  local argv0=$0
  local configFile=$1
  ## set default configuration
  declare -A C=(
    ["replicateSets"]=""
    ["remoteCheck"]="ping -c1 -q -W2 %HOST%"
    ["recurseChildren"]=0
    ["forceReplicate"]=0
    ["allowRootDatasets"]=0
    ["snapKeep"]=2
    ["nameTag"]="%MOY%%DOM%%CYR%_%NOW%"
    ["syslog"]=1
    ["syslogFacility"]="user"
    ["logBase"]=""
    ["logFile"]="autorep-%NAMETAG%.log"
    ["logKeep"]=5
    ["logger"]="$(which logger)"
    ["find"]="$(which find)"
    ["zfs"]="$(which zfs)"
  )
  ## attempt to load configuration
  if [[ -f "$configFile" ]]; then
    true ## passed value found, nothing to do
  elif configFile="$(dirname "$argv0")/config.sh" && [[ -f "$configFile" ]]; then
    true ## we found the default name in the script dir, nothing else to do
  else
    configFile="" ## clear config file
    printf "ERROR: Failed to find a valid configuration file. Continuing with defaults!\n"
  fi
  if [[ "$configFile" != "" ]]; then
    printf "Sourcing configuration from %s\n" "$configFile"
    # shellcheck disable=SC1090
    . "$configFile"
  fi
  ## overwrite defaults from config values
  [[ "$REPLICATE_SETS" != "" ]] && C["replicateSets"]="$REPLICATE_SETS"
  [[ "$REMOTE_CHECK" != "" ]] && C["remoteCheck"]="$REMOTE_CHECK"
  [[ "$RECURSE_CHILDREN" != "" ]] && C["recurseChildren"]="$RECURSE_CHILDREN"
  [[ "$FORCE_REPLICATE" != "" ]] && C["forceReplicate"]="$FORCE_REPLICATE"
  [[ "$ALLOW_ROOT_DATASETS" != "" ]] && C["allowRootDatasets"]="$ALLOW_ROOT_DATASETS"
  [[ "$SNAP_KEEP" != "" ]] && C["snapKeep"]="$SNAP_KEEP"
  [[ "$NAME_TAG" != "" ]] && C["nameTag"]="$NAMETAG"
  [[ "$SYSLOG" != "" ]] && C["syslog"]="$SYSLOG"
  [[ "$SYSLOG_FACILITY" != "" ]] && C["syslogFacility"]="$SYSLOG_FACILITY"
  [[ "$LOG_BASE" != "" ]] && C["logBase"]="$LOG_BASE"
  [[ "$LOG_FILE" != "" ]] && C["logFile"]="$LOG_FILE"
  [[ "$LOG_KEEP" != "" ]] && C["logKeep"]="$LOG_KEEP"
  [[ "$LOGGER" != "" ]] && C["logger"]="$LOGGER"
  [[ "$FIND" != "" ]] && C["find"]="$FIND"
  [[ "$ZFS" != "" ]] && C["zfs"]="$ZFS"
  ## export config as readonly
  readonly C
  export C
}

## make sure our log dir exits
[ ! -d "${LOGBASE}" ] && mkdir -p "${LOGBASE}"

## this is where it all starts
main "$@" > "${LOGFILE}" 2>&1
