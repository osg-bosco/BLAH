#!/bin/bash
#
# File:     lsf_submit.sh
# Author:   David Rebatto (david.rebatto@mi.infn.it)
#
# Revision history:
#     8-Apr-2004: Original release
#    28-Apr-2004: Patched to handle arguments with spaces within (F. Prelz)
#                 -d debug option added (print the wrapper to stderr without submitting)
#    10-May-2004: Patched to handle environment with spaces, commas and equals
#    13-May-2004: Added cleanup of temporary file when successfully submitted
#    18-May-2004: Search job by name in log file (instead of searching by jobid)
#     8-Jul-2004: Try a chmod u+x on the file shipped as executable
#                 -w option added (cd into submission directory)
#    21-Sep-2004: -q option added (queue selection)
#    29-Sep-2004: -g option added (gianduiotto selection) and job_ID=job_ID_log
#    13-Jan-2005: -n option added (MPI job selection) and changed prelz@mi.infn.it with
#                    blahp_sink@mi.infn.it
#     4-Mar-2005: Dgas(gianduia) removed. Proxy renewal stuff added (-r -p -l flags)
#     3-May-2005: Added support for Blah Log Parser daemon (using the lsf_BLParser flag)
#    31-May-2005: Separated job's standard streams from wrapper's ones
# 
#
# Description:
#   Submission script for LSF, to be invoked by blahpd server.
#   Usage:
#     lsf_submit.sh -c <command> [-i <stdin>] [-o <stdout>] [-e <stderr>] [-w working dir] [-- command's arguments]
#
#
#  Copyright (c) 2004 Istituto Nazionale di Fisica Nucleare (INFN).
#  All rights reserved.
#  See http://grid.infn.it/grid/license.html for license details.
#
#

[ -f ${GLITE_LOCATION:-/opt/glite}/etc/blah.config ] && . ${GLITE_LOCATION:-/opt/glite}/etc/blah.config

conffile=$lsf_confpath/lsf.conf

lsf_base_path=`cat $conffile|grep LSB_SHAREDIR| awk -F"=" '{ print $2 }'`

lsf_confdir=`cat $conffile|grep LSF_CONFDIR| awk -F"=" '{ print $2 }'`
[ -f ${lsf_confdir}/profile.lsf ] && . ${lsf_confdir}/profile.lsf

lsf_clustername=`${lsf_binpath}/lsid | grep 'My cluster name is'|awk -F" " '{ print $5 }'`
logpath=$lsf_base_path/$lsf_clustername/logdir

logfilename=lsb.events

stgcmd="yes"
workdir="."

proxyrenewald="${GLITE_LOCATION:-/opt/glite}/bin/BPRserver"

proxy_dir=~/.blah_jobproxy_dir

stgproxy="yes"

#default is to stage proxy renewal daemon 
proxyrenew="yes"

if [ ! -r $proxyrenewald ]
then
  unset proxyrenew
fi

#default values for polling interval and min proxy lifetime
prnpoll=30
prnlifetime=0

srvfound=""

BLClient="${GLITE_LOCATION:-/opt/glite}/bin/BLClient"

###############################################################
# Parse parameters
###############################################################

while getopts "i:o:e:c:s:v:V:dw:q:n:rp:l:x:j:T:I:O:R:C:" arg 
do
    case "$arg" in
    i) stdin="$OPTARG" ;;
    o) stdout="$OPTARG" ;;
    e) stderr="$OPTARG" ;;
    v) envir="$OPTARG";;
    V) environment="$OPTARG";;
    c) the_command="$OPTARG" ;;
    s) stgcmd="$OPTARG" ;;
    d) debug="yes" ;;
    w) workdir="$OPTARG";;
    q) queue="$OPTARG";;
    n) mpinodes="$OPTARG";;
    r) proxyrenew="yes" ;;
    p) prnpoll="$OPTARG" ;;
    l) prnlifetime="$OPTARG" ;;
    x) proxy_string="$OPTARG" ;;
    j) creamjobid="$OPTARG" ;;
    T) temp_dir="$OPTARG" ;;
    I) inputflstring="$OPTARG" ;;
    O) outputflstring="$OPTARG" ;;
    R) outputflstringremap="$OPTARG" ;;
    C) req_file="$OPTARG";;
    -) break ;;
    ?) echo $usage_string
       exit 1 ;;
    esac
