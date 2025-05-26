#!/bin/bash

# Change values of below variables if you want
SID="NDB" #Tenant database name
SYSTEM_USER_PW="Passw0rd" #SYSTEM database user password
NEW_DB_USER="SAPADMIN" #SAPADMIN or as you want
NEW_DB_USER_PW="H@na@123" #new db user password
B1SITEUSER_PW="Hana@123"
# Change values of above variables if you want





SID_USER=$(echo "$SID" | tr '[:upper:]' '[:lower:]')adm

#function to check whether database user already exists
user_exists=$(
  su - $SID_USER -c "echo \"SELECT user_name FROM users WHERE user_name='${NEW_DB_USER}';\" | hdbsql -u SYSTEM -p ${SYSTEM_USER_PW} -n localhost:30013 -d ${SID}" \
  | awk -v user="\"${NEW_DB_USER}\"" '$0 == user { print }' \
  | tr -d '"'
)

#set log file directory and dowload hana and sap parameters from github repo
set -e  # Exit on error
LOGFILE="/var/log/install_script.log"
curl -O https://raw.githubusercontent.com/sawandrew93/salt_sap_deployment/refs/heads/main/hdb_param.cfg
curl -O https://raw.githubusercontent.com/sawandrew93/salt_sap_deployment/refs/heads/main/sap_param.cfg


#dependency checking
if zypper lr | grep -q vglocal; then
    echo "vglocal repository is already enabled" | tee -a "$LOGFILE"
else
    echo "Adding local repository..." | tee -a "$LOGFILE"
    zypper addrepo -G http://121.54.164.70/15-SP3/ vglocal
fi

echo "Checking and installing required packages..." | tee -a "$LOGFILE"

PACKAGES="jq libatomic1 rpm-build xmlstarlet python2-pyOpenSSL bc glibc-i18ndata \
          libcap-progs libicu60_2 insserv-compat nfs-kernel-server"

for pkg in $PACKAGES; do
    if ! rpm -q $pkg &>/dev/null; then
        echo "Installing $pkg..." | tee -a "$LOGFILE"
        zypper install -y $pkg
    else
        echo "$pkg is already installed." | tee -a "$LOGFILE"
    fi
done

echo "Dependency Packages installation complete!" | tee -a "$LOGFILE"



#Modifying hdb_param.cfg file before using it as input file and giving exec permission on hana installer directory
echo "Modifying hdb_param.cfg file and giving exec permissions on hana installer directory..." | tee -a "$LOGFILE"
hdb_param_file=$(find / -type f -name "hdb_param.cfg" 2>/dev/null | head -n 1)
cp "$hdb_param_file" /tmp/hdb.cfg

hana_afl_dir=$(find / -type d -name "SAP_HANA_AFL" 2>/dev/null | head -n 1)
hana_client_dir=$(find / -type d -name "SAP_HANA_CLIENT" 2>/dev/null | head -n 1)
hana_db_dir=$(find / -type d -name "SAP_HANA_DATABASE" 2>/dev/null | head -n 1)

sed -i "s|hana_afl_dir|${hana_afl_dir}|g" /tmp/hdb.cfg
sed -i "s|hana_client_dir|${hana_client_dir}|g" /tmp/hdb.cfg
sed -i "s|hana_db_dir|${hana_db_dir}|g" /tmp/hdb.cfg
sed -i "s|sap_admin_pw|${NEW_DB_USER_PW}|g" /tmp/hdb.cfg # to change sap_adm_pw inside /tmp/hdb.cfg with update value from variable
sed -i "s|system_pw|${SYSTEM_USER_PW}|g" /tmp/hdb.cfg # to change system databse user password inside /tmp/hdb.cfg with update value from variable
sed -i "s|NDB|${SID}|g" /tmp/hdb.cfg # to change sid value inside /tmp/hdb.cfg with update value from variable
if [[ -d "$hana_db_dir" ]]; then
    chmod +x -R "$hana_db_dir"
else
    echo "Cannot find HANA database installer directory." | tee -a "$LOGFILE"
fi

if [[ -d "$hana_client_dir" ]]; then
    chmod +x -R "$hana_client_dir"
else
    echo "Cannot find HANA database client installer directory." | tee -a "$LOGFILE"
fi

if [[ -d "$hana_afl_dir" ]]; then
    chmod +x -R "$hana_afl_dir"
else
    echo "Cannot find HANA AFL installer directory." | tee -a "$LOGFILE"
fi



#Install hana database, afl and client #It won't be executed if hana is already installed
echo "Checking SAP HANA Database installation..." | tee -a "$LOGFILE"

if su - $SID_USER -c "HDB version" &>/dev/null; then
    echo "SAP HANA is already installed." | tee -a "$LOGFILE"
    su - $SID_USER -c "HDB version"  # This will echo current installed version 
