#!/bin/sh
# Reinstall the CLIs in a fresh cloud session. Auth comes from the
# DATABRICKS_HOST and DATABRICKS_TOKEN environment variables.
set -e
cd "$(dirname "$0")/.."

CLI_VERSION="1.22.1"

if ! command -v databricks >/dev/null 2>&1; then
    case "$(uname -m)" in
        x86_64) ARCH=amd64 ;;
        arm64|aarch64) ARCH=arm64 ;;
        *) echo "Unsupported arch: $(uname -m)"; exit 1 ;;
    esac
    OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/cli.zip" \
        "https://github.com/databricks/cli/releases/download/v${CLI_VERSION}/databricks_cli_${CLI_VERSION}_${OS}_${ARCH}.zip"
    unzip -q "$tmp/cli.zip" -d "$tmp"
    install -m 0755 "$tmp/databricks" /usr/local/bin/databricks
    rm -rf "$tmp"
fi

[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q databricks-agentbricks

databricks --version
AGENTBRICKS_DISABLE_AGENT_HINT=1 .venv/bin/agentbricks --version

if [ -n "$DATABRICKS_HOST" ] && [ -n "$DATABRICKS_TOKEN" ]; then
    databricks current-user me --output json | head -c 200; echo
else
    echo "DATABRICKS_HOST / DATABRICKS_TOKEN not set"
fi