done

# Command is mandatory
if [ "x$the_command" == "x" ]
then
    echo $usage_string
    exit 1
fi

shift `expr $OPTIND - 1`
arguments=$*

if [ "x$lsf_nologaccess" != "xyes" -a "x$lsf_nochecksubmission" != "xyes" ]; then

#Try different log parser
 if [ ! -z $lsf_num_BLParser ] ; then
  for i in `seq 1 $lsf_num_BLParser` ; do
   s=`echo lsf_BLPserver${i}`
   p=`echo lsf_BLPport${i}`
   eval tsrv=\$$s
   eval tport=\$$p
   testres=`echo "TEST/"|$BLClient -a $tsrv -p $tport`
   if [ "x$testres" == "xYLSF" ] ; then
    lsf_BLPserver=$tsrv
    lsf_BLPport=$tport
    srvfound=1
    break
   fi
  done
  if [ -z $srvfound ] ; then
   echo "1ERROR: not able to talk with no logparser listed"
   exit 0
  fi
 fi
fi

###############################################################
# Create wrapper script
###############################################################

curdir=`pwd`
if [ -z "$temp_dir"  ] ; then
    temp_dir="$curdir"
else
    if [ ! -e $temp_dir ] ; then
        mkdir -p $temp_dir
    fi
    if [ ! -d $temp_dir -o ! -w $temp_dir ] ; then
        echo "1ERROR: unable to create or write to $temp_dir"
        exit 0
    fi
fi

# Get a suitable name for temp file
if [ "x$debug" != "xyes" ]
then
    if [ ! -z "$creamjobid"  ] ; then
        tmp_name="cream_${creamjobid}"
        tmp_file="$temp_dir/$tmp_name"
    else
        tmp_name=blahjob_$RANDOM$RANDOM$RANDOM
        tmp_file="$temp_dir/$tmp_name"
        `touch $tmp_file;chmod 600 $tmp_file`
    fi
    if [ $? -ne 0 ]; then
        echo Error
        exit 1
    fi
else
    # Just print to stderr if in debug
    tmp_file="/proc/$$/fd/2"
fi

# Create unique extension for filename
uni_uid=`id -u`
uni_pid=$$
uni_time=`date +%s`
uni_ext=$uni_uid.$uni_pid.$uni_time

# Create date for output string
datenow=`date +%Y%m%d%H%M.%S`

# Write wrapper preamble
cat > $tmp_file << end_of_preamble
#!/bin/bash
# LSF job wrapper generated by `basename $0`
# on `/bin/date`
#
# LSF directives:
#BSUB -L /bin/bash
#BSUB -J $tmp_name
end_of_preamble

#set the queue name first, so that the local script is allowed to change it
#(as per request by CERN LSF admins).
# handle queue overriding
[ -z "$queue" ] || grep -q "^#BSUB -q" $tmp_file || echo "#BSUB -q $queue" >> $tmp_file

#local batch system-specific file output must be added to the submit file
if [ ! -z $req_file ] ; then
    echo \#\!/bin/sh >> ${req_file}-temp_req_script 
    cat $req_file >> ${req_file}-temp_req_script
    echo "source ${GLITE_LOCATION:-/opt/glite}/bin/lsf_local_submit_attributes.sh" >> ${req_file}-temp_req_script 
    chmod +x ${req_file}-temp_req_script 
    ${req_file}-temp_req_script  >> $tmp_file 2> /dev/null
    rm -f ${req_file}-temp_req_script 
    rm -f $req_file
fi

# Write LSF directives according to command line options