else
    if [[ -d "$hana_db_dir" ]]; then
        echo "Installing HANA Database services..." | tee -a "$LOGFILE"
        cd "$hana_db_dir"
        ./hdblcm --batch --configfile="/tmp/hdb.cfg" 2>&1 | tee -a "$LOGFILE"
        if [[ $? -eq 0 ]]; then
            echo "Installation completed successfully!" | tee -a "$LOGFILE"
        else
            echo "Installation failed!" | tee -a "$LOGFILE"
        fi       
    else
        echo "Cannot find HANA installer directory." | tee -a "$LOGFILE"
    fi
fi


#HANA DB user creation
if [[ "$user_exists" == "$NEW_DB_USER" ]]; then
    echo "User ${NEW_DB_USER} already exists. Skipping creation."
else
    echo "Creating user ${NEW_DB_USER}..." | tee -a "$LOGFILE"

    su - $SID_USER -c "hdbsql -u SYSTEM -p ${SYSTEM_USER_PW} -n localhost:30013 -d ${SID} <<EOF
CREATE USER ${NEW_DB_USER} PASSWORD \"${NEW_DB_USER_PW}\" NO FORCE_FIRST_PASSWORD_CHANGE;
ALTER USER ${NEW_DB_USER} DISABLE PASSWORD LIFETIME;
GRANT CONTENT_ADMIN TO ${NEW_DB_USER};
GRANT AFLPM_CREATOR_ERASER_EXECUTE TO ${NEW_DB_USER};
GRANT \"IMPORT\" TO ${NEW_DB_USER};
GRANT \"EXPORT\" TO ${NEW_DB_USER};
GRANT \"INIFILE ADMIN\" TO ${NEW_DB_USER};
GRANT \"LOG ADMIN\" TO ${NEW_DB_USER};
GRANT \"CREATE SCHEMA\",\"USER ADMIN\",\"ROLE ADMIN\",\"CATALOG READ\" TO ${NEW_DB_USER} WITH ADMIN OPTION;
GRANT \"CREATE ANY\",\"SELECT\" ON SCHEMA \"SYSTEM\" TO ${NEW_DB_USER} WITH GRANT OPTION;
GRANT \"SELECT\",\"EXECUTE\",\"DELETE\" ON SCHEMA \"_SYS_REPO\" TO ${NEW_DB_USER} WITH GRANT OPTION;
EOF"

    if [[ $? -eq 0 ]]; then
        echo "User ${NEW_DB_USER} created and privileges granted successfully." | tee -a "$LOGFILE"
    else
        echo "Error creating hana database user ${NEW_DB_USER}." | tee -a "$LOGFILE"
        exit 1
    fi
fi


#Modifying sap_param.cfg file before using it as input file and giving exec permission on sap installer directory
echo "Configuring SAP installation prerequisites..." | tee -a "$LOGFILE"

sap_dir=$(find / -type d -name "ServerComponents" 2>/dev/null | head -n 1)
if [[ -d "$sap_dir" ]]; then
        chmod +x -R "$sap_dir"
else
        echo "SAP installer directory not found!" | tee -a "$LOGFILE"
        exit 1
fi
sap_param_file=$(find / -type f -name "sap_param.cfg" 2>/dev/null | head -n 1)
if [ -z "$sap_param_file" ]; then
    echo "Error: 'sap_param.cfg' file not found." | tee -a "$LOGFILE"
    exit 1
fi
cp "$sap_param_file" /tmp/sap.cfg
sed -i "s/serverfqdn/$(hostname)/g" /tmp/sap.cfg
sed -i "s|B1SITEUSER_PW|${B1SITEUSER_PW}|g" /tmp/sap.cfg
sed -i "s/^HANA_DATABASE_USER_ID=.*/HANA_DATABASE_USER_ID=${NEW_DB_USER}/" /tmp/sap.cfg
sed -i "s/^HANA_DATABASE_USER_PASSWORD=.*/HANA_DATABASE_USER_PASSWORD=${NEW_DB_USER_PW}/" /tmp/sap.cfg
sed -i "s/^HANA_DATABASE_TENANT_DB=.*/HANA_DATABASE_TENANT_DB=${SID}/" /tmp/sap.cfg
sed -i -E "s|(BCKP_HANA_SERVERS=.*tenant-db=\")[^\"]*(\" user=\")[^\"]*(\" password=\")[^\"]*(\")|\1${SID}\2${NEW_DB_USER}\3${NEW_DB_USER_PW}\4|" /tmp/sap.cfg


#install SAP
echo "Checking SAP installation status..." | tee -a "$LOGFILE"

if systemctl list-units --type=service | grep -q "sapb1servertools.service"; then
    echo "SAP is already installed." | tee -a "$LOGFILE"
else
    echo "Starting SAP installation..." | tee -a "$LOGFILE"
    if [[ -d "$sap_dir" ]]; then
        cd "$sap_dir"
        ./install -i silent -f /tmp/sap.cfg --debug 2>&1 | tee -a "$LOGFILE"
        echo "SAP installation completed!" | tee -a "$LOGFILE"
    else
        echo "SAP installer directory not found!" | tee -a "$LOGFILE"
        exit 1
    fi
fi

#remove config files after installation
rm hdb_param.cfg
rm sap_param.cfg
rm /tmp/sap.cfg
rm /tmp/hdb.cfg
