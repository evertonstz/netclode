#!/usr/bin/env bash
# Apply Datadog metric metadata (units, types, descriptions) from metric-metadata.json.
# Requires DD_API_KEY and DD_APP_KEY (reads from .env if not set).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
METADATA_FILE="$SCRIPT_DIR/metric-metadata.json"

# Source keys from .env if not already set
if [[ -z "${DD_API_KEY:-}" || -z "${DD_APP_KEY:-}" ]]; then
	if [[ -f "$REPO_ROOT/.env" ]]; then
		DD_API_KEY=$(grep '^DD_API_KEY=' "$REPO_ROOT/.env" | cut -d= -f2 | tr -d '[:space:]')
		DD_APP_KEY=$(grep '^DD_APP_KEY=' "$REPO_ROOT/.env" | cut -d= -f2 | tr -d '[:space:]')
	fi
fi

if [[ -z "${DD_API_KEY:-}" || -z "${DD_APP_KEY:-}" ]]; then
	echo "error: DD_API_KEY and DD_APP_KEY must be set (in env or .env file)" >&2
	exit 1
fi

DD_SITE="${DD_SITE:-datadoghq.com}"

echo "Applying metric metadata from $METADATA_FILE"
echo "Datadog site: $DD_SITE"
echo ""

# Read each metric from the JSON and PUT metadata
python3 -c "
import json, sys
with open('$METADATA_FILE') as f:
    data = json.load(f)
for metric, meta in sorted(data.items()):
    body = json.dumps({k: v for k, v in meta.items()})
    print(f'{metric}\t{body}')
" | while IFS=$'\t' read -r metric body; do
	code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
		"https://api.${DD_SITE}/api/v1/metrics/${metric}" \
		-H "Content-Type: application/json" \
		-H "DD-API-KEY: ${DD_API_KEY}" \
		-H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
		-d "$body")

	if [[ "$code" == "200" ]]; then
		unit=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('unit',''))")
		echo "  ok  $metric ($unit)"
	else
		echo "  FAIL($code)  $metric" >&2
	fi
done

echo ""
echo "Done."
