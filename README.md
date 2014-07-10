
zfs-replicate.sh
================

Simple script to replicate zfs volumes between hosts (or between pools on the same host) via incremental snapshots.

Warning
-------

Replicating a root dataset to a remote will rewrite the remote pool with forced replication.  This script will create
a true 1:1 copy of the source (local) dataset in the destination (remote) dataset as currently configured.

The configuration ```REPLICATE_SETS="zpoolone:zpooltwo"``` will result in ```zpooltwo``` being a 1:1 copy of ```zpoolone```
and may result in dataloss on ```zpooltwo```.

To replicate a root dataset safely to another pool consider this configuration: ```REPLICATE_SETS="zpoolone:zpooltwo/zpoolone"```

This will result in a 1:1 copy of ```zpoolone``` in a separate data set of ```zpooltwo``` and will not affect other datasets currently present on the destination.

To Use
------

Configuration is done via the first part of the script and is fairly well descibed.

Snippet of that section can be found below.

```bash
## datasets to replicate - use zfs paths not mount points...
## format is local_pool/local_fs:remote_pool
## the local snap name will be used on the remote end
REPLICATE_SETS="zpoolone/somefs:zpooltwo zpoolone/otherfs:zpooltwo"

## allow replication of root datasets - if you specify root
## datasets above and do not toggle this setting the
## script will generate a warning and skip replicating
## root datasets
## 0 - disable (default)
## 1 - enable (do so at your own risk)
ALLOW_ROOT_DATASETS=0

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

## ip address or hostname of a remote server
## this variable may be referenced in the
## additional settings below
##
## this should not be used for local replication
## and could be commented out and ignored
REMOTE_SERVER='192.168.100.2'

## command to check health of remote host
## a return code of 0 will be considered OK
##
## this is not used for local replication
## and could be commented out and ignored
REMOTE_CHECK="ping -c1 -q -W2 ${REMOTE_SERVER}"

## pipe to your remote host...the pool/snap
## DO NOT INCLUDE THE PIPE (|) CHARACTER
## fs names from this host will be used on the remote
##
## for increased transfer speed you may want to specifically
## enumerate your prefered cipher order in your ssh command:
## ssh -c arcfour256,arcfour128,blowfish-cbc,aes128-ctr,aes192-ctr,aes256-ctr
##
## for local replication do not
## call ssh or reference a remote server
RECEIVE_PIPE="ssh ${REMOTE_SERVER} zfs receive -vFd"

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
