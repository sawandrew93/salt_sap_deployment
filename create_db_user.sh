#!/bin/bash
SYSTEM_USER_PW="Passw0rd" #SYSTEM Database User
SID="NDB"
NEW_USER="ADMIN"
NEW_PASS="Passw0rd"
#function to check whether database user already exists
user_exists=$(
  su - ndbadm -c "echo \"SELECT user_name FROM users WHERE user_name='${NEW_USER}';\" | hdbsql -u SYSTEM -p ${SYSTEM_USER_PW} -n localhost:30013 -d ${SID}" \
  | awk -v user="\"${NEW_USER}\"" '$0 == user { print }' \
  | tr -d '"'
)



#DB user creation
if [[ "$user_exists" == "$NEW_USER" ]]; then
    echo "User ${NEW_USER} already exists. Skipping creation."
else
    echo "Creating user ${NEW_USER}..."

    su - ndbadm -c "hdbsql -u SYSTEM -p ${SYSTEM_USER_PW} -n localhost:30013 -d ${SID} <<EOF
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
