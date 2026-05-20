#!/usr/bin/env bash
# Applies caller-provided ENV=VALUE overrides from $OVERRIDES. Empty values are
# skipped so callers can safely forward optional secrets unconditionally.
set -euo pipefail

while IFS= read -r line; do
  # Strip leading/trailing whitespace.
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue

  if [[ "$line" != *"="* ]]; then
    echo "::warning::Ignoring malformed override line (no '='): $line"
    continue
  fi

  name="${line%%=*}"
  value="${line#*=}"

  if [[ -z "$value" ]]; then
    continue
  fi

  echo "Using provided $name secret"
  echo "::add-mask::$value"
  echo "$name=$value" >> "$GITHUB_ENV"
done <<< "$OVERRIDES"
