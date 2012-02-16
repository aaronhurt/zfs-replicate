#!/usr/local/bin/bash
## /root/doreplicate.sh
## last update 07.26.2010 by ahurt
##

## datasets to replicate - use zfs paths not mount points...
## format is local_pool/local_fs:remote_pool/remote_fs
## the local snap name will be used on the remote end
REPLICATE_SETS="pool/mystyle-data:pool"

## number of snapshots to keep of each dataset
## snaps in excess of this number will be expired
## oldest deleted first...must be 2 or greater
SNAP_KEEP="2"

## number of logs to keep in path ... logs will be
## deleted in order of age with oldest going first
LOG_KEEP="10"

## where you want your log files
## and gnu tar incremental snaphots
LOGBASE=/root/logs

## pipe to your remote host...the pool/snap
## DO NOT INCLUDE THE PIPE (|) CHARACTER
## names from this host will be used on the remote
REMOTE="ssh nv-srv2 zfs receive -vFd"

## path to zfs binary
ZFS=/sbin/zfs

## get the current date info
DOW=$(date +"%a")
MOY=$(date "+%m")
DOM=$(date "+%d")
NOW=$(date "+%s")
CYR=$(date "+%Y")

## snapshot and log name tags
## ie: pool0/someplace@autorep-${NAMETAG}
NAMETAG="${MOY}${DOM}${CYR}_${NOW}"

## the log file...you need to prepend with
## autorep- in order for log cleanup to work
## using the default below is strongly suggested
LOGFILE="${LOGBASE}/autorep-${NAMETAG}.log"


############################################
##### warning gremlins live below here #####
############################################


## check log count and delete old
check_old_log() {
        ## declare log array
        declare -a logs
        ## initialize index
        local index=0
        ## find existing logs
        for log in `find ${LOGBASE} -maxdepth 1 -type f -name autorep-\*`; do
                ## append logs to array with creation time
                logs[$index]="$(stat -f %c ${log})\t$log\n"
                ## increase index
                let "index += 1"
        done
        ## set log count
        local lcount=${#logs[@]}
        ## check count ... if greater than keep loop and delete
        if [ $lcount -gt ${LOG_KEEP} ]; then
                ## build new array in descending age order and reset index
                declare -a slogs; local index=0
                ## loop through existing array
                for log in `echo -e ${logs[@]:0} | sort -rn | cut -f2`; do
                        ## append log to array
                        slogs[$index]=${log}
                        ## increase index
                        let "index += 1"
                done
                ## delete excess logs
                echo "deleting old logs: ${slogs[@]:${LOG_KEEP}} ..."
                rm -rf ${slogs[@]:${LOG_KEEP}}
        fi
}

## exit 0 and delete old log files
exit_clean() {
        ## print errors
        if [ "${1}x" != "x" ] && [ ${1} != 0 ]; then
                echo "Last operation returned error code: ${1}"
        fi
        ## check log files
        check_old_log
        ## always exit 0
        echo "Exiting..."
        exit 0
}

## lockfile creation and maintenance
check_lock () {
        ## check our lockfile status
        if [ -f "${1}" ]; then
                ## get lockfile contents
                local lpid=`cat "${1}"`
                ## see if this pid is still running
                local ps=`ps auxww|grep $lpid|grep -v grep`
                if [ "${ps}x" != 'x' ]; then
                        ## looks like it's still running
                        echo "ERROR: This script is already running as: $ps"
                else
                        ## well the lockfile is there...stale?
                        echo "ERROR: Lockfile exists: '${1}'"
                        echo -n "However, the contents do not match any "
                        echo "currently running process...stale lock?"
                fi
                ## tell em what to do...
                echo -n "To run script please delete: "
                echo "'${1}'"
                ## compress log and exit...
                exit_clean
        else
                ## well no lockfile..let's make a new one
                echo "Creating lockfile: ${1}"
                echo $$ > "${1}"
        fi
}

## delete lockiles
clear_lock() {
        ## delete lockfiles...and that's all we do here
        if [ -f "${1}" ]; then
                echo "Deleting lockfile: ${1}"
                rm "${1}"
        fi
}

## main replication function
do_send(){
        ## check our send lockfile
        check_lock "${LOGBASE}/.send.lock"
        ## create initial send command based on arguments
        ## if first snapname is NULL we do not generate an inremental
        if [ "${1}" == "NULL" ]; then
                sendargs="-R"
        else
                sendargs="-R -I ${1}"
        fi
        echo "RUNNING: ${ZFS} send $sendargs ${2} | ${REMOTE} ${3}"
        ${ZFS} send $sendargs ${2} | ${REMOTE} ${3}
        ## clear lockfile
        clear_lock "${LOGBASE}/.send.lock"
}

## create and manage our zfs snapshots
do_snap(){
        ## make sure we aren't ever creating simultaneous snapshots
        check_lock "${LOGBASE}/.snapshot.lock"
        ## set our snap name
        local sname="autorep-${NAMETAG}"
        ## generate snapshot list and cleanup old snapshots
        for foo in $REPLICATE_SETS; do
                ## split dataset into local and remote parts
                local_set=`echo $foo|cut -f1 -d:`
                remote_set=`echo $foo|cut -f2 -d:`
                ## get current existing snapshots that look like
                ## they were made by this script
                local temps=`$ZFS list -t snapshot|\
                grep "${local_set}\@autorep-" | awk '{print $1}'`
                ## just a counter var
                local index=0
                ## our snapshot array
                declare -a snaps
                ## to the loop...
                for sn in $temps; do
                        ## while we are here...check for our current snap name
                        if [ "${sn}" == "${local_set}@${sname}" ]; then
                                ## looks like it's here...we better kill it
                                ## this shouldn't happen normally
                                echo "Destroying DUPLICATE snapshot ${local_set}@${sname}"
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
                local base_snap=${snaps[$scount-1]}
                ## how many snapshots did we end up with..
                if [ $scount -ge $SNAP_KEEP ]; then
                        ## oops...too many snapshots laying around
                        ## we need to destroy some of these
                        while [ $scount -ge $SNAP_KEEP ]; do
                                ## zfs list always shows newest last
                                ## we can use that to our advantage
                                echo "Destroying OLD snapshot ${snaps[$index]}"
                                $ZFS destroy ${snaps[$index]}
                                ## decrease scount and increase index
                                let "scount -= 1"; let "index += 1"
                        done
                fi
                ## come on already...make that snapshot
                echo "Creating ZFS snapshot ${local_set}@${sname}"
                $ZFS snapshot ${local_set}@${sname}
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
init(){
        ## sanity check
        if [ $SNAP_KEEP -lt 2 ]; then
                echo "ERROR: You must keep at least 2 snaps for incremental sending."
                echo "Please check the setting of 'SNAP_KEEP' in the script."
                exit_clean
        fi
        ## do snapshots and send
        echo "Creating snapshots..."
        do_snap
        ## that's it...sending called from do_snap
        echo "Finished all operations for ..."
        ## show a nice message and exit...
        exit_clean
}

## make sure our log dir exits
[ ! -d $LOGBASE ] && mkdir -p $LOGBASE

## this is where it all starts
init > $LOGFILE 2>&1
