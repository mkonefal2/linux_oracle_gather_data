#!/bin/bash

# Define directory for Oracle inventory files
inventory_dir="/tmp/ora_inventory"

# Create Oracle inventory directory if it doesn't exist
if [ ! -d "$inventory_dir" ]; then
    mkdir -p "$inventory_dir"
fi

# Get the hostname of the server
server_hostname=$(hostname)
# Paths to the CSV files
output_file="${inventory_dir}/${server_hostname}_oracle_databases_info.csv"
backup_output_file="${inventory_dir}/${server_hostname}_oracle_backup_details.csv"
feature_usage_output_file="${inventory_dir}/${server_hostname}_oracle_feature_usage.json"
oracle_connected_machines_csv="${inventory_dir}/${server_hostname}_oracle_connected_machines.csv"
asm_disks_info_csv="${inventory_dir}/${server_hostname}_asm_disks_info.csv"
asm_disk_usage_csv="${inventory_dir}/${server_hostname}_asm_disk_usage.csv"

# Paths to the TXT files
asm_disk_usage_txt="${inventory_dir}/${server_hostname}_asm_disk_usage.txt"
asm_disks_info_txt="${inventory_dir}/${server_hostname}_asm_disks_info.txt"
asm_disks_sql_txt="${inventory_dir}/${server_hostname}_asm_disks_sql.txt"
connected_machines_sql_txt="${inventory_dir}/${server_hostname}_connected_machines_sql.txt"
feature_usage_sql_txt="${inventory_dir}/${server_hostname}_feature_usage_sql.txt"
backup_details_sql_txt="${inventory_dir}/${server_hostname}_backup_details_sql.txt"

# CSV file headers
echo "Hostname,Database Name,Database Size (GB),ArchiveLog Mode,Software Version,Oracle Home,Alert Log Path,Database Role,Device Backup Type" > $output_file
echo "Hostname,Database Name,Input Type,Status,Start Time,End Time,Input Size (GB),Duration" > $backup_output_file
echo "Hostname,Database Name,Machine" > $oracle_connected_machines_csv
echo "Hostname,Group,Name,Path,Size,Device Path" > $asm_disks_info_csv
echo "Hostname,Name,Free GB,Total GB,Used GB,Used Percent,Free Percent" > $asm_disk_usage_csv

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
SELECT OUTPUT_DEVICE_TYPE AS "DEVICE_BACKUP_TYPE"
FROM (
    SELECT OUTPUT_DEVICE_TYPE, START_TIME
    FROM V\$RMAN_BACKUP_JOB_DETAILS
    WHERE OUTPUT_DEVICE_TYPE IS NOT NULL
    ORDER BY START_TIME DESC
)
WHERE ROWNUM = 1;
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
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF TIMING OFF LINESIZE 1000 LONG 10000 TRIMSPOOL ON
SELECT
    '{' || CHR(10) ||
    '"Hostname": "' || TRIM('$server_hostname') || '",' || CHR(10) ||
    '"Database Name": "' || TRIM('$db_name') || '",' || CHR(10) ||
    '"Feature Name": "' || TRIM(REPLACE(NAME, '"', '\"')) || '",' || CHR(10) ||
    '"Version": "' || TRIM(REPLACE(VERSION, '"', '\"')) || '",' || CHR(10) ||
    '"Detected Usages": "' || TRIM(TO_CHAR(DETECTED_USAGES)) || '",' || CHR(10) ||
    '"Total Samples": "' || TRIM(TO_CHAR(TOTAL_SAMPLES)) || '",' || CHR(10) ||
    '"Currently Used": "' || TRIM(CURRENTLY_USED) || '",' || CHR(10) ||
    '"First Usage Date": "' || TRIM(TO_CHAR(FIRST_USAGE_DATE, 'dd/mm/yyyy')) || '",' || CHR(10) ||
    '"Last Usage Date": "' || TRIM(TO_CHAR(LAST_USAGE_DATE, 'dd/mm/yyyy')) || '",' || CHR(10) ||
    '"Feature Info": "' || TRIM(SUBSTR(REPLACE(FEATURE_INFO, '"', '\"'), 1, 4000)) || '"' || CHR(10) || '},'
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
        echo "$hostname,$db_name,$db_size,$archivelog_mode,$software_version,$oracle_home,$alert_log_path,$database_role,$device_backup_type,$output_file" >> $output_file

        # Writing backup details to the CSV file
        while IFS= read -r backup_line; do
            echo "$hostname,$db_name,$backup_line,$backup_output_file" >> $backup_output_file
        done <<< "$backup_details"

        # Extracting connected machines information
        connected_machines=$(sqlplus -s / as sysdba <<EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF LINESIZE 300
SELECT DISTINCT machine FROM gv\$session;
EXIT;
EOF
        )

        # Writing results to the CSV file for connected machines
        while IFS= read -r machine; do
            if [[ -n "$machine" ]]; then # Checking if machine name is not empty
                echo "$server_hostname,$db_name,$machine" >> $oracle_connected_machines_csv
            fi
        done <<< "$connected_machines"
    fi
