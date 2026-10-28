#!/bin/sh
# Run one SQL statement on the serverless warehouse via the Statement Execution API.
# Usage: sh scripts/sql.sh "SELECT 1"
WH="${DATABRICKS_WAREHOUSE_ID:-acbfda553f05a6ec}"
body=$(python3 -c 'import json,sys;print(json.dumps({"warehouse_id":sys.argv[1],"statement":sys.argv[2],"wait_timeout":"50s"}))' "$WH" "$1")
databricks api post /api/2.0/sql/statements --json "$body"
