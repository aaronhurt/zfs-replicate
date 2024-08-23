#!/bin/bash

# Set log directory (defaults to /var/log/zfs-replicate)
## for XigmaNAS users, uncomment the next 3 lines
## called SCRIPT SCRIPTPATH and LOGBASE
## and comment out the last line to make sure the 
## log files stay in the script directory
#SCRIPT=$(readlink -f "$0")
#SCRIPTPATH=$(dirname "${SCRIPT}")
#LOGBASE="${SCRIPTPATH}/logs"
LOGBASE="/var/log/zfs-replicate"

# Check for existing logs
if ! [ -e  ${LOGBASE} ]; then
	echo "Log directory does not exist, can't check status."
	exit 0
fi

# Retrieve latest log status
RECENT_LOG_FILE=$(ls ${LOGBASE} | grep autorep- | tail -n 1)
STATUS=$(tail -n 1 ${LOGBASE}/${RECENT_LOG_FILE})

echo "Last Replication Status"
echo "----------"
echo "${STATUS}"
echo "----------"
