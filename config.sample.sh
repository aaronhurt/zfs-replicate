## zfs-replicate configuration file - edit as needed
## config.sh

## ip address or hostname of a remote server
## not used if TYPE is set to LOCAL
REMOTE_SERVER="192.168.1.250"

## set replication mode, PUSH or PULL
## PULL replicates from remote to local
## PUSH replicates from local to remote
## default is PULL
MODE="PULL"

## set replication TYPE to LOCAL for local only replication
## or REMOTE for remote replication
## REMOTE - remote server replication (default)
## LOCAL - local dataset replication
TYPE="REMOTE"

## datasets to replicate - use zfs paths not mount points...
## format is localpool/localdataset:remotepool or
## localpool/localdataset:remotepool/remotedataset
## can include multiple strings separated by a "space"
## pools and dataset pairs must exist on the respective servers
## PUSH will push the local to the remote
## PULL will pull the local to the remote
## REPLICATE_SETS="localpool/localdataset:remotepool/remotedataset"
REPLICATE_SETS=""

## option to recursively snapshot children of all datasets listed above
## 0 - disable (default)
## 1 - enable
RECURSE_CHILDREN=0

## if ANY replication task results in an error because of either
##  - no common snapshot
##  - snapshots detected on destination
##  - failure to replicate incremental snapshot
## this will start the replication from scratch if set to 1
## and overwrite the existing data on the destination
## 0 - disable (default)
## 1 - enable (use at your own risk)
ALLOW_REPLICATE_FROM_SCRATCH=0

## Allow replication of root datasets
## if you specify root datasets above and do not toggle this setting the
## script will generate a warning and skip replicating root datasets
## 0 - disable (default)
## 1 - enable (use at your own risk)
ALLOW_ROOT_DATASETS=0

## number of snapshots to keep for each dataset
## older snapshots will be deleted
SNAP_KEEP=2

## number of logs to keep
## older logs will be deleted
LOG_KEEP=5

## log files directory (defaults to /var/log/zfs-replicate)
LOGBASE="/var/log/zfs-replicate"

## command to check health of remote host
## a return code of 0 will be considered OK
## not used if TYPE is set to LOCAL
REMOTE_CHECK="ping -c1 -q -W2 ${REMOTE_SERVER}"

## path to zfs binary (only command for now)
ZFS=zfs

## path to GNU find binary
## solaris `find` does not support the -maxdepth option, which is required
## on solaris 11, GNU find is typically located at /usr/bin/gfind
FIND=/usr/bin/find

## get the current date info
DOW=$(date "+%a")
MOY=$(date "+%m")
DOM=$(date "+%d")
NOW=$(date "+%s")
CYR=$(date "+%Y")

## snapshot and log name tags
## ie: pool0/someplace@autorep-${NAMETAG}
NAMETAG="${MOY}${DOM}${CYR}_${NOW}"

## the log file needs to start with
## autorep- in order for log cleanup to work
## using the default below is strongly suggested
LOGFILE="${LOGBASE}/autorep-${NAMETAG}.log"
