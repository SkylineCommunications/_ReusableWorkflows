#!/usr/bin/env bash
# Pulls a newline-separated list of Key Vault secret names from $SECRET_NAMES,
# fetches each value from $VAULT_NAME with the Azure CLI, masks it, and exports
# it to $GITHUB_ENV. The env var name is the secret name uppercased with '-'
# replaced by '_'.
set -euo pipefail

echo "Starting Key Vault secret retrieval from '$VAULT_NAME'."

if [[ -z "${GITHUB_ENV:-}" ]]; then
  echo "ERROR: GITHUB_ENV is not set; cannot export retrieved secrets." >&2
  exit 1
fi

echo "GITHUB_ENV is configured at '$GITHUB_ENV'."

# Read newline-separated secret names into an array, dropping blank lines.
mapfile -t secret_names < <(printf '%s\n' "$SECRET_NAMES" | sed '/^[[:space:]]*$/d')
echo "Parsed ${#secret_names[@]} non-blank secret name(s) from SECRET_NAMES."

if [[ "${#secret_names[@]}" -eq 0 ]]; then
  echo "ERROR: SECRET_NAMES contained no non-blank secret names." >&2
  exit 1
fi

for secret_name in "${secret_names[@]}"; do
  secret_name="${secret_name//[[:space:]]/}"
  [[ -z "$secret_name" ]] && continue

  env_var_name=$(echo "$secret_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  echo "Fetching Key Vault secret '$secret_name' for environment variable '$env_var_name'."

  if ! secret_value=$(az keyvault secret show --vault-name "$VAULT_NAME" --name "$secret_name" --query value -o tsv); then
    echo "ERROR: Failed to fetch Key Vault secret '$secret_name'." >&2
    exit 1
  fi
  echo "Fetched Key Vault secret '$secret_name'; masking and exporting it."

  # Mask every line so multi-line secrets (e.g. PEM private keys) never leak in logs.
  masked_line_count=0
  while IFS= read -r secret_line; do
    if [[ -n "$secret_line" ]]; then
      echo "::add-mask::$secret_line"
      masked_line_count=$((masked_line_count + 1))
    fi
  done <<< "$secret_value"
  echo "Masked $masked_line_count non-empty line(s) for '$secret_name'."

  # Write to $GITHUB_ENV using the heredoc form so multi-line values (e.g. PEM keys)
  # are preserved. A random delimiter avoids clashing with the secret content.
  delimiter="ghadelim_${secret_name}_${RANDOM}${RANDOM}"
  {
    printf '%s<<%s\n' "$env_var_name" "$delimiter"
    printf '%s\n' "$secret_value"
    printf '%s\n' "$delimiter"
  } >> "$GITHUB_ENV"
  echo "Exported '$env_var_name' to GITHUB_ENV."
done

echo "Completed Key Vault secret retrieval for ${#secret_names[@]} secret(s)."