# Setup the standard streams
if [ ! -z "$stdin" ] ; then
    if [ -f "$stdin" ] ; then
        stdin_unique=`basename $stdin`.$uni_ext
        echo "#BSUB -f \"$stdin > $stdin_unique\"" >> $tmp_file
        arguments="$arguments <\"$stdin_unique\""
        to_be_moved="$to_be_moved $stdin_unique"
    else
        arguments="$arguments <$stdin"
    fi
fi
if [ ! -z "$stdout" ] ; then
    if [ "${stdout:0:1}" != "/" ] ; then
        local_stdout="${workdir}/${stdout}"
    else
        local_stdout=$stdout
    fi
    stdout_unique=`basename $stdout`.$uni_ext
    arguments="$arguments >\"$stdout_unique\""
    echo "#BSUB -f \"$stdout < home_${tmp_name}/${stdout_unique}\"" >> $tmp_file
fi
if [ ! -z "$stderr" ] ; then
    if [ "$stderr" == "$stdout" ]; then
        arguments="$arguments 2>&1"
    else
        if [ "${stderr:0:1}" != "/" ] ; then
            local_stderr="${workdir}/${stderr}"
        else
            local_stderr=$stderr
        fi
        stderr_unique=`basename $stderr`.$uni_ext
        arguments="$arguments 2>\"$stderr_unique\""
        echo "#BSUB -f \"$stderr < home_${tmp_name}/$stderr_unique\"" >> $tmp_file
    fi
fi

# Set the remaining parameters
if [ "x$proxyrenew" == "xyes" ]
then
    echo "#BSUB -f \"$proxyrenewald > `basename $proxyrenewald`.$uni_ext\"" >> $tmp_file
    to_be_moved="$to_be_moved `basename $proxyrenewald`.$uni_ext"
fi

if [ "x$stgcmd" == "xyes" ] 
then
    echo "#BSUB -f \"$the_command > `basename $the_command`\"" >> $tmp_file
    to_be_moved="$to_be_moved `basename $the_command`"
fi

[ -z "$mpinodes" ]       || echo "#BSUB -n $mpinodes" >> $tmp_file
#CONVERTIRE PER LSF
#absolute paths
 if [ ! -z "$inputflstring" ] ; then
         exec 4<> "$inputflstring"
         while read xfile <&4 ; do
               if [ ! -z $xfile  ] ; then
		       echo "#BSUB -f \"$xfile > `basename $xfile`\"" >> $tmp_file
               fi
         done
         exec 4<&-
       rm -f $inputflstring
 fi

xfile=
xfilesandbox=
#Add files to transfer from execution node
 if [ ! -z "$outputflstring" ] ; then
        exec 5<> "$outputflstring"
        if [ ! -z "$outputflstringremap" ] ; then
                exec 6<> "$outputflstringremap"
        fi
        while read xfile <&5 ; do
               if [ ! -z $xfile  ] ; then
                       if [ ! -z "$outputflstringremap" ] ; then
                                read xfileremap <&6
                       fi
                       if [ ! -z $xfileremap ] ; then
                                if [ "${xfileremap:0:1}" != "/" ] ; then
                                        xfilesandbox="${workdir}/${xfileremap}"
                                else
                                        xfilesandbox="${xfileremap}"
                                fi
                        else
                                if [ "${xfile:0:1}" != "/" ] ; then
                                        xfilesandbox="${workdir}/${xfile}"
                                else
                                        xfilesandbox="${xfile}"
                                fi
                        fi
		        echo "#BSUB -f \"$xfilesandbox < $xfile\"" >> $tmp_file
               fi
         done
         exec 5<&-
         exec 6<&-
         rm -f $outputflstring
         if [ ! -z "$outputflstringremap" ] ; then
                rm -f $outputflstringremap
         fi
 fi

# Setup proxy transfer
if [ "x$stgproxy" == "xyes" ] ; then
    proxy_local_file=${workdir}"/"`basename "$proxy_string"`
    [ -r "$proxy_local_file" -a -f "$proxy_local_file" ] || proxy_local_file=$proxy_string
    [ -r "$proxy_local_file" -a -f "$proxy_local_file" ] || proxy_local_file=/tmp/x509up_u`id -u`
    if [ -r "$proxy_local_file" -a -f "$proxy_local_file" ] ; then
        proxy_unique=${tmp_name}.${uni_ext}.proxy
        echo "#BSUB -f \"$proxy_local_file > $proxy_unique\"" >> $tmp_file
        to_be_moved="$to_be_moved $proxy_unique"
    fi
