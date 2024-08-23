#!/bin/bash

# Set log directory
LOG_DIRECTORY="/var/log/zfs-replicate"

# Check for existing logs
if ! [ -e  ${LOG_DIRECTORY} ]; then
	echo "Log directory does not exist, can't check status."
	exit 0
fi

# Retrieve latest log status
RECENT_LOG_FILE=$(ls ${LOG_DIRECTORY} | grep autorep- | tail -n 1)
STATUS=$(tail -n 1 ${LOG_DIRECTORY}/${RECENT_LOG_FILE})

echo "Last Replication Status"
echo "----------"
echo "${STATUS}"
echo "----------"
