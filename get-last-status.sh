#!/usr/bin/env bash
## get-last-status.sh

print_status() {
  ## Set local variables used below
  local logPath find
  logPath="$(dirname "$(readlink -f "$0")")/logs"
  find=$(which find)

  ## Check for existing logs
  if ! [ -e "${logPath}" ]; then
    printf "Log directory does not exist, can't check status.\n"
    exit 0
  fi

  ## Retrieve latest log status
  local newestLog status
  newestLog=$(${find} "${logPath}" -maxdepth 1 -type f -name autorep-\* | sort | tail -1)
  status=$(tail -n 1 "${logPath}/${newestLog}")

  ## Print status block
  printf "Last Replication Status\n----------\n%s\n----------\n" "${status}"
}
