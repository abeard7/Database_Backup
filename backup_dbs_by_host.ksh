#!/bin/ksh

###################################################################
# Script name: backup_dbs_by_host.ksh
# Date Created: 08/26/2020
# Author: Aaron Beard
#A
# usage is backup_dbs_by_host.ksh hostname
#
# Modified: yyyy-mm-dd dba - Making change to ?????
#           2020-08-26 Aaron Beard New Script
#           2021-02-19 Aaron Beard - modified to resolve issue with long running backups (over 1 hour) causing network timeout and not reporting back to DSM or the log file.
#           2021-03-03 Aaron Beard - Changed the ssh call to nohup and to check processing on the dbmgr host. This finally resolved the ssh timeout.
#           2021-05-04 Aaron Beard - Added touch for tmpfile to make sure NAS directory is available. Error out if not.
#           2021-06-12 Aaron Beard - Added logic to use 6 sessions if running backups on the Purescale hosts to get run time down.
#           2021-07-27 Aaron Beard - Modified to run under new service account dmcsvc
#           2021-09-22 Aaron Beard - Added optional environment parm and case statement to allow UNIT/INTG to run on member 1 and DEVL/PERF to run on member 2 in pureScale.
#           2022-03-11 Aaron Beard - Added logic for third retry on failed backups while TSM issues persist.
#           2022-05-09 Aaron Beard - Modified to use /DB2LUW/DMC/mail.lst to get list of email addresses
#           2022-09-21 Aaron Beard - Mondified to move first output to log file to top of script to try and troubleshoot DMC issues where script does not look like it is even starting.
#
###################################################################
#set -x
hname=$1

logpath=/DB2LUW/DMC/logs
scriptpath=/DB2LUW/DMC/scripts

if [ $# -gt 1 ]
then
   env=$2
   where_clause="and DB_ENV_TYPE = '${env}'"
   hostlist=${logpath}/backup_dbs_on_host_${hname}_${env}.lst
   logfile=${logpath}/${hname}_backups.${env}.`date +%Y%m%d%H%M%S`.log
else
   env=""
   where_clause=""
   hostlist=${logpath}/backup_dbs_on_host_${hname}.lst
   logfile=${logpath}/${hname}_backups.`date +%Y%m%d%H%M%S`.log
fi

# Aaron Beard - Moved this code to be the first thing executed to troubleshoot DMC issues.
#############################################
# Start the backup process for host passed in
#############################################

echo "backup_dbs_by_host.ksh $hname is starting : " `date` > $logfile
echo "" >> $logfile

. /db2home/udbinst1/sqllib/db2profile

integer hourelapsed1=0
integer hourelapsed2=0

find $logpath -name "${hname}_backups.*" -type f -mtime +30 -exec rm -f {} \;
maillist=`cat /DB2LUW/DMC/scripts/mail.lst`

start_time="$(date -u +%s)"

####################################################################################
#  Function to backup the database using nohup to prevent issues with ssh timing out
####################################################################################
backup_db ()
{
nohup ssh -n ${C} ". /db2home/${B}/sqllib/db2profile ${B} ${C} ${D} $tmpfile ""$( cat <<'EOT'

inst=$1
server=$2
dbase=$3
tmpfile=$4

. /db2home/${inst}/sqllib/db2profile

#making numsessions 6 by default. Remove logic if no issues or change back if running out of sessions.
numsessions=6

db2 -v "backup db $dbase online use tsm open $numsessions sessions WITHOUT PROMPTING" > $tmpfile

EOT
)" > /dev/null 2>/dev/null&

sleep 90

####################################################################################
# Wait in while loop until there is output from the backup command executed in nohup
####################################################################################

cmd="egrep -c \"Backup successful|SQL\" $tmpfile"
ssh -n ${C} -q ${cmd} | read check

integer x=0

if [ $check -eq 0 ]
then
   while (true)
   do
      sleep 120
      ssh -n ${C} -q ${cmd} | read check

      if [ $check -gt 0 ]
      then
         break
      fi
      let x=$x+1
      if [ $x -eq 5 ]
      then
         echo "Backup still in progress for ${D} : `date`"  | tee -a $logfile
         x=0
      fi
   done
fi

cmd2="cat $tmpfile ; rm $tmpfile"
ssh -n ${C} -q ${cmd2} > $tmpfile2
cat $tmpfile2 >> $logfile
}

# Aaron Beard - can remove this code if no issues caused by moving it to top of script.
#############################################
# Start the backup process for host passed in
#############################################

#jmkecho "backup_dbs_by_host.ksh $hname is starting : " `date` > $logfile
#jmkecho "" >> $logfile

#############################################
# First, get list of active databases by host
#############################################
db2 connect to dbmgr > /dev/null
if [ $? -ne 0 ]
then
   echo "Error connecting to DBMGR. Exiting...." >> $logfile
   db2 terminate > /dev/null
   exit 8
fi

db2 -x "select DB_INSTANCE_NAME||'         '||DB_SERVER || '         ' || db_database_name from UINST12.DB_INST_SRVR where DB_SERVER =  '${hname}' and ACTIVE_FLAG = 'Y' ${where_clause} order by DB_SERVER, DB_INSTANCE_NAME, db_database_name" > ${hostlist}

