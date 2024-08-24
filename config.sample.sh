#!/usr/bin/env bash
## zfs-replicate configuration file
# shellcheck disable=SC2034

## Datasets to replicate. These must be zfs paths not mount points.
## The format general format is "source:destination".
## Examples replicating a local source to a remote destination (PUSH):
##   - sourcePool/sourceDataset:destinationPool@host
##   - sourcePool/sourceDataset:destinationPool/destinationDataset@host
## Examples replicating from a remote source to a local destination (PULL):
##   - sourcePool/sourceDataset@host:destinationPool
##   - sourcePool/sourceDataset@host:destinationPool/destinationDataset
## Examples replicating a local source to a local destination:
##   - sourcePool/sourceDataset:destinationPool
##   - sourcePool/sourceDataset:destinationPool/destinationDataset
## Multiple space separated sets may be specified.
## Pools and dataset pairs must exist on the respective servers.
REPLICATE_SETS="localpool/localdataset:remotepool/remotedataset"

## Command to check the health of remote host a return code of 0 is
## considered OK/available. This is only be used when a replicate set
## contains an "@host" designation. The macro string "%HOST%" will be
## substituted with the value of the "@host" target in the replicate set.
## The default command is "ping -c1 -q -W2 %HOST%".
#REMOTE_CHECK="ping -c1 -q -W2 %HOST%"

## Option to recursively snapshot children of all datasets listed above.
## 0 - disable (default)
## 1 - enable
#RECURSE_CHILDREN=0

## Option to force ANY replication task that would fail for any of the
## following conditions:
##   - no common snapshot
##   - snapshots detected on destination
##   - failure to replicate incremental snapshot
## Setting "FORCE_REPLICATE" to 1 will start the replication from scratch
## and overwrite the existing data on the destination.
## 0 - disable (default)
## 1 - enable (use at your own risk)
#FORCE_REPLICATE=0

## Allow replication of root datasets.
## If "REPLICATE_SETS" contains root datasets and "ALLOW_ROOT_DATASETS" is
## NOT seet to 1, root datasets will be skipped and a warning will be printed.
## 0 - disable (default)
## 1 - enable (use at your own risk)
#ALLOW_ROOT_DATASETS=0

## The number of snapshots to keep for each dataset.
## Older snapshots, by creation date, will be deleted.
## A minimum of 2 snapshots must be kept for replication to work.
## This defaults to 2 if not set.
#SNAP_KEEP=2

## The following substitutions for current date information
## may be used in the "TAG" setting below.
## These are evaluated at runtime.
##   - %DOW% = Day of Week (date "+%a")
##   - %MOY% = Month of Year (date "+%m")
##   - %DOM% = Day of Month (date "+%d")
##   - %CYR% = Current Year (date "+%Y")
##   - %NOW% = Current Unixtime (date "+%s")

## String used for snapshot names and log tags.
## Example: pool0/someplace@autorep-08242024_1724527527
## The default is "%MOY%%DOM%%CYR%_%NOW%"
#TAG="%MOY%%DOM%%CYR%_%NOW%"

## Option to write logs to syslog via the "logger" tool.
## 0 - disable
## 1 - enable (default)
#SYSLOG=1

## Optional logging facility to use with syslog. The default facility is
## "user" unless changed below. Other common options local facic facilities 0-7.
## Example: local0, local1, local2, local3, local4, local5, local6, or local7
#SYSLOG_FACILITY="user"

## Set the destination for physical log files to reside. By default
## logging is done via syslog. This setting will always be treated as a
## directory and not a file.
#LOG_BASE="/var/log/zfs-replicate"

## The log file needs to start with "autorep-" in order for log cleanup
## to work using the default below is strongly suggested. Leaving this commented out
## will disable the writing of the standalone log file. The "%TAG%" substitution
## and/or other date substitutions may be used. The default is "autorep-%TAG%.log"
## When enabled logs will be placed under the "LOG_BASE" path set above.
#LOG_FILE="autorep-%TAG%.log"

## Number of log files to keep. Note, this is only used
## if "LOG_BASE" is set to a non-empty value above.
## Older logs, by creation date, will be deleted.
## This defaults to 5 if not set.
#LOG_KEEP=5

## Path to the system "logger" executable.
## The default uses the first "logger" executable found in $PATH.
#LOGGER=$(which logger)

## Path to GNU "find" binary. Solaris find does not support the "-maxdepth"
## option, which is required to rotate log files.
## On solaris 11, GNU find is typically located at "/usr/bin/gfind".
## The default uses the first "find" executable in $PATH.
## This is NOT required when using syslog.
#FIND=$(which find)

## Path to the system "zfs" binary. The default uses the first "zfs"
## executable found in $PATH.
#ZFS=$(which zfs)