fi

# Accommodate for CERN-specific job subdirectory creation.
echo "" >> $tmp_file
echo "# Check whether we need to move to the LSF original CWD:" >> $tmp_file
echo "if [ -d \"\$CERN_STARTER_ORIGINAL_CWD\" ]; then" >> $tmp_file
echo "    cd \$CERN_STARTER_ORIGINAL_CWD" >> $tmp_file
echo "fi" >> $tmp_file

# Set the required environment variables (escape values with double quotes)
if [ "x$environment" != "x" ] ; then
        echo "" >> $tmp_file
        echo "# Setting the environment:" >> $tmp_file
        eval "env_array=($environment)"
        for  env_var in "${env_array[@]}"; do
                 echo export \"$env_var\" >> $tmp_file
        done
else
	if [ "x$envir" != "x" ] ; then
    		echo "" >> $tmp_file
    		echo "# Setting the environment:" >> $tmp_file
    		echo "export `echo ';'$envir |sed -e 's/;[^=]*;/;/g' -e 's/;[^=]*$//g' | sed -e 's/;\([^=]*\)=\([^;]*\)/ \1=\"\2\"/g'`" >> $tmp_file
	#'#
	fi
fi

# Set the temporary home (including cd'ing into it)
echo "mkdir ~/home_$tmp_name">>$tmp_file
[ -z "$to_be_moved" ] || echo "mv $to_be_moved ~/home_$tmp_name &>/dev/null">>$tmp_file
echo "export HOME=~/home_$tmp_name">>$tmp_file
echo "cd">>$tmp_file

# Set the path to the user proxy
if [ ! -z $proxy_unique ] ; then 
    echo "export X509_USER_PROXY=\`pwd\`/$proxy_unique" >> $tmp_file
fi

# Add the command (with full path if not staged)
echo "" >> $tmp_file
echo "# Command to execute:" >> $tmp_file
if [ "x$stgcmd" == "xyes" ] ; then
    the_command="./`basename $the_command`"
    echo "if [ ! -x $the_command ]; then chmod u+x $the_command; fi" >> $tmp_file
    # God *really* knows why LSF doesn't like a 'dot' in here
    # To be investigated further. prelz@mi.infn.it 20040911
    echo "\`pwd\`/`basename $the_command` $arguments &" >> $tmp_file
else
    echo "$the_command $arguments &" >> $tmp_file
fi

echo "job_pid=\$!" >> $tmp_file

if [ ! -z $proxyrenew ] ; then
    echo "if [ ! -x `basename $proxyrenewald`.$uni_ext ]; then chmod u+x `basename $proxyrenewald`.$uni_ext; fi" >> $tmp_file
    echo "\`pwd\`/`basename $proxyrenewald`.$uni_ext \$job_pid $prnpoll $prnlifetime \${LSB_JOBID} &" >> $tmp_file
    echo "server_pid=\$!" >> $tmp_file
fi
echo "wait \$job_pid" >> $tmp_file
echo "user_retcode=\$?" >> $tmp_file

if [ ! -z "$proxyrenew" ] ; then
    echo ""  >> $tmp_file
    echo "# Wait for the proxy renewal daemon to exit" >> $tmp_file
    echo "sleep 1" >> $tmp_file
    echo "kill \$server_pid 2> /dev/null" >> $tmp_file
fi

if [ ! -z "$to_be_moved" ] ; then
    echo ""  >> $tmp_file
    echo "# Remove the staged files" >> $tmp_file
    echo "rm $to_be_moved" >> $tmp_file
fi

# We cannot remove the output files, as they have to be transferred back to the CE
# echo "cd .." >> $tmp_file
# echo "rm -rf \$HOME" >> $tmp_file

echo ""  >> $tmp_file
echo "exit \$user_retcode" >> $tmp_file

