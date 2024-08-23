zfs-replicate
=============

A Bash script to automate ZFS Replication.

Features
--------

- Supports PUSH or PULL replication
- Supports LOCAL or REMOTE replication
- Supports multiple pool/dataset pairs to replicate
- Everything is logged to `${SCRIPTPATH}/logs` by default (can be set to custom location using $LOGBASE variable) but its better to keep it together with the scripts
- Runs off a well documented `config.sh` file (see below)
- Can be run on any schedule using cron with `bash zfs-replicate.sh -config.sh`
- Includes a `get-last-status.sh` (for XigmaNAS) that can be used to email latest replication status, which will email the latest replication status at your preferred schedule. Simply add it as a custom script in the email settings under "System > Advanced > Email Reports" 
- Includes ALLOW_REPLICATE_FROM_SCRATCH option (see below, or `config.sh` file for details)

Warning
-------

Replicating a root dataset to a remote will rewrite the remote pool with forced replication.  This script will create
a true 1:1 copy of the source dataset in the destination dataset as currently configured.

The configuration ```REPLICATE_SETS="zpoolone:zpooltwo"``` will result in ```zpooltwo``` being a 1:1 copy of ```zpoolone```
and may result in dataloss on ```zpooltwo```.

To replicate a root dataset safely to another pool consider this configuration: ```REPLICATE_SETS="zpoolone:zpooltwo/zpoolone"```

This will result in a 1:1 copy of ```zpoolone``` in a separate data set of ```zpooltwo``` and will not affect other datasets currently present on the destination.

To Use
------

Configuration is done via a separate file that should be passed to the script on execution.  The script will attempt to locate a file called ```config.sh``` if one is not passed via the command line.

The file is very well commented and the contents of the sample config are shown below.

```bash
## zfs-replicate sample configuration file - edit as needed
## config.sample.sh

## ip address or hostname of a remote server
## comment out for local only replication
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
## PUSH will push the local to the remote
## PULL will pull the local to the remote
REPLICATE_SETS="localpool/localdataset:remotepool/remotedataset"

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

## number of snapshots to keep of each dataset
## older snapshots will be deleted
SNAP_KEEP=2

## number of logs to keep
## older logs will be deleted
LOG_KEEP=5

## log files directory (defaults to /var/log/zfs-replicate)
## for XigmaNAS users, uncomment the next 3 lines
## called SCRIPT SCRIPTPATH and LOGBASE
## and comment out the last line to make sure the 
## log files stay in the script directory
#SCRIPT=$(readlink -f "$0")
#SCRIPTPATH=$(dirname "${SCRIPT}")
#LOGBASE="${SCRIPTPATH}/logs"
LOGBASE="/var/log/zfs-replicate"

## command to check health of remote host
## a return code of 0 will be considered OK
## comment out for local only replication
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
```

Notes
-----
If you use this script, let me know, also please report issues via GitHub so this may be improved.
