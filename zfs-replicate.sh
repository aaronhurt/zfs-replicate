#!/usr/bin/env bash
## zfs-replicate.sh
## file revision $Id$
##

############################################
##### warning gremlins live below here #####
############################################

## check log count and delete old
check_old_log() {
        ## declare log array
        declare -a logs=()
        ## initialize index
        local index=0
        ## find existing logs
        for log in $(find ${LOGBASE} -maxdepth 1 -type f -name autorep-\*); do
                ## get file change time via stat (platform specific)
                case "$(uname -s)" in
                    Linux|SunOS)
                        local fstat=$(stat -c %Z ${log})
                    ;;
                    *)
                        local fstat=$(stat -f %c ${log})
                    ;;
                esac
                ## append logs to array with creation time
                logs[$index]="${fstat}\t${log}\n"
                ## increase index
                let "index += 1"
        done
        ## set log count
        local lcount=${#logs[@]}
        ## check count ... if greater than keep loop and delete
        if [ $lcount -gt ${LOG_KEEP} ]; then
                ## build new array in descending age order and reset index
                declare -a slogs=(); local index=0
                ## loop through existing array
                for log in $(echo -e ${logs[@]:0} | sort -rn | cut -f2); do
                        ## append log to array
                        slogs[$index]=${log}
                        ## increase index
                        let "index += 1"
                done
                ## delete excess logs
                printf "deleting old logs: %s ...\n" "${slogs[@]:${LOG_KEEP}}"
                rm -rf ${slogs[@]:${LOG_KEEP}}
        fi
}

## exit 0 and delete old log files
exit_clean() {
        ## print errors
        if [ "${1}x" != "x" ] && [ ${1} != 0 ]; then
                printf "Last operation returned error code: %s\n" "${1}"
        fi
        ## check log files
        check_old_log
        ## always exit 0
        printf "Exiting...\n"
        exit 0
}

## lockfile creation and maintenance
check_lock () {
        ## check our lockfile status
        if [ -f "${1}" ]; then
                ## get lockfile contents
                local lpid=$(cat "${1}")
                ## see if this pid is still running
                local ps=$(ps auxww|grep $lpid|grep -v grep)
                if [ "${ps}x" != 'x' ]; then
                        ## looks like it's still running
                        printf "ERROR: This script is already running as: %s\n" "${ps}"
                else
                        ## well the lockfile is there...stale?
                        printf "ERROR: Lockfile exists: %s\n" "${1}"
                        printf "However, the contents do not match any "
                        printf "currently running process...stale lockfile?\n"
                fi
                ## tell em what to do...
                printf "To run script please delete: %s\n" "${1}"
                ## compress log and exit...
                exit_clean
        else
                ## well no lockfile..let's make a new one
                printf "Creating lockfile: %s\n" "${1}"
                echo $$ > "${1}"
        fi
}

## delete lockiles
clear_lock() {
        ## delete lockfiles...and that's all we do here
        if [ -f "${1}" ]; then
                printf "Deleting lockfile: %s\n" "${1}"
                rm "${1}"
        fi
}

## check remote system health
check_remote() {
    ## do we have a remote check defined
    if [ "${REMOTE_CHECK}x" != 'x' ]; then
        ## run the check
        $REMOTE_CHECK > /dev/null 2>&1
        ## exit if above returned non-zero
        if [ $? != 0 ]; then
            printf "ERROR: Remote health check '%s' failed!\n" "${REMOTE_CHECK}"
            exit_clean
        fi
    fi
}