# Exit if it was just a test
if [ "x$debug" == "xyes" ]
then
    exit 255
fi

# Let the wrap script be at least 1 second older than logfile
# for subsequent "find -newer" command to work
sleep 1


###############################################################
# Submit the script
###############################################################

cd $workdir
if [ $? -ne 0 ]; then
    echo "Failed to CD to Initial Working Directory." >&2
    echo Error # for the sake of waiting fgets in blahpd
    exit 1
fi

jobID=`cd && ${lsf_binpath}/bsub -o /dev/null -e /dev/null -i /dev/null < $tmp_file | awk -F" " '{ print $2 }' | sed "s/>//" |sed "s/<//"`

retcode=$?
if [ "$retcode" != "0" ] ; then
        rm -f $tmp_file
        exit 1
fi

if [ "x$lsf_nologaccess" != "xyes" -a "x$lsf_nochecksubmission" != "xyes" ]; then

# Don't trust bsub retcode, it could have crashed
# between submission and id output, and we would
# loose track of the job

# Search for the job in the logfile using job name

# Sleep for a while to allow job enter the queue
sleep 5

# find the correct logfile (it must have been modified
# *more* recently than the wrapper script)

logfile=""
jobID_log=""
log_check_retry_count=0
tfbasename="`basename ${tmp_file}`"

while [ "x$logfile" == "x" -a "x$jobID_log" == "x" ]; do

 cliretcode=0
 if [ "x$lsf_BLParser" == "xyes" ] ; then
     jobID_log=`echo BLAHJOB/$tmp_name| $BLClient -a $lsf_BLPserver -p $lsf_BLPport`
     cliretcode=$?
 fi
 
 if [ "$cliretcode" == "1" -a "x$lsf_fallback" == "xno" ] ; then
   ${lsf_binpath}/bkill $jobID
   echo "Error: not able to talk with logparser on ${lsf_BLPserver}:${lsf_BLPport}" >&2
   echo Error # for the sake of waiting fgets in blahpd
   rm -f $tmp_file
   exit 1
 fi

 if [ "$cliretcode" == "1" -o "x$lsf_BLParser" != "xyes" ] ; then

   logfile=`find $logpath -name "$logfilename.*" -type f -newer $tmp_file -exec grep -lP "\"JOB_NEW\" \"[0-9\.]+\" [0-9]+ $jobID " {} \;`

   if [ "x$logfile" != "x" ] ; then

     jobID_log=`grep \"JOB_NEW\" $logfile | awk -F" " '{ print $4" " $42 }' | grep $tmp_file|awk -F" " '{ print $1 }'`
   fi
 fi
 
 if (( log_check_retry_count++ >= 12 )); then
     ${lsf_binpath}/bkill $jobID
     echo "Error: job not found in logs" >&2
     echo Error # for the sake of waiting fgets in blahpd
     rm -f $tmp_file
     exit 1
 fi

 let "bsleep = 2**log_check_retry_count"
 sleep $bsleep

done

jobID_check=`echo $jobID_log|egrep -e "^[0-9]+$"`

if [ "$jobID_log" != "$jobID" -a "x$jobID_log" != "x" -a "x$jobID_check" != "x" ]; then
    echo "WARNING: JobID in log file is different from the one returned by bsub!" >&2
    echo "($jobID_log != $jobID)" >&2
    echo "I'll be using the one in the log ($jobID_log)..." >&2
    jobID=$jobID_log
fi

fi #end if on $lsf_nologaccess

# Compose the blahp jobID (date + lsf jobid)
echo ""
echo "BLAHP_JOBID_PREFIXlsf/${datenow}/$jobID"

# Clean temporary files
cd $temp_dir
rm -f $tmp_file

# Create a softlink to proxy file for proxy renewal
if [ -r "$proxy_local_file" -a -f "$proxy_local_file" ] ; then
    [ -d "$proxy_dir" ] || mkdir $proxy_dir
    ln -s $proxy_local_file $proxy_dir/$jobID.proxy
fi

exit $retcode
