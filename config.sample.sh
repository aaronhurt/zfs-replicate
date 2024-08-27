#!/usr/bin/env bash
## zfs-replicate configuration file
# shellcheck disable=SC2034

## Datasets to replicate. These must be zfs paths not mount points.
## The format general format is "source:destination". The source is always
## considered authoritative. This holds true for reconciliation attempts with
## the "FORCE_FALLBACK" and "FORCE_PRUNE" options describe below as well.
## This script will NEVER modify the source as a means to prevent a failure.
## The "FORCE_FALLBACK" and "FORCE_PRUNE" options only affect the destination.
##
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
##
#REPLICATE_SETS=""

## Allow replication of root datasets.
## If "REPLICATE_SETS" contains root datasets and "ALLOW_ROOT_DATASETS" is
## NOT set to 1, root datasets will be skipped and a warning will be printed.
##
## 0 - disable (default)
## 1 - enable (use at your own risk)
##
#ALLOW_ROOT_DATASETS=0

## Manual alteration of the source or destination datasets by removing
## snapshots often results in failure. It is expected that datasets configured
## for replication are a 1:1 copy of each other after the first script run.
## Setting this option to "1" allows the script to attempt reconciliation when
## source and destination datasets have diverged.
##
## NOTE: The source is always authoritative. Reconciliation will only
## affect the destination dataset.
##
## Setting this option to "1" will result in the following potentially
## destructive behavior for the destination dataset.
##
## - If the script is unable to find the source base snapshot
##   in the destination dataset. The script will fallback to a full send.
##   When combined with the "-F" option in the destination receive pipe,
##   this option will force a reconciliation. ZFS will automatically remove
##   snapshots in the destination that do not exist within the source.
## - If the script determines that replication snapshots exist in the
##   destination dataset, and no base snapshot is present in the source.
##   The script will remove ALL destination snapshots that appear to have been
##   created by this script and instruct ZFS to do a full send of the source
##   to the destination.
##
## These scenarios should never happen under normal circumstances.
## Setting "ALLOW_RECONCILIATION" to "1" will allow the script to push
## past failures caused by divergent source and destination datasets to
## create a 1:1 copy of the source in the destination.
##
## 0 - disable (default)
## 1 - enable (use at your own risk)
##
#ALLOW_RECONCILIATION=0

## Option to recursively snapshot children of datasets contained
## in the replication set.
##
## 0 - disable (default)
## 1 - enable
##
#RECURSE_CHILDREN=0

## The number of snapshots to keep for each dataset.
## Older snapshots, by creation date, will be deleted.
## A minimum of 2 snapshots must be kept for replication to work.
## This defaults to 2 if not set.
##
#SNAP_KEEP=2

## Option to write logs to syslog via the "logger" tool. This option
## may be enabled or disabled independently from log file settings.
##
## 0 - disable
## 1 - enable (default)
##
#SYSLOG=1

## Optional logging facility to use with syslog. The default facility
## is "user" unless changed below. Other common options include local
## facilities 0-7.
## Example: local0, local1, local2, local3, local4, local5, local6, or local7
##
#SYSLOG_FACILITY="user"

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
##
#TAG="%MOY%%DOM%%CYR%_%NOW%"

## The log file needs to start with "autorep-" in order for log cleanup
## to work using the default below is strongly suggested. Leaving this commented out
## will disable the writing of the standalone log file. The "%TAG%" substitution
## and/or other date substitutions may be used. The default is "autorep-%TAG%.log"
## When enabled logs will be placed under the "LOG_BASE" path set above.
##
#LOG_FILE="autorep-%TAG%.log"

## Number of log files to keep. Note, this is only used
## if "LOG_BASE" is set to a non-empty value above.
## Older logs, by creation date, will be deleted.
## This defaults to 5 if not set.
##
#LOG_KEEP=5

## Set the destination for physical log files to reside. By default
## logging is done via syslog. This setting will always be treated as a
## directory and not a file.
##
#LOG_BASE="/var/log/zfs-replicate"

## Path to the system "logger" executable.
## The default uses the first "logger" executable found in $PATH.
##
#LOGGER=$(which logger)

## Path to GNU "find" binary. Solaris find does not support the "-maxdepth"
## option, which is required to rotate log files.
## On solaris 11, GNU find is typically located at "/usr/bin/gfind".
## The default uses the first "find" executable in $PATH.
## This is NOT required when using syslog.
##
#FIND=$(which find)

## Path to the system "zfs" binary. The default uses the first "zfs"
## executable found in $PATH.
##
#ZFS=$(which zfs)

## Path to the system "ssh" binary. You may also include custom arguments
## to SSH here or in the "DEST_PIPE_WITH_HOST" option above.
## Example: SSH="ssh -l root" to login as root to target host.
## The default uses the first "ssh" executable found in $PATH.
##
#SSH=$(which ssh)

## Set the pipe to the destination pool. But DO NOT INCLUDE the pipe (|)
## character in this setting. Filesystem  names from the source will be
## sent to the destination. For increased transfer speed to remote hosts you
## may want to customize ssh ciphers or include mbuffer.
## The macro %HOST% string will be substituted with the value of the "@host"
## target in the replication set.
## The default WITH a "@host" option is "ssh %HOST% zfs receive -vFd"
## The default WITHOUT a "@host" option is "zfs receive -vFd".
##
#DEST_PIPE_WITH_HOST="$SSH %HOST% $ZFS receive -vFd"
#DEST_PIPE_WITHOUT_HOST="$ZFS receive -vFd"

## Command to check the health of a source or destination host.
## A return code of 0 is considered OK/available.
## This is only used when a replicate set contains an "@host" option.
## The macro string "%HOST%" will be substituted with the value of
## the "@host" target in the replicate set.
## The default command is "ping -c1 -q -W2 %HOST%".
##
#HOST_CHECK="ping -c1 -q -W2 %HOST%"
