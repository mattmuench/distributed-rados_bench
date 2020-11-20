#!/bin/bash
#ident: distributed-rados_bench.sh, v1.5, 2020/11/20. matthias.muench@redhat.com

# version 3+ only: parallel use of nodes for kicking off sessions (otherwise, all would run on the local node)
#BENCH_NODELIST="ceph04-n01;ceph04-n02;ceph04-n04;ceph04-n05"
BENCH_NODELIST="ceph04-n01"
#BENCH_PODS="ceph04-n01:rgw0;ceph04-n02:rgw0;ceph04-n04:mds;ceph04-n05:mds"
BENCH_PODS="ceph04-n01:rgw0"
# assumption: pools are created, with number of pools matching number of nodes from BENCH_NODELIST
#BENCH_POOLS="testrbd1;testrbd2;testrbd3;testrbd4"
BENCH_POOLS="testrbd1"
CONTAINERISED=1
BENCH_HOSTS_USER=root

# number of parallel different benchmarks  - from the same node in parallel - those will work with the same pool
PARALLEL_BENCH=1
# runtime per single benchmark test
BENCH_RUNTIME=10
# stop benchmarking after fill grade is hit
BENCH_CEPHFILL=20
# runtime of an individual benchmark job before generating a warning: wait additional NN sec on top of set job runtime
BENCH_JOB_WARNTIME=`expr $BENCH_RUNTIME + 20`
# max runtime of all benchmark jobs run in parallel - otherwise those will be terminated
BENCH_JOB_TERMTIME=`expr $BENCH_RUNTIME + 120`
# benchmark IO size used
BENCH_IOSIZE=`expr 4 \* 1024`
# benchmark number of threads in parallel
BENCH_THREADS=4

# DO NOT MODIFY WITHOUT NEED
# time to wait for settling writes before kicking off read benchmark
BENCH_MULTIHOST_WAIT_BEFORE_READ=3