## main replication function
do_send() {
        ## check our send lockfile
        check_lock "${LOGBASE}/.send.lock"
        ## create initial send command based on arguments
        ## if first snapname is NULL we do not generate an inremental
        if [ "${1}" == "NULL" ]; then
                local sendargs="-R"
        else
                local sendargs="-R -I ${1}"
        fi
        printf "Sending snapshots...\n"
        printf "RUNNING: %s send %s %s | %s %s\n" "${ZFS}" "${sendargs}" "${2}" "${RECEIVE_PIPE}" "${3}"
        ${ZFS} send ${sendargs} ${2} | ${RECEIVE_PIPE} ${3}
        ## clear lockfile
        clear_lock "${LOGBASE}/.send.lock"
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
                local local_set=$(echo $foo|cut -f1 -d:|sed 's/\/*$//')
                local remote_set=$(echo $foo|cut -f2 -d:|sed 's/\/*$//')
                ## check for root datasets
                if [ $ALLOW_ROOT_DATASETS -ne 1 ]; then
                    if [ "${local_set}" == $(basename "${local_set}") ] && \
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
                if [ $RECURSE_CHILDREN -ne 1 ]; then
                    local temps=$($ZFS list -Hr -o name -s creation -t snapshot -d 1 ${local_set}|\
                        grep "${local_set}\@autorep-")
                else
                    local temps=$($ZFS list -Hr -o name -s creation -t snapshot ${local_set}|\
                        grep "${local_set}\@autorep-")
                fi
                ## just a counter var
                local index=0
                ## our snapshot array
                declare -a snaps=()
                ## to the loop...
                for sn in $temps; do
                        ## while we are here...check for our current snap name
                        if [ "${sn}" == "${local_set}@${sname}" ]; then
                                ## looks like it's here...we better kill it
                                ## this shouldn't happen normally
                                printf "Destroying DUPLICATE snapshot %s@%s\n" "${local_set}" "${sname}"
                                $ZFS destroy ${local_set}@${sname}
                        else
                                ## append this snap to an array
                                snaps[$index]=$sn
                                ## increase our index counter
                                let "index += 1"
                        fi
                done
                ## set our snap count and reset our index
                local scount=${#snaps[@]}; local index=0
                ## set our base snap for incremental generation below
                if [ $scount -ge 1 ]; then
                    local base_snap=${snaps[$scount-1]}
                fi
                ## how many snapshots did we end up with..
                if [ $scount -ge $SNAP_KEEP ]; then
                        ## oops...too many snapshots laying around
                        ## we need to destroy some of these
                        while [ $scount -ge $SNAP_KEEP ]; do
                                ## snaps are sorted above by creation in
                                ## ascending order
                                printf "Destroying OLD snapshot %s\n" "${snaps[$index]}"
                                $ZFS destroy ${snaps[$index]}
                                ## decrease scount and increase index
                                let "scount -= 1"; let "index += 1"
                        done
                fi
                ## come on already...make that snapshot
                printf "Creating ZFS snapshot %s@%s\n" "${local_set}" "${sname}"
                ## check if we are supposed to be recurrsive
                if [ $RECURSE_CHILDREN -ne 1 ]; then
                    printf "RUNNING: %s snapshot %s@%s" "${ZFS}" "${local_set}" "${sname}"
                    $ZFS snapshot ${local_set}@${sname}
                else
                    printf "RUNNING: %s snapshot -r %s@%s" "${ZFS}" "${local_set}" "${sname}"
                    $ZFS snapshot -r ${local_set}@${sname}
                fi
                ## check return
                if [ $? -ne 0 ]; then
                        ## oops...that's not right
                        exit_clean $?
                fi
                ## send incremental if snap count 1 or more
                ## otherwise send a regular stream
                if [ $scount -ge 1 ]; then
                        do_send ${base_snap} ${local_set}@${sname} ${remote_set}
                else
                        do_send "NULL" ${local_set}@${sname} ${remote_set}
                fi
        done
        ## clear our lockfile
        clear_lock "${LOGBASE}/.snapshot.lock"
}

## it all starts here...
init() {
    ## sanity check
    if [ $SNAP_KEEP -lt 2 ]; then
        printf "ERROR: You must keep at least 2 snaps for incremental sending.\n"
        printf "Please check the setting of 'SNAP_KEEP' in the script.\n"
        exit_clean
    fi
    ## check remote health
    printf "Checking remote system...\n"
    check_remote
    ## do snapshots and send
    printf "Creating snapshots...\n"
    do_snap
    ## that's it...sending called from do_snap
    printf "Finished all operations for ...\n"
    ## show a nice message and exit...
    exit_clean
}

## attempt to load configuration
if [ "${1}x" != "x" ] && [ -f "${1}" ]; then
    ## source passed config
    printf "Sourcing configuration from %s\n" "${1}"
    . "${1}"
elif [ -f "config.sh" ]; then
    ## source default config
    printf "Sourcing configuration from config.sh\n"
    . "config.sh"
else
    ## display error
    printf "ERROR: Cannot continue without a valid configuration file!\n"
    printf "Usage: %s <config>\n" "${0}"
    ## exit
    exit 0
fi

## make sure our log dir exits
[ ! -d "${LOGBASE}" ] && mkdir -p "${LOGBASE}"

## this is where it all starts
init > "${LOGFILE}" 2>&1
