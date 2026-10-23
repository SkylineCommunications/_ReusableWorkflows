#!/usr/bin/env bash
set -euo pipefail

checked=0
while IFS= read -r secret_name; do
  secret_name="${secret_name//[[:space:]]/}"
  [[ -z "$secret_name" ]] && continue

  env_var_name=$(printf '%s' "$secret_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  if [[ -z "${!env_var_name:-}" ]]; then
    echo "::error::Key Vault secret '$secret_name' was not exported as '$env_var_name'." >&2
    exit 1
  fi
  checked=$((checked + 1))
done <<< "$SECRET_NAMES"

if [[ "$checked" -eq 0 ]]; then
  echo "::error::No Key Vault secret names to verify." >&2
  exit 1
fi

echo "Verified $checked Key Vault secret(s) in the environment."