# FUNCTIONS
# wait for subprocess completion: src: https://stackoverflow.com/questions/356100/how-to-wait-in-bash-for-several-subprocesses-to-finish-and-return-exit-code-0,by https://stackoverflow.com/users/2635443/orsiris-de-jong
function WaitForTaskCompletion {
    local pids="${1}" # pids to wait for, separated by semi-colon
    local soft_max_time="${2}" # If execution takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
    local hard_max_time="${3}" # If execution takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
    local caller_name="${4}" # Who called this function
    local exit_on_error="${5:-false}" # Should the function exit program on subprocess errors       

    Logger "${FUNCNAME[0]} called by [$caller_name]."

    local soft_alert=0 # Does a soft alert need to be triggered, if yes, send an alert once 
    local log_ttime=0 # local time instance for comparaison

    local seconds_begin=$SECONDS # Seconds since the beginning of the script
    local exec_time=0 # Seconds since the beginning of this function

    local retval=0 # return value of monitored pid process
    local errorcount=0 # Number of pids that finished with errors

    local pidCount # number of given pids

    IFS=';' read -a pidsArray <<< "$pids"
    pidCount=${#pidsArray[@]}

    while [ ${#pidsArray[@]} -gt 0 ]; do
        newPidsArray=()
        for pid in "${pidsArray[@]}"; do
            if kill -0 $pid > /dev/null 2>&1; then
                newPidsArray+=($pid)
            else
                wait $pid
                result=$?
                if [ $result -ne 0 ]; then
                    errorcount=$((errorcount+1))
                    Logger "${FUNCNAME[0]} called by [$caller_name] finished monitoring [$pid] with exitcode [$result]."
                fi
            fi
        done

        ## Log a standby message every hour
        exec_time=$(($SECONDS - $seconds_begin))
        if [ $((($exec_time + 1) % 3600)) -eq 0 ]; then
            if [ $log_ttime -ne $exec_time ]; then
                log_ttime=$exec_time
                Logger "Current tasks still running with pids [${pidsArray[@]}]."
            fi
        fi

        if [ $exec_time -gt $soft_max_time ]; then
            if [ $soft_alert -eq 0 ] && [ $soft_max_time -ne 0 ]; then
                Logger "Max soft execution time exceeded for task [$caller_name] with pids [${pidsArray[@]}]."
                soft_alert=1
                SendAlert

            fi
            if [ $exec_time -gt $hard_max_time ] && [ $hard_max_time -ne 0 ]; then
                Logger "Max hard execution time exceeded for task [$caller_name] with pids [${pidsArray[@]}]. Stopping task execution."
                kill -SIGTERM $pid
                if [ $? == 0 ]; then
                    Logger "Task stopped successfully"
                else
                    errrorcount=$((errorcount+1))
                fi
            fi
        fi

        pidsArray=("${newPidsArray[@]}")
        sleep 1
    done

    Logger "${FUNCNAME[0]} ended for [$caller_name] using [$pidCount] subprocesses with [$errorcount] errors."
    if [ $exit_on_error == true ] && [ $errorcount -gt 0 ]; then
        Logger "Stopping execution."
        exit 1337
    else
        return $errorcount
    fi
}

# Just a plain stupid logging function to replace with yours
function Logger {
    local value="${1}"

    echo $value
}

function node2pod {
	# parameters: NODE, seq in PodsArray
	local _node=${1}
	local _seq=${2}
	local _podarray
	local _runpod
	local _podrole
	local _instance
	local _fail=0
	local _return
	local _empty # this is the value for an entry in return string


	
	# check actual nodename with nodename for pod in list to avoid mistakes
	IFS=':' read -a _podarray <<< ${PodsArray[$_seq]}
	if [ ${_podarray[0]} = "$_node" ]; then
		_runpod=${_podarray[1]}
		 _podrole=`echo $_runpod|cut -c1-3`
		if [ "$_podrole" = "rgw" -o "$_podrole" = "osd" ]; then
			_instance=`echo $_runpod|cut -c4-8`
			if [ $_instance -gt 5000 ]; then
				Logger "WARNING: OSD numbers greater than 5000 not supported - skipping instance"
				_fail=1		
			fi
		else
			_instance="-1"
		fi
	else
		Logger "FATAL: nodename for pod does not match the actual nodename - stopped. Check pod list"
		_fail=2
	fi
	if [ $_fail -eq 0 ]; then
		_return=$_fail@$_node@$_podrole@$_instance
	else
		_return=$_fail@-1@-1@"-1"
	fi
	echo $_return
}

function podname {
	# parameters: ID_SET
	local _idarray
	local _podname
	IFS='@' read -a _idarray <<< "$1"
	if [ ${_idarray[0]} -ne 0 ]; then
		Logger "FATAL: getting pod name for node $_NODE failed. Stop testing."
		exit 2
	elif [ ${_idarray[2]} = "rgw" ]; then
		# format: ceph-rgw-ceph04-n01-rgw0
		_PODNAME="ceph-${_idarray[2]}-${_idarray[1]}-${_idarray[2]}${_idarray[3]}"
	elif [ ${_idarray[2]} = "osd" ]; then
		# format: ceph-osd-3
		_PODNAME="ceph-${_idarray[2]}-${_idarray[3]}"
	else
		# format: ceph-mon-ceph04-n01
		# format: ceph-mds-ceph04-n01
		# format: ceph-mgr-ceph04-n01
		_PODNAME="ceph-${_idarray[2]}-${_idarray[1]}"
	fi
	echo $_PODNAME
}

function checkfillgrade {
	# parameters
	local _containerised=$1

	local _last_NodesArray=`expr ${#NodesArray[@]} - 1`
	local _act_fill
	local _seq
	local _node
	local _id_set
	local _podman

	for _seq in `seq 0 $_last_NodesArray`; do
		_node=${NodesArray[$_seq]}
		if [ $_containerised -eq 1 ]; then
			local _id_set=$(node2pod $_node $_seq)
			local _podname=$(podname $_id_set)
			_act_fill=`ssh $BENCH_HOSTS_USER@$_node podman exec $_podname ceph osd df|grep -v AVAIL|awk '{print $17}'|cut -d. -f1|sort -unr|head -1` 
		else
			_act_fill=`ssh $BENCH_HOSTS_USER@$_node ceph osd df|grep -v AVAIL|awk '{print $17}'|cut -d. -f1|sort -unr|head -1`
		fi
		break
	done
	echo "$_act_fill"
}

############
# MAIN
############
# preset of tracking variables - that's a simply counter for the number of runs of the set
TEST_RUN=0
# generate arrays from the lists
IFS=';' read -a NodesArray <<< "$BENCH_NODELIST"
nodesCount=${#NodesArray[@]}
last_NodesArray=`expr ${#NodesArray[@]} - 1`
if [ $CONTAINERISED -eq 1 ]; then
	IFS=';' read -a PodsArray <<< "$BENCH_PODS"
	podsCount=${#PodsArray[@]}
fi
IFS=';' read -a PoolsArray <<< "$BENCH_POOLS"
poolsCount=${#PoolsArray[@]}


# check for 'ceph osd df' command to work and has the expected format
# Since Nautilus has a different output now for osd df we'll need to check for proper columns. Different output for other previous versions. 
for _seq in `seq 0 $last_NodesArray`; do
	_NODE=${NodesArray[$_seq]}
	if [ $CONTAINERISED -eq 1 ]; then
		_ID_SET=$(node2pod $_NODE $_seq)
		_PODNAME=$(podname $_ID_SET)
		if [ `ssh $BENCH_HOSTS_USER@$_NODE podman exec $_PODNAME ceph osd df|grep AVAIL|wc -w` -ne 15 ]; then
			Logger "Ceph cluster seems to use an older version which this tool isn't tested anymore with. Currently tested version is Nautilus. Stopping testing."
			exit 5
		fi
	else
		ssh $BENCH_HOSTS_USER@$_NODE ceph osd df 2>/dev/null >/dev/null
		if [ $? -ne 0 ]; then
			Logger "FATAL: ceph command does not work on first node: $_NODE - is required, with proper permissions"
			exit 1
		fi 
		if [ `ssh $BENCH_HOSTS_USER@$_NODE podman exec $_PODNAME ceph osd df|grep AVAIL|wc -w` -ne 15 ]; then
			Logger "Ceph cluster seems to use an older version which this tool isn't tested anymore with. Currently tested version is Nautilus. Stopping testing."
			exit 5
		fi
	fi
	break
done


# run until fill grade reaches $BENCH_CEPHFILL
while test : ; do
	TEST_RUN=`expr $TEST_RUN + 1`
	_TIME=`date +'%Y-%m-%d=%H_%M_%S'`
	# check status of fill grade
# the following line focused on the overall available capacity in the cluster while
#    ignoring the actual pool CRUSH rule. OSD became full before we could stop on certain 
#    fill grade and stopped the whole thing. With new focus on any OSD fill grade,
#    we stop if any of the OSDs become near full. (Anyway, cluster will not accept any writes
#    when nearfull is reached for at least one OSD.)

	_ACT_FILL=$(checkfillgrade $CONTAINERISED)
	if [ $_ACT_FILL -gt $BENCH_CEPHFILL ]; then
		echo "$_TIME STOP: fill grade $_ACT_FILL of $BENCH_CEPHFILL reached."
		echo "$_TIME INFO: Please remove all test images created"
		exit 1
	elif [ $_ACT_FILL -gt 80 ]; then
		echo "$_TIME STOP: fill grade $_ACT_FILL is over 80% - stopping to prevent from production impact."
		echo "$_TIME INFO: Please remove all test images created"
		exit 1
	else
		echo "$_TIME FILL GRADE: current fill grade $_ACT_FILL of $BENCH_CEPHFILL stop mark"
	fi


	# 
	# write benchmark (leave data there)
	#
	_PIDS=
	BENCH_MODE=write

	for _RUN in `seq 1 $PARALLEL_BENCH`; do
		last_NodesArray=`expr ${#NodesArray[@]} - 1`

		for _seq in `seq 0 $last_NodesArray`; do
			_NODE=${NodesArray[$_seq]}
			_POOL=${PoolsArray[$_seq]}
			_RUN_NAME="$_TIME+$_NODE+$_POOL+$_RUN+$TEST_RUN+$BENCH_MODE"

			if [ $_RUN -le $PARALLEL_BENCH ]; then
	    			if [ $CONTAINERISED -eq 1 ]; then
					_ID_SET=$(node2pod $_NODE $_seq)
					_PODNAME=$(podname $_ID_SET)
					Logger "Starting @$_NODE rados bench -p $_POOL $BENCH_RUNTIME $BENCH_MODE -b $BENCH_IOSIZE -t $BENCH_THREADS --no-cleanup --run-name \"$_RUN_NAME\" - in container $_PODNAME"
					ssh $BENCH_HOSTS_USER@$_NODE podman exec ${_PODNAME} rados bench -p $_POOL $BENCH_RUNTIME $BENCH_MODE -b $BENCH_IOSIZE -t $BENCH_THREADS --no-cleanup --run-name $_RUN_NAME | tee > $_RUN_NAME.log &
				else
					Logger "Starting @$_NODE rados bench -p $_POOL $BENCH_RUNTIME $BENCH_MODE -b $BENCH_IOSIZE -t $BENCH_THREADS --no-cleanup --run-name \"$_RUN_NAME\""
					ssh $BENCH_HOSTS_USER@$_NODE rados bench -p $_POOL $BENCH_RUNTIME $BENCH_MODE -b $BENCH_IOSIZE -t $BENCH_THREADS --no-cleanup --run-name $_RUN_NAME | tee > $_RUN_NAME.log &
				fi
				if [ -z $_PIDS ]; then
					_PIDS="$!"
					_RUNArray="$_NODE@$_PODNAME@$_POOL@$_RUN_NAME"
				else
					_PIDS="$_PIDS;$!"
					_RUNArray="$_RUNArray $_NODE@$_PODNAME@$_POOL@$_RUN_NAME"
				fi
			else
				break
			fi
		done
	done

	# wait for all rados bench commands to complete; upon program failures exit (true)
	WaitForTaskCompletion $_PIDS $BENCH_JOB_WARNTIME $BENCH_JOB_TERMTIME main\(\) true

	if [ $nodesCount -gt 1 ]; then
		sleep $BENCH_MULTIHOST_WAIT_BEFORE_READ
	fi
	# 
	# read benchmark - based on previously written objects (using the same name); output file will be named for read
	#
	_PIDS=
	BENCH_MODE=rand
        for _WNRUN in `echo $_RUNArray`; do
		IFS='@' read -a _ID_READ <<< $_WNRUN
		_RNODE=`echo $_WNRUN|cut -d@ -f1`
		_RPOD=`echo $_WNRUN|cut -d@ -f2`
		_RPOOL=`echo $_WNRUN|cut -d@ -f4`
		_WRUN=`echo $_WNRUN|cut -d@ -f5`
		_RUN_NAME="$_TIME+${_ID_READ[0]}+${_ID_READ[2]}+$_RUN+$TEST_RUN+$BENCH_MODE"

		if [ $CONTAINERISED -eq 1 ]; then
			Logger "Starting ${_ID_READ[0]} rados bench -p ${_ID_READ[2]} $BENCH_RUNTIME $BENCH_MODE -t $BENCH_THREADS --no-cleanup --run-name \"${_ID_READ[3]}\" - in container ${_ID_READ[1]}"
			ssh $BENCH_HOSTS_USER@${_ID_READ[0]} podman exec ${_ID_READ[1]} rados bench -p ${_ID_READ[2]} $BENCH_RUNTIME $BENCH_MODE -t $BENCH_THREADS --no-cleanup --run-name ${_ID_READ[3]} | tee >> ${_ID_READ[3]}.log &
		else
			Logger "Starting @${_ID_READ[0]} rados bench -p ${_ID_READ[2]} $BENCH_RUNTIME $BENCH_MODE -t $BENCH_THREADS --run-name ${_ID_READ[3]}"

			ssh $BENCH_HOSTS_USER@$_RNODE rados bench -p $_RPOOL $BENCH_RUNTIME $BENCH_MODE -t $BENCH_THREADS --run-name ${_ID_READ[3]} | tee >> ${_ID_READ[3]}.log &
		fi
		if [ -z $_PIDS ]; then
			_PIDS="$!"
		else
			_PIDS="$_PIDS;$!"
		fi
	done

	# wait for all rados bench commands to complete; upon program failures exit (true)
	WaitForTaskCompletion $_PIDS $BENCH_JOB_WARNTIME $BENCH_JOB_TERMTIME main\(\) true
	# wait for next run to settle fill grade information from ceph osd df
	sleep 5
done

# Hint for cleanup: based on the file names created, use the following scriptlet to properly remove the benchmark allocated objects, since those need to be removed from proper owner, i.e. the node.
#for i in `ls 2019*`; do  node=`echo $i|cut -d+ -f2`; pool=`echo $i|cut -d+ -f3`; name=`echo $i|cut -d. -f1`; ssh root@$node rados cleanup -p $pool --run-name $name; done