done < /etc/oratab

# Remove the last comma and close the JSON array
sed -i '$ s/},$/}]/' $feature_usage_output_file

# Fetching ASM disks info
# Checking if +ASM instance exists
ASM_LINE=$(grep '+ASM' "/etc/oratab" | grep -v '^#' | head -n 1)
if [[ ! -z "$ASM_LINE" ]]; then
    ORACLE_SID=$(echo "$ASM_LINE" | cut -d: -f1)
    ORACLE_HOME=$(echo "$ASM_LINE" | cut -d: -f2)
    export ORACLE_HOME
    export ORACLE_SID
    export PATH=$ORACLE_HOME/bin:$PATH
    # SQL query to check ASM disk space usage
    sqlplus -s / as sysdba <<EOF > "$asm_disk_usage_txt"
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT
    NAME || ',' ||
    ROUND(free_mb / 1024, 2) || ',' ||
    ROUND(total_mb / 1024, 2) || ',' ||
    ROUND((total_mb - free_mb) / 1024, 2) || ',' ||
    ROUND(((total_mb - free_mb) / total_mb) * 100, 2) || ',' ||
    ROUND((free_mb / total_mb) * 100, 2)
FROM
    v\$asm_diskgroup
ORDER BY
    1;
EOF
    # Saving ASM disk usage data to CSV
    while IFS=, read -r name free_gb total_gb used_gb used_percent free_percent; do
        echo "$server_hostname,$name,$free_gb,$total_gb,$used_gb,$used_percent,$free_percent,$asm_disk_usage_csv" >> "$asm_disk_usage_csv"
    done < "$asm_disk_usage_txt"
else
    echo "Instance +ASM not found in oratab, skipping ASM disk usage query."
fi
if [[ ! -z "$ASM_LINE" ]]; then
    # Gathering ASM disk information
    sqlplus -s / as sysdba <<EOF > "$asm_disks_sql_txt"
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF LINESIZE 300
SELECT dg.NAME || ',' || d.NAME || ',' || d.PATH || ',' || ROUND(d.TOTAL_MB / 1024, 2) FROM V\$ASM_DISK d JOIN V\$ASM_DISKGROUP dg ON d.GROUP_NUMBER = dg.GROUP_NUMBER ORDER BY dg.NAME, d.NAME;
EOF
    # Processing and saving ASM disk data to CSV
    while IFS=, read -r group name path size; do
        # Determine the separator used in the path variable
        if [[ "$path" == *"/"* ]]; then
            separator="/"
        elif [[ "$path" == *":"* ]]; then
            separator=":"
        else
            separator=""
        fi
        # Extract disk name from path based on separator
        disk_name_from_path=$(echo "$path" | rev | cut -d"$separator" -f1 | rev)
        # Find device path using disk name
        device_path=$(blkid | grep "LABEL=\"$disk_name_from_path\"" | awk -F: '{print $1}')
        # Append device path to CSV based on its availability
        if [[ ! -z "$device_path" ]]; then
            echo "$server_hostname,$group,$name,$path,$size,$device_path,$asm_disks_info_csv" >> $asm_disks_info_csv
        else
            echo "$server_hostname,$group,$name,$path,$size,,$asm_disks_info_csv" >> $asm_disks_info_csv
        fi
    done < "$asm_disks_sql_txt"
fi

# Set permissions for the inventory directory
chmod -R 755 "$inventory_dir"

# Print success message
echo "Oracle database information collected successfully."
# Print directory path 
echo "Inventory directory: $inventory_dir"
