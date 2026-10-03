#!/usr/bin/env bash

# ===================================================================
# sshkey-root-confined: filter and limit capabilities of commands
#
# Make use of capsh and cgroups to isolate commands that would run
# as full root.
#
# github.com/prod365/ssh-tools
# ===================================================================

typeset MYSELF="$(realpath $0)"
typeset MYPATH="${MYSELF%/*}"

set -o nounset -o noclobber
export LC_ALL=C
export PATH="/bin:/sbin:/usr/bin:/usr/sbin:$PATH"
export PS4=' (${BASH_SOURCE##*/}:$LINENO ${FUNCNAME[0]:-main})  '

typeset LOG_FILE="$MYSELF.log"

typeset CMD_CALL="${SSH_ORIGINAL_COMMAND:-$@}"
typeset CMD_EXEC="${CMD_CALL%% *}"
typeset CMD_PATH="$(type -P $CMD_EXEC)"


#
# Drop capabilities to minimum
#

# What do we have / drop / keep
#typeset -a CAPCURRENT=($(capsh --print|awk '$1=="Current:"{print $3}'|tr ',' '\n'|grep ^cap_))
typeset    CAPOPTS=""
typeset -a CAPCURRENT=($(capsh --print|awk '$1=="Bounding"{gsub(/=/,"", $3); split($3,a,","); for (i in a) { print a[i]; }; }'))
typeset -a CAPDROP=(${CAPCURRENT[@]:-}
)
# We just allow to read any file and folder by default
typeset -a CAPKEEP=(cap_dac_read_search)


#
# capabilities exceptions
#

# Some binaries need added rights. Explain which and why
if [[ "$CMD_PATH" -ef "/bin/traceroute" ]]; then
	# Needed for tcp-traceroute
	CAPKEEP+=(cap_net_raw)
fi

#
# End of capabilities exception handling
#

# Remove from droplist caps we want to keep
for c in ${CAPKEEP[@]}; do
	[[ -n "${CAPDROP[@]:-}" ]] && CAPDROP=(${CAPDROP[@]//$c/})
done

# Stringify droplist
typeset CAPDROPSTR="${CAPDROP[@]:-}"
CAPDROPSTR="${CAPDROPSTR// /,}"

# DEBUG: Uncomment to remove the cap drop
#CAPDROPSTR=""

#
# Prepare the env to avoid unwanted leaks
#

function cgclean {
	typeset cgpath="$1"

	# Move us from the cgroup to a higher level
	echo $$ >> "/sys/fs/cgroup/cgroup.procs"

	# Kill all our remaining child and remove cgroup
	echo 1 >| "$cgpath/cgroup.kill"
	rmdir "$cgpath"
}

# CGroup if available to kill every process afterwards
typeset    CG_NAME="sshkey_filter.$$"
typeset    CG_PATH="/sys/fs/cgroup/$CG_NAME"
if [[ -e "/sys/fs/cgroup" ]] && [[ "$EUID" -eq 0 ]]; then
	[[ -e "$CG_PATH" ]] || mkdir -p "$CG_PATH"
	# get the script in chroot
	echo $$ >> "$CG_PATH/cgroup.procs"

	# Limit to only fork the process we'll run
	#echo "+pids" >> "$CG_PATH/cgroup.subtree_control"
	#echo 5 >| "$CG_PATH/pids.max"

	# cleanup upon exit: Kill all tasks and remove cgroup
	trap 'cgclean "'$CG_PATH'"' EXIT
fi


echo >>"$LOG_FILE" "Starting '$CMD_CALL' with cap:'${CAPKEEP[@]}'"

# Fork but don't exec', else the "trap exit" will kill us from cgroup
capsh --drop="$CAPDROPSTR" $CAPOPTS -- -c "$CMD_CALL"
