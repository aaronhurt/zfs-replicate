#!/bin/bash

# Set default script directory
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")

# Check for existing logs
if ! [ -e  ${SCRIPTPATH}/logs ]; then
	echo "Log directory does not exist, can't check status."
	exit 0
fi

# Set log directory
LOGS="${SCRIPTPATH}/logs"

# Retrieve latest log status
RECENT_LOG_FILE=$(ls ${LOGS} | grep autorep- | tail -n 1)
STATUS=$(tail -n 1 ${LOGS}/${RECENT_LOG_FILE})

echo "Last Replication Status"
echo "----------"
echo "${STATUS}"
echo "----------"
