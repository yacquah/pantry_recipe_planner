#!/usr/bin/env bash
#
# Rebuild the device database from scratch and run the target queries.
#
#   ./schema/build.sh              # builds at /tmp/pantry.db
#   ./schema/build.sh ~/my.db      # or wherever you like
#
# The .db file is a BUILD ARTIFACT, never source. The .sql files in this
# directory are the truth; the database is regenerated from them and is safe
# to delete at any time. That is why it defaults to /tmp and is not committed.

set -euo pipefail
#   -e  stop at the first command that fails, instead of ploughing on
#   -u  treat an unset variable as an error, so typos surface immediately
#   -o pipefail  a failure anywhere in a pipeline fails the whole pipeline

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # this script's directory
DB="${1:-/tmp/pantry.db}"                              # $1 if given, else default

rm -f "$DB"        # -f: no complaint if it does not exist yet.
                   # Starting clean is what makes the build reproducible —
                   # otherwise CREATE TABLE hits "table already exists".

sqlite3 "$DB" < "$HERE/001_device_sqlite.sql"
echo "schema loaded"

sqlite3 "$DB" < "$HERE/002_seed.sql"
echo "seed loaded  ->  $DB"

for q in "$HERE"/queries/*.sql; do
  echo
  echo "=============================================================="
  echo "  $(basename "$q")"
  echo "=============================================================="
  sqlite3 "$DB" < "$q"
done
