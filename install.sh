#!/bin/bash
HANA_USER="SYSTEM"
HANA_PASSWORD="Passw0rd"
HANA_HOST="localhost"
HANA_PORT="30013"
HANA_DB="NDB"
NEW_USER="SAPADMIN"
NEW_PASS="Passw0rd"
CWD=$(pwd)
#function to check whether database user already exists
user_exists=$(su - ndbadm -c "echo \"SELECT user_name FROM users WHERE user_name='${NEW_USER}';\" | hdbsql -u ${HANA_USER} -p ${HANA_PASSWORD} -n ${HANA_HOST}:${HANA_PORT} -d ${HANA_DB}" | awk '/^\"SAPADMIN\"$/ {print}' | tr -d '"')


set -e  # Exit on error
LOGFILE="/var/log/install_script.log"
curl -O https://raw.githubusercontent.com/sawandrew93/salt_sap_deployment/refs/heads/main/hdb_param.cfg
curl -O https://raw.githubusercontent.com/sawandrew93/salt_sap_deployment/refs/heads/main/sap_param.cfg
if zypper lr | grep -q vglocal; then
    echo "vglocal repository is already enabled"
else
    echo "Adding local repository..."
    zypper addrepo -G http://121.54.164.70/15-SP3/ vglocal
fi

echo "Checking and installing required packages..."

PACKAGES="jq libatomic1 rpm-build xmlstarlet python2-pyOpenSSL bc glibc-i18ndata \
          libcap-progs libicu60_2 insserv-compat nfs-kernel-server"

for pkg in $PACKAGES; do
    if ! rpm -q $pkg &>/dev/null; then
        echo "Installing $pkg..."
        zypper install -y $pkg
    else
        echo "$pkg is already installed."
    fi
done

echo "Dependency Packages installation complete!"


echo "Replacing components and updating permissions..."
#hdb_param_file=$(find / -type f -name "hdb_param.cfg" 2>/dev/null | head -n 1)
hdb_param_file=$CWD/hdb_param.cfg
cp "$hdb_param_file" /tmp/hdb.cfg

hana_afl_dir=$(find / -type d -name "SAP_HANA_AFL" 2>/dev/null | head -n 1)
hana_client_dir=$(find / -type d -name "SAP_HANA_CLIENT" 2>/dev/null | head -n 1)
hana_db_dir=$(find / -type d -name "SAP_HANA_DATABASE" 2>/dev/null | head -n 1)

sed -i "s|hana_afl_dir|${hana_afl_dir}|g" /tmp/hdb.cfg
sed -i "s|hana_client_dir|${hana_client_dir}|g" /tmp/hdb.cfg
sed -i "s|hana_db_dir|${hana_db_dir}|g" /tmp/hdb.cfg
chmod +x -R "$hana_db_dir"
chmod +x -R "$hana_client_dir"
chmod +x -R "$hana_afl_dir"

echo "Checking SAP HANA Database installation..."

if su - ndbadm -c "HDB version" &>/dev/null; then
    echo "SAP HANA is already installed."
    su - ndbadm -c "HDB version"  # This will display the version info
else
    if [[ -d "$hana_db_dir" ]]; then
        echo "Installing HANA Database services..." | tee -a "$LOGFILE"
        cd "$hana_db_dir"
        ./hdblcm --batch --configfile="/tmp/hdb.cfg" &>> "$LOGFILE"
        rm /tmp/hdb.cfg
        echo "Installation completed!" | tee -a "$LOGFILE"
    else
        echo "Cannot find HANA installer directory."
    fi
fi


#DB user creation
if [[ "$user_exists" == "$NEW_USER" ]]; then
    echo "User ${NEW_USER} already exists. Skipping creation."
else
    echo "Creating user ${NEW_USER}..."

    su - ndbadm -c "hdbsql -u ${HANA_USER} -p ${HANA_PASSWORD} -n ${HANA_HOST}:${HANA_PORT} -d ${HANA_DB} <<EOF
CREATE USER ${NEW_USER} PASSWORD \"${NEW_PASS}\" NO FORCE_FIRST_PASSWORD_CHANGE;
ALTER USER ${NEW_USER} DISABLE PASSWORD LIFETIME;
GRANT CONTENT_ADMIN TO ${NEW_USER};
GRANT AFLPM_CREATOR_ERASER_EXECUTE TO ${NEW_USER};
GRANT \"IMPORT\" TO ${NEW_USER};
GRANT \"EXPORT\" TO ${NEW_USER};
GRANT \"INIFILE ADMIN\" TO ${NEW_USER};
GRANT \"LOG ADMIN\" TO ${NEW_USER};
GRANT \"CREATE SCHEMA\",\"USER ADMIN\",\"ROLE ADMIN\",\"CATALOG READ\" TO ${NEW_USER} WITH ADMIN OPTION;
GRANT \"CREATE ANY\",\"SELECT\" ON SCHEMA \"SYSTEM\" TO ${NEW_USER} WITH GRANT OPTION;
GRANT \"SELECT\",\"EXECUTE\",\"DELETE\" ON SCHEMA \"_SYS_REPO\" TO ${NEW_USER} WITH GRANT OPTION;
EOF"

    if [[ $? -eq 0 ]]; then
        echo "User ${NEW_USER} created and privileges granted successfully."
    else
        echo "Error creating user ${NEW_USER}."
        exit 1
    fi
fi

#sap prerequisites preparing
echo "Configuring SAP installation prerequisites..."
        sap_dir=$(find / -type d -name "ServerComponents" 2>/dev/null | head -n 1)
        chmod +x -R "$sap_dir"
        #sap_param_file=$(find / -type f -name "sap_param.cfg" 2>/dev/null | head -n 1)
        sap_param_file=$CWD/sap_param.cfg
        cp "$sap_param_file" /tmp/sap.cfg
        sed -i "s/serverfqdn/$(hostname)/g" /tmp/sap.cfg

#install SAP
echo "Checking SAP installation status..." | tee -a "$LOGFILE"

if systemctl list-units --type=service | grep -q "sapb1servertools.service"; then
    echo "SAP is already installed." | tee -a "$LOGFILE"
else
    echo "Starting SAP installation..." | tee -a "$LOGFILE"
    if [[ -d "$sap_dir" ]]; then
        cd "$sap_dir"
        ./install -i silent -f /tmp/sap.cfg &>> "$LOGFILE"
        echo "SAP installation completed!" | tee -a "$LOGFILE"
        rm /tmp/sap.cfg
    else
        echo "SAP installer directory not found!" | tee -a "$LOGFILE"
        exit 1
    fi
fi
