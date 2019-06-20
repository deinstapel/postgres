#!/usr/bin/env bash

set -eou pipefail

echo "Running as Replica"

# set password ENV
export PGPASSWORD=${POSTGRES_PASSWORD:-postgres}

export ARCHIVE=${ARCHIVE:-}

# We do not need to check for pg-failover-trigger, because we have a limited time in this loops.
# If we cannot reach the primary, we will suicide and be rescheduled as master.

for i in 1 2 3 ; do
    if pg_isready --host="$PRIMARY_HOST" --timeout=2
    then
      echo "Connection Test was successful."
      break;
    else
      echo "Connection Test was not successful."

      if [[ ${i} -eq 3 ]]
      then
        echo "Cannot connect to primary. Exiting."
        exit 2
      fi
    fi
done

for i in 1 2 3 ; do
    if psql -h "$PRIMARY_HOST" --no-password --username=postgres --command="select now();"
    then
      echo "Query Test was successful."
      break;
    else
      echo "Query Test was not successful."

      if [[ ${i} -eq 3 ]]
      then
        echo "Cannot query primary. Exiting."
        exit 2
      fi

    fi
done

# get basebackup
mkdir -p "$PGDATA"
rm -rf "$PGDATA"/*
chmod 0700 "$PGDATA"

pg_basebackup -X fetch --no-password --pgdata "$PGDATA" --username=postgres --host="$PRIMARY_HOST"

# setup recovery.conf
cp /scripts/replica/recovery.conf /tmp
echo "recovery_target_timeline = 'latest'" >>/tmp/recovery.conf
echo "archive_cleanup_command = 'pg_archivecleanup $PGWAL %r'" >>/tmp/recovery.conf
# primary_conninfo is used for streaming replication
echo "primary_conninfo = 'application_name=$HOSTNAME host=$PRIMARY_HOST'" >>/tmp/recovery.conf
mv /tmp/recovery.conf "$PGDATA/recovery.conf"

# setup postgresql.conf
touch /tmp/postgresql.conf
echo "wal_level = replica" >>/tmp/postgresql.conf
echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS
echo "wal_keep_segments = 32" >>/tmp/postgresql.conf
if [ "$STANDBY" == "hot" ]; then
  echo "hot_standby = on" >>/tmp/postgresql.conf
fi
if [ "$STREAMING" == "synchronous" ]; then
   # setup synchronous streaming replication
   echo "synchronous_commit = remote_write" >>/tmp/postgresql.conf
   echo "synchronous_standby_names = '*'" >>/tmp/postgresql.conf
fi

# push base-backup
if [ "$ARCHIVE" == "wal-g" ]; then
  # set walg ENV
  CRED_PATH="/srv/wal-g/archive/secrets"

  if [[ ${ARCHIVE_S3_PREFIX} != "" ]]; then
    export WALE_S3_PREFIX="$ARCHIVE_S3_PREFIX"
    [[ -e "$CRED_PATH/AWS_ACCESS_KEY_ID" ]] &&  export AWS_ACCESS_KEY_ID=$(cat "$CRED_PATH/AWS_ACCESS_KEY_ID")
    [[ -e "$CRED_PATH/AWS_SECRET_ACCESS_KEY" ]] &&  export AWS_SECRET_ACCESS_KEY=$(cat "$CRED_PATH/AWS_SECRET_ACCESS_KEY")
    if [[ ${ARCHIVE_S3_ENDPOINT} != "" ]]; then
      [[ -e "$CRED_PATH/CA_CERT_DATA" ]] &&  export WALG_S3_CA_CERT_FILE="$CRED_PATH/CA_CERT_DATA"
      export AWS_ENDPOINT=$ARCHIVE_S3_ENDPOINT
      export AWS_S3_FORCE_PATH_STYLE="true"
      export AWS_REGION="us-east-1"
    fi

  elif [[ ${ARCHIVE_GS_PREFIX} != "" ]]; then
    export WALE_GS_PREFIX="$ARCHIVE_GS_PREFIX"
    [[ -e "$CRED_PATH/GOOGLE_APPLICATION_CREDENTIALS" ]] && export GOOGLE_APPLICATION_CREDENTIALS="$CRED_PATH/GOOGLE_APPLICATION_CREDENTIALS"
    [[ -e "$CRED_PATH/GOOGLE_SERVICE_ACCOUNT_JSON_KEY" ]] &&  export GOOGLE_APPLICATION_CREDENTIALS="$CRED_PATH/GOOGLE_SERVICE_ACCOUNT_JSON_KEY"

  elif [[ ${ARCHIVE_FILE_PREFIX} != "" ]]; then
    export WALG_FILE_PREFIX="$ARCHIVE_FILE_PREFIX/$(hostname)"
    mkdir -p $WALG_FILE_PREFIX

  elif [[ ${ARCHIVE_AZ_PREFIX} != "" ]]; then
    export WALE_AZ_PREFIX="$ARCHIVE_AZ_PREFIX"
    [[ -e "$CRED_PATH/AZURE_STORAGE_ACCESS_KEY" ]] && export AZURE_STORAGE_ACCESS_KEY=$(cat "$CRED_PATH/AZURE_STORAGE_ACCESS_KEY")
    [[ -e "$CRED_PATH/AZURE_ACCOUNT_KEY" ]] && export AZURE_STORAGE_ACCESS_KEY=$(cat "$CRED_PATH/AZURE_ACCOUNT_KEY")
    [[ -e "$CRED_PATH/AZURE_STORAGE_ACCOUNT" ]] && export AZURE_STORAGE_ACCOUNT=$(cat "$CRED_PATH/AZURE_STORAGE_ACCOUNT")
    [[ -e "$CRED_PATH/AZURE_ACCOUNT_NAME" ]] && export AZURE_STORAGE_ACCOUNT=$(cat "$CRED_PATH/AZURE_ACCOUNT_NAME")

  elif [[ ${ARCHIVE_SWIFT_PREFIX} != "" ]]; then
    export WALE_SWIFT_PREFIX="$ARCHIVE_SWIFT_PREFIX"
    [[ -e "$CRED_PATH/OS_USERNAME" ]] &&  export OS_USERNAME=$(cat "$CRED_PATH/OS_USERNAME")
    [[ -e "$CRED_PATH/OS_PASSWORD" ]] &&  export OS_PASSWORD=$(cat "$CRED_PATH/OS_PASSWORD")
    [[ -e "$CRED_PATH/OS_REGION_NAME" ]] &&  export OS_REGION_NAME=$(cat "$CRED_PATH/OS_REGION_NAME")
    [[ -e "$CRED_PATH/OS_AUTH_URL" ]] &&  export OS_AUTH_URL=$(cat "$CRED_PATH/OS_AUTH_URL")
    #v2
    [[ -e "$CRED_PATH/OS_TENANT_NAME" ]] &&  export OS_TENANT_NAME=$(cat "$CRED_PATH/OS_TENANT_NAME")
    [[ -e "$CRED_PATH/OS_TENANT_ID" ]] &&  export OS_TENANT_ID=$(cat "$CRED_PATH/OS_TENANT_ID")
    #v3
    [[ -e "$CRED_PATH/OS_USER_DOMAIN_NAME" ]] && export OS_USER_DOMAIN_NAME=$(cat "$CRED_PATH/OS_USER_DOMAIN_NAME")
    [[ -e "$CRED_PATH/OS_PROJECT_NAME" ]] && export OS_PROJECT_NAME=$(cat "$CRED_PATH/OS_PROJECT_NAME")
    [[ -e "$CRED_PATH/OS_PROJECT_DOMAIN_NAME" ]] && export OS_PROJECT_DOMAIN_NAME=$(cat "$CRED_PATH/OS_PROJECT_DOMAIN_NAME")
    #manual
    [[ -e "$CRED_PATH/OS_STORAGE_URL" ]] && export OS_STORAGE_URL=$(cat "$CRED_PATH/OS_STORAGE_URL")
    [[ -e "$CRED_PATH/OS_AUTH_TOKEN" ]] && export OS_AUTH_TOKEN=$(cat "$CRED_PATH/OS_AUTH_TOKEN")
    #v1
    [[ -e "$CRED_PATH/ST_AUTH" ]] && export ST_AUTH=$(cat "$CRED_PATH/ST_AUTH")
    [[ -e "$CRED_PATH/ST_USER" ]] && export ST_USER=$(cat "$CRED_PATH/ST_USER")
    [[ -e "$CRED_PATH/ST_KEY" ]] && export ST_KEY=$(cat "$CRED_PATH/ST_KEY")
  fi

  # setup postgresql.conf
  echo "archive_command = 'wal-g wal-push %p'" >>/tmp/postgresql.conf
  echo "archive_timeout = 60" >>/tmp/postgresql.conf
  echo "archive_mode = always" >>/tmp/postgresql.conf
fi
cat /scripts/primary/postgresql.conf >> /tmp/postgresql.conf
mv /tmp/postgresql.conf "$PGDATA/postgresql.conf"

exec postgres
