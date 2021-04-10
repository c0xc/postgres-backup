#!/usr/bin/env bash

# Recommendation: Save this as ~postgres/bin/backup.sh; set up cron job:
# @daily ~/bin/backup.sh
# or
# @daily PGBUP_DIR=/var/backup PGBUP_DEFAULT_PGPASSWORD=... ~/bin/backup.sh
# If you want to run it as application user, make sure to
# set the application database user in the cron job (owner/superuser), e.g.:
# @daily PGBUP_DIR=~/backup PGBUP_DEFAULT_PGUSER=app... PGBUP_DEFAULT_PGPASSWORD=... ~/bin/backup.sh
# or have PGUSER and PGPASSWORD in your environment, set to the db owner.

# This script attempts to get a list of all user databases and
# makes a backup of each database in /var/tmp/backup (or $PGBUP_DIR).
# If run as user postgres, it doesn't specify any login names to pg_dump
# as it expects that user to have full access to everything.
# If it has a password, it must be specified via $PGPASSWORD.
# If run as any other user,
# it will read the ~/.pgpass file and explicitly use the username found there
# for the current db, assuming that file contains credentials for all dbs to be saved.
# In that case, databases not configured in ~/.pgpass will be skipped.
if [[ -z "$PGBUP_EXPLICIT_LOGIN" ]]; then
    # Decide whether to use explicit login user for Postgres
    if [[ "$USER" = "postgres" || -n "$PGUSER" ]]; then
        PGBUP_EXPLICIT_LOGIN=0
    else
        PGBUP_EXPLICIT_LOGIN=1
    fi
fi
if [[ -z "$PGBUP_VERBOSE" || "$PGBUP_VERBOSE" = "0" ]]; then
    PGBUP_VERBOSE=0
else
    PGBUP_VERBOSE=1
fi

# Timeout wrapper; set low value like 60 or 300 seconds for testing
# Use high values like 3600 in production
# Override, disable timeout with TIMEOUT=0 (in cron job)
TIMEOUT=${TIMEOUT:-300}
wrapper=()
if [[ "$TIMEOUT" =~ ^[0-9]+ && $TIMEOUT -gt 0 ]]; then
    wrapper=("timeout" "$TIMEOUT")
fi

# Get list of local Postgres databases
# Any valid PG login required, preferably postgres user.
# If run as postgres user, no default credentials required except maybe PGPASSWORD.
# Override: PGBUP_DEFAULT_PGUSER=... PGBUP_DEFAULT_PGPASSWORD=...
PGBUP_DEFAULT_PGDATABASE=${PGBUP_DEFAULT_PGDATABASE:-postgres}
list_u_arg=()
if [[ -n "$PGBUP_DEFAULT_PGUSER" ]]; then
    # Specify explicit user login for psql to get list of databases
    list_u_arg+=("-U" "$PGBUP_DEFAULT_PGUSER")
fi
export PGBUP_DEFAULT_PGPASSWORD
export PGBUP_DEFAULT_PGDATABASE
pg_databases=$( \
    [ -n "$PGBUP_DEFAULT_PGPASSWORD" ] && export PGPASSWORD=$PGBUP_DEFAULT_PGPASSWORD; \
    [ -n "$PGBUP_DEFAULT_PGDATABASE" ] && export PGDATABASE=$PGBUP_DEFAULT_PGDATABASE; \
    "${wrapper[@]}" psql "${list_u_arg[@]}" -Atc "select datname from pg_database where datname not in ('template0', 'template1', 'postgres')"; \
) || (echo "ERROR listing postgres databases" >&2; exit 1)
date=$(date +%F)
(( $PGBUP_VERBOSE )) && echo "PG databases [$date]: "$pg_databases

# Destination backup directory (created if missing)
# Override with: PGBUP_DIR=...
PGBUP_DIR=${PGBUP_DIR:-/var/tmp/backup}
if [[ ! -d "$PGBUP_DIR" ]]; then
    (( $PGBUP_VERBOSE )) && echo "creating db backup directory: $PGBUP_DIR"
    if ! mkdir "$PGBUP_DIR"; then
        echo "failed to create backup directory: $PGBUP_DIR" >&2
        exit 1
    fi
fi
if ! [[ -d "$PGBUP_DIR" && -w "$PGBUP_DIR" ]]; then
    echo "inaccessible backup directory: $PGBUP_DIR" >&2
    exit 1
fi

# Commentary:
# -a|--data-only:
# pg_dump: warning: there are circular foreign-key constraints on this table:
# pg_dump:   videoComment
# pg_dump: You might not be able to restore the dump without using --disable-triggers or temporarily dropping the constraints.
# pg_dump: Consider using a full dump instead of a --data-only dump to avoid this problem.

# Make backups for all of them
for db in $pg_databases; do
    (( $PGBUP_VERBOSE )) && echo "DATABASE: $db ..."

    # User argument, (if) user has to be specified explicitly to prevent interactive prompt:
    # Password: 
    # pg_dump: error: connection to database "..." failed: FATAL:  password authentication failed for user "..."
    db_u_arg=()
    if ! [[ -z "$PGBUP_EXPLICIT_LOGIN" || "$PGBUP_EXPLICIT_LOGIN" = "0" ]]; then
        # Explicit login required, check if .pgpass contains credentials for this db
        got_db_user=0
        while IFS=: read h p d u p; do
            # Expect and find credentials for this db
            [[ "$h" =~ ^# ]] && continue # line commented out
            [[ -z "$u" ]] && continue # blank user field
            [[ "$d" = "$db" ]] || continue # skip any other db
            got_db_user=1
            db_u_arg+=("-U" "$u")
            (( $PGBUP_VERBOSE )) && echo "using configured db user: $u"
            break # use first result (should be superuser/owner of this db)
        done <~/.pgpass
        if [[ $got_db_user != 1 ]]; then
            echo "SKIP pg database not configured in pgpass: $db"
            continue
        fi
    fi

    # Make backup in Postgres file format, which is faster
    # but sometimes, it can't be imported if there's a version difference or something - so...
    "${wrapper[@]}" /usr/bin/pg_dump "${db_u_arg[@]}" -Fc "$db" >"${PGBUP_DIR}/${db}__${date}.db"
    db_rc=$?
    # Make backup in standard SQL which is slow but it simply works
    "${wrapper[@]}" /usr/bin/pg_dump "${db_u_arg[@]}" --column-inserts "$db" | gzip -c >"${PGBUP_DIR}/${db}__full_${date}.sql.gz"
    db_rc=$?
    if [[ "$db_rc" -eq 0 ]]; then
        (( $PGBUP_VERBOSE )) && echo "OK pg database saved [$date] in ${PGBUP_DIR}"
    else
        echo "ERROR creating database backup for $db"
    fi
done

# Delete backup files older than 3 months
find "${PGBUP_DIR}/" -maxdepth 1 -mtime +90 \( -name '*.db' -or -name '*.sql' -or -name '*.sql.gz' \) -print -delete

