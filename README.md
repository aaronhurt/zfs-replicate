
zfs-replicate.sh
================

Simple script to replicate zfs volumes between hosts (or between pools on the same host) via incremental snapshots.

To Use
------

Configuration is done via the first part of the script and is fairly well descibed.

Snippet of that section below.

```bash
## datasets to replicate - use zfs paths not mount points...
## format is local_pool/local_fs:remote_pool
## the local snap name will be used on the remote end
REPLICATE_SETS="zpoolone/somefs:zpooltwo zpoolone/otherfs:zpooltwo"

## option to recurrsively snapshot children of
## all datasets listed above
## 0 - disable (previous behavior)
## 1 - enable
RECURSE_CHILDREN=0

## number of snapshots to keep of each dataset
## snaps in excess of this number will be expired
## oldest deleted first...must be 2 or greater
SNAP_KEEP=2

## number of logs to keep in path ... logs will be
## deleted in order of age with oldest going first
LOG_KEEP=10

## where you want your log files
## and gnu tar incremental snaphots
LOGBASE=/root/logs

## pipe to your remote host...the pool/snap
## DO NOT INCLUDE THE PIPE (|) CHARACTER
## fs names from this host will be used on the remote
REMOTE="ssh remote-server zfs receive -vFd"

## command to check health of remote host
## a return code of 0 will be considered OK
RCHECK="ping -c1 -q -W2 remote-server"

## path to zfs binary
ZFS=/sbin/zfs

## get the current date info
DOW=$(date "+%a")
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
```

Notes
-----

This script has been used by myself and others for well over a year, however as they say YMMV (your mileage may vary).

If you use it, let me know, also please report issues via GitHub so this may be improved.
