#!/bin/bash

# Set log directory
LOGS="/var/log/zfs-replicate"

# Check for existing logs
if ! [ -e  ${LOGS} ]; then
	echo "Log directory does not exist, can't check status."
	exit 0
fi

# Retrieve latest log status
RECENT_LOG_FILE=$(ls ${LOGS} | grep autorep- | tail -n 1)
STATUS=$(tail -n 1 ${LOGS}/${RECENT_LOG_FILE})

echo "Last Replication Status"
echo "----------"
echo "${STATUS}"
echo "----------"
