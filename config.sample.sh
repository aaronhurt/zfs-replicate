## zfs-replicate sample configuration file - edit as needed
## config.sample.sh
## file revision $Id$
##

## datasets to replicate - use zfs paths not mount points...
## format is local_pool/local_fs:remote_pool or
## local_pool/local_fs:remote_pool/remote_fs the local name
## will be used on the remote end if not specified
REPLICATE_SETS="zpoolone/somefs:zpooltwo zpoolone/otherfs:zpooltwo"

## allow replication of root datasets - if you specify root
## datasets above and do not toggle this setting the
## script will generate a warning and skip replicating
## root datasets
## 0 - disable (default)
## 1 - enable (use at your own risk)
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

## where to place log files and temporary lock files
LOGBASE=/root/logs

## ip address or hostname of a remote server
## this variable may be referenced in the
## additional settings below
##
## this should not be used for local replication
## and could be commented out and ignored
REMOTE_SERVER="192.168.100.2"

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