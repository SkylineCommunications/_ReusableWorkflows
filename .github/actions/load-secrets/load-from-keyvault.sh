#!/usr/bin/env bash
# Pulls a newline-separated list of Key Vault secret names from $SECRET_NAMES,
# fetches each value from $VAULT_NAME with the Azure CLI, masks it, and exports
# it to $GITHUB_ENV. The env var name is the secret name uppercased with '-'
# replaced by '_'.
set -euo pipefail

echo "Fetching secrets from Azure Key Vault '$VAULT_NAME'..."

# Read newline-separated secret names into an array, dropping blank lines.
mapfile -t secret_names < <(printf '%s\n' "$SECRET_NAMES" | sed '/^[[:space:]]*$/d')

for secret_name in "${secret_names[@]}"; do
  secret_name="${secret_name//[[:space:]]/}"
  [[ -z "$secret_name" ]] && continue

  env_var_name=$(echo "$secret_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

  secret_value=$(az keyvault secret show --vault-name "$VAULT_NAME" --name "$secret_name" --query value -o tsv)

  echo "::add-mask::$secret_value"
  echo "$env_var_name=$secret_value" >> "$GITHUB_ENV"
done