db2 terminate > /dev/null

###################################################
# Loop through the database list by host and backup
###################################################

while read line1
do
    A=$line1
    B=$(echo $A | awk '{print $1}' |cut -c1-8)
    C=$(echo $A | awk '{print $2}' |cut -c1-23)
    D=`(echo $A | awk '{print $3}' |cut -c1-10)`
    echo $C | grep -c vdb2psm01 | read check
    if [ $check -eq 1 ]
    then
       case "${env}" in
          "UNIT") C="savdcuvdb2psm02"
          ;;
          "DEVL") C="savdcuvdb2psm03"
          ;;
          "INTG") C="savdcfvdb2psm02"
          ;;
          "PERF") C="savdcfvdb2psm03"
          ;;
          *) date > /dev/null
          ;;
      esac
   fi

    tmpfile=${logpath}/backup_${C}_${B}_${D}.tmpfile
    tmpfile2=${logpath}/backup_${C}_${B}_${D}.tmpfile2

###########################################################
# Call the function to backup the database by host/instance
###########################################################

echo "Start backup of database ${D} `date`" >> $logfile
echo "" >> $logfile

ssh -n ${C} "touch $tmpfile"

if [ $? -ne 0 ]
then
    echo "ERROR: Unable to create $tmpfile on host ${C} using id ${B}. Exiting...." | tee -a $logfile
    rm $tmpfile $tmpfile2 ${hostlist}
    exit 8
fi

end_time="$(date -u +%s)"

elapsed="$(($end_time-$start_time))"

hourelapsed1=`date +%H`
if [ $elapsed -gt 18000 ] && [ $hourelapsed1 != $hourelapsed2 ]
then
    echo "" | mailx -s "Backups running over 5 hours on host $hname. Starting backup of ${D}." $maillist
    hourelapsed2=$hourelapsed1
fi

backup_db

###############################################################
# Once backup is done, check to see if it was successful or not
###############################################################

grep -c "Backup successful" $tmpfile2 | read check
rm $tmpfile2

###################################################################
# If not successful, attempt a second time after waiting 5 minutes
###################################################################

if [ $check -ne 1 ]
then
#changed 4/12/2022   sleep 300
   sleep 60
   echo "" >> $logfile
   echo "First backup attempt failed for database ${D} on host ${C}. Attemping to backup a second time. `date`" >> $logfile
   echo "" >> $logfile

   ssh -n ${C} "touch $tmpfile"

   if [ $? -ne 0 ]
   then
       echo "ERROR: Unable to create $tmpfile on host ${C} using id ${B} during second backup attempt. Exiting...." | tee -a $logfile
       rm $tmpfile $tmpfile2 ${hostlist}
       exit 8
   fi

   backup_db

   grep -c "Backup successful" $tmpfile2 | read check
   rm $tmpfile2

   if [ $check -ne 1 ]
   then
#changed 4/12/2022      sleep 300
      sleep 60
      echo "" >> $logfile
      echo "Second backup attempt failed for database ${D} on host ${C}. Attemping to backup a third and final time. `date`" >> $logfile
      echo "" >> $logfile

      ssh -n ${C} "touch $tmpfile"

      if [ $? -ne 0 ]
      then
          echo "ERROR: Unable to create $tmpfile on host ${C} using id ${B} during third backup attempt. Exiting...." | tee -a $logfile
          rm $tmpfile $tmpfile2 ${hostlist}
          exit 8
      fi

      backup_db

      grep -c "Backup successful" $tmpfile2 | read check
      rm $tmpfile2

      if [ $check -ne 1 ]
      then
         echo "Error backing up ${D} under ${B} on host ${C} during third attempt." >> $logfile
      fi
   fi
fi

echo "End backup of database ${D} `date`" >> $logfile
echo "" >> $logfile


done < ${hostlist}

rm ${hostlist}

##################################################################################################
# Verify the distinct number of backups attempted match the number of backups that were successful
##################################################################################################

successcount=`grep -c "Backup successful" $logfile`
attemptcount=`grep "backup db" $logfile | sort -u | wc -l`

echo "" >> $logfile

if [ $successcount -ne $attemptcount ]
then
   tmpfile=$logpath/$$.tmpfile
   echo "" >> $tmpfile
   echo "Databases that had backup failures after 3 attempts:" >> $tmpfile
   echo "" >> $tmpfile
   grep "during third attempt" $logfile | nawk -F " " '{print "Database: "$4" Instance: "$6" Host: "$9}' >> $tmpfile
   echo "" >> $tmpfile
   msg="Error backing up at least one database on $hname. Please review logfile $logfile"
   echo "${msg}" >> $logfile
   cat $tmpfile >> $logfile
   mailx -s "${msg}" $maillist < $tmpfile
   rm $tmpfile
   rc=8
else
   echo "All databases on host $hname completed successfully." >> $logfile
   rc=0
fi
echo "" >> $logfile
echo "backup_dbs_by_host.ksh $hname is done : " `date` >> $logfile
exit $rc


