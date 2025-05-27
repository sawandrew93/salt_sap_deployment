#!/bin/bash
#set log file directory
set -e  # Exit on error
LOGFILE="/var/log/install_script_$(date '+%Y-%m-%d').log"

# Default values for non-password variables
SID="NDB"
NEW_DB_USER="SAPADMIN"

# Function to request user input
prompt_with_default() {
    local var_name=$1
    local default_value=$2
    local prompt_message=$3

    echo -n "$prompt_message [default: $default_value]: "
    read input
    eval "$var_name=\"\${input:-$default_value}\""
}

# Function to request password
prompt_password_confirm() {
    local var_name=$1
    local prompt_message=$2

    while true; do
        echo -n "$prompt_message: "
        read pw1

        echo -n "Confirm $prompt_message: "
        read pw2

        echo "You entered: $pw2"

        if [[ "$pw1" == "$pw2" ]]; then
            eval "$var_name=\"\$pw1\""
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done
}

# Input prompts
prompt_with_default SID "$SID" "Enter Tenant Database Name (SID)"
prompt_password_confirm SYSTEM_USER_PW "Set SYSTEM User Password"
prompt_with_default NEW_DB_USER "$NEW_DB_USER" "Enter New DB User"
prompt_password_confirm NEW_DB_USER_PW "Set Password for New DB User"
prompt_password_confirm B1SITEUSER_PW "Set B1SiteUser Password"
echo "Choose an option:"
echo "1. I have downloaded HANA and SAP installers and extracted with SAPCAR"
echo "2. I want to download from Google Drive"
read -p "Enter your choice (1 or 2): " user_choice

# Summary
echo -e "\nConfiguration Summary:"
echo "SID: $SID"
echo "SYSTEM_USER_PW: $SYSTEM_USER_PW"
echo "NEW_DB_USER: $NEW_DB_USER"
echo "NEW_DB_USER_PW: $NEW_DB_USER_PW"
echo "B1SITEUSER_PW: $B1SITEUSER_PW"


# Wait for user to continue
echo
read -p "Press Enter to continue..."


if [[ "$user_choice" == "2" ]]; then
  # Prompt user for Google Drive folder ID
  read -p "Enter the Google Drive folder ID: " FOLDER_ID

    if [[ -z "$FOLDER_ID" ]]; then
      echo "No folder ID entered. Exiting."
      exit 1
    fi
  #dependency checking
  if zypper lr | grep -q vglocal; then
    echo "vglocal repository is already enabled" | tee -a "$LOGFILE"
  else
    echo "Adding local repository..." | tee -a "$LOGFILE"
    zypper addrepo -G http://121.54.164.70/15-SP3/ vglocal
  fi
    zypper install -y python3-pip
    pip install gdown
     
  # Create and enter a working directory
  DOWNLOAD_DIR="/hana/shared/installers"
  mkdir "$DOWNLOAD_DIR"
  cd "$DOWNLOAD_DIR" || exit 1

  # Download all files in the folder
  echo "Downloading files from Google Drive folder..."
  gdown --folder "$FOLDER_ID"

  # Find and extract all ZIP files recursively
  find . -type f \( -iname "*.zip" \) | while read -r zip_file; do
    echo "Extracting ZIP file: $zip_file"
    unzip -o "$zip_file" -d "$(dirname "$zip_file")"
    rm "$zip_file"
  done

  # Find and extract all RAR files recursively
  find . -type f -iname "*.rar" | while read -r rar_file; do
    echo "Extracting RAR file: $rar_file"
    unar -f -o "$(dirname "$rar_file")" "$rar_file"
  done

  echo "Extraction complete. Files are in: $(pwd)"

  # Apply chmod -R 777 to all files and folders
  echo "Setting permissions..."
  chmod -R 777 .

  # Find the SAPCAR executable (assuming only one match like SAPCAR-123123.EXE)
  SAPCAR_EXE=$(find . -maxdepth 1 -iname "SAPCAR_*.EXE" | head -n 1)

  if [[ -z "$SAPCAR_EXE" ]]; then
    echo "SAPCAR-*.EXE not found in the top-level directory."
    exit 1
  fi

  SAPCAR_NAME=$(basename "$SAPCAR_EXE")
  echo "Found SAPCAR executable: $SAPCAR_NAME"

  # Find all .SAR files and process them
  find . -type f -name "*.SAR" | while IFS= read -r sar_path; do
    sar_dir=$(dirname "$sar_path")
    sar_file=$(basename "$sar_path")
    echo "Processing SAR file: $sar_file in directory: $sar_dir"

    # Copy SAPCAR to the SAR file's directory
    cp "$SAPCAR_EXE" "$sar_dir" || { echo "Failed to copy SAPCAR to $sar_dir"; continue; }

    # Run SAPCAR extract command
    (
      cd "$sar_dir" || { echo "Failed to cd to $sar_dir"; continue; }

      sapcar_local=$(basename "$SAPCAR_EXE")
      if [[ ! -f "$sapcar_local" ]]; then
        echo "SAPCAR executable not found in $sar_dir"
        continue
      fi

      # Run extraction
      echo "Extracting $sar_file with $sapcar_local"
      ./"$sapcar_local" -manifest SIGNATURE.SMF -xvf "$sar_file"
    )
  done

  echo "All files have been downloaded and extracted."
else
  echo "Skipping download and extraction steps as you already have the installers."
fi

echo "Other codes will start from here"

SID_USER=$(echo "$SID" | tr '[:upper:]' '[:lower:]')adm

#function to check whether database user already exists
user_exists=$(
  su - $SID_USER -c "echo \"SELECT user_name FROM users WHERE user_name='${NEW_DB_USER}';\" | hdbsql -u SYSTEM -p ${SYSTEM_USER_PW} -n localhost:30013 -d ${SID}" \
  | awk -v user="\"${NEW_DB_USER}\"" '$0 == user { print }' \
  | tr -d '"'
)

#dowload hana and sap parameters from github repo

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
    su - $SID_USER -c "hdbsql -u SYSTEM -p ${SYSTEM_USER_PW} -n localhost:30013 <<EOF
ALTER DATABASE NDB ADD 'scriptserver'
EOF"

    if [[ $? -eq 0 ]]; then
        echo "Script server has been added successfully." | tee -a "$LOGFILE"
    else
        echo "Error adding script server." | tee -a "$LOGFILE"
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
rm "$hdb_param_file"
rm "$sap_param_file"
rm /tmp/sap.cfg /tmp/hdb.cfg
