#!/bin/bash

# Get the hostname of the server
server_hostname=$(hostname)

# Path to the main CSV file with the hostname included in the filename
output_file="/tmp/${server_hostname}_oracle_databases_info.csv"

# Path to the backup details CSV file
backup_output_file="/tmp/${server_hostname}_oracle_backup_details.csv"

# Path to the feature usage JSON file
feature_usage_output_file="/tmp/${server_hostname}_oracle_feature_usage.json"

# CSV file header for the main file
echo "Hostname,Database Name,Database Size (GB),ArchiveLog Mode,Software Version,Oracle Home,Alert Log Path,Database Role,Device Backup Type" > $output_file

# CSV file header for the backup details file
echo "Hostname,Database Name,Input Type,Status,Start Time,End Time,Input Size (GB),Duration" > $backup_output_file

# Initialize JSON file for feature usage
echo "[" > $feature_usage_output_file

# Reading from /etc/oratab
while read line
do
    # Remove everything after the '#' character
    line=$(echo $line | cut -d'#' -f1)

    # Check if the line is valid and not an +ASM instance
    if [[ $line == *":"* && ! $line == "+ASM:"* ]]; then
        # Extracting database name and ORACLE_HOME path
        db_name=$(echo $line | cut -d':' -f1)
        oracle_home=$(echo $line | cut -d':' -f2)
        oracle_sid=$db_name

        # Setting ORACLE_HOME and ORACLE_SID environment variables
        export ORACLE_HOME=$oracle_home
        export ORACLE_SID=$oracle_sid
        export PATH=$ORACLE_HOME/bin:$PATH

        # Fetching main data from the database
        sql_output=$(sqlplus -s / as sysdba << EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF TIMING OFF LINESIZE 300
SELECT ROUND(SUM(bytes) / 1024 / 1024 / 1024, 2) AS "Size in GB" FROM dba_data_files;
select log_mode from v\$database;
select version from v\$instance;
select value from GV\$DIAG_INFO WHERE name='Diag Trace';
select database_role from v\$database;
SELECT OUTPUT_DEVICE_TYPE AS "DEVICE_BACKUP_TYPE" FROM V\$RMAN_BACKUP_JOB_DETAILS WHERE rownum = 1;
EXIT;
EOF
)

        # Fetching backup details
        backup_details=$(sqlplus -s / as sysdba << EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF TIMING OFF LINESIZE 300
SELECT
    INPUT_TYPE || ',' ||
    STATUS || ',' ||
    TO_CHAR(START_TIME,'mm/dd/yy hh24:mi') || ',' ||
    TO_CHAR(END_TIME,'mm/dd/yy hh24:mi') || ',' ||
    ROUND(INPUT_BYTES/POWER(1024,3), 3) || ',' ||
    LPAD(TRUNC(ELAPSED_SECONDS/3600),2,'0') || ':' || LPAD(TRUNC(MOD(ELAPSED_SECONDS,3600)/60),2,'0')
FROM
    V\$RMAN_BACKUP_JOB_DETAILS
WHERE
    SYSDATE - START_TIME <= 7;
EXIT;
EOF
)

        # Fetching feature usage details and appending to JSON file
        feature_usage=$(sqlplus -s / as sysdba << EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF TIMING OFF LINESIZE 1000 LONG 10000
SELECT
    '{' ||
    '"Hostname": "' || '$server_hostname' || '", ' ||
    '"Database Name": "' || '$db_name' || '", ' ||
    '"Feature Name": "' || REPLACE(NAME, '"', '\"') || '", ' ||
    '"Version": "' || REPLACE(VERSION, '"', '\"') || '", ' ||
    '"Detected Usages": "' || DETECTED_USAGES || '", ' ||
    '"Total Samples": "' || TOTAL_SAMPLES || '", ' ||
    '"Currently Used": "' || CURRENTLY_USED || '", ' ||
    '"First Usage Date": "' || TO_CHAR(FIRST_USAGE_DATE, 'mm/dd/yyyy') || '", ' ||
    '"Last Usage Date": "' || TO_CHAR(LAST_USAGE_DATE, 'mm/dd/yyyy') || '", ' ||
    '"Feature Info": "' || REPLACE(FEATURE_INFO, '"', '\"') || '"},'
FROM
    DBA_FEATURE_USAGE_STATISTICS
WHERE
    CURRENTLY_USED = 'TRUE';
EXIT;
EOF
)

        # Append feature usage data to JSON file
        echo "$feature_usage" >> $feature_usage_output_file

        # Processing the main results
        hostname=$(hostname)
        db_size=$(echo "$sql_output" | sed -n '1p')
        archivelog_mode=$(echo "$sql_output" | sed -n '2p')
        software_version=$(echo "$sql_output" | sed -n '3p')
        alert_log_path=$(echo "$sql_output" | sed -n '4p')
        database_role=$(echo "$sql_output" | sed -n '5p')
        device_backup_type=$(echo "$sql_output" | sed -n '6p')

        # Writing main data to the CSV file
        echo "$hostname,$db_name,$db_size,$archivelog_mode,$software_version,$oracle_home,$alert_log_path,$database_role,$device_backup_type" >> $output_file

        # Writing backup details to the CSV file
        while IFS= read -r backup_line; do
            echo "$hostname,$db_name,$backup_line" >> $backup_output_file
        done <<< "$backup_details"
    fi
done < /etc/oratab

# Remove the last comma and close the JSON array
sed -i '$ s/},$/}]/' $feature_usage_output_file
