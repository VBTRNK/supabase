#!/usr/bin/env bash
# Writes the migrations `supabase db push` would apply to <plan-file>, one
# "<file> <sha256> <tool>" line each, and refuses any that no named tool owns.
# A tool owns a migration when its migrations directory (a checkout of that
# tool's repo at the dispatched ref) holds a byte-identical copy (VBTRNK/kut
# ADR-144, VBTRNK/cnc ADR-010). An empty plan file means the database is up to
# date.
#
# Usage: scripts/ci/plan-migrations.sh <plan-file> <tool>=<migrations-dir>...
#        e.g. plan-migrations.sh plan.txt kut=.kut/supabase/migrations cnc=.cnc/supabase/migrations
# Env:   DB_URL      connection URL without a password
#        PGPASSWORD  the password, read by the CLI from the environment
#        SUPABASE    CLI command (default: supabase)
set -euo pipefail

plan_file=${1:?plan file}
shift
(( $# > 0 )) || { echo "Name at least one <tool>=<migrations-dir>." >&2; exit 2; }
tools=()
dirs=()
for owner in "$@"; do
  [[ "$owner" =~ ^([a-z][a-z0-9-]*)=(.+)$ ]] || { echo "Not <tool>=<migrations-dir>: '$owner'." >&2; exit 2; }
  [[ -d "${BASH_REMATCH[2]}" ]] || { echo "No migrations directory for ${BASH_REMATCH[1]}: ${BASH_REMATCH[2]}." >&2; exit 2; }
  tools+=("${BASH_REMATCH[1]}")
  dirs+=("${BASH_REMATCH[2]}")
done
read -r -a cli <<< "${SUPABASE:-supabase}"
: "${DB_URL:?}" "${PGPASSWORD:?}"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

"${cli[@]}" migration list --agent no --db-url "$DB_URL"

if ! "${cli[@]}" db push --dry-run --agent no --db-url "$DB_URL" > "$work/dry.out" 2> "$work/dry.err"; then
  cat "$work/dry.out" "$work/dry.err" >&2
  echo "The dry run failed, so nothing is planned." >&2
  exit 1
fi
cat "$work/dry.err" "$work/dry.out"

: > "$plan_file"
# "Remote" against hosted, "Local" against a loopback test database.
if grep -qE '^(Remote|Local) database is up to date' "$work/dry.out" "$work/dry.err"; then
  echo "Plan: nothing pending."
  exit 0
fi
if ! grep -q '^Would push these migrations:' "$work/dry.err"; then
  echo "The dry run output has an unknown shape; refusing to plan." >&2
  exit 1
fi

refused=0
while IFS= read -r name; do
  if [[ ! "$name" =~ ^[0-9]{12,14}_[a-z0-9_]+\.sql$ ]]; then
    echo "REFUSED: unexpected migration name '$name'." >&2
    refused=1
    continue
  fi
  if [[ ! -f "supabase/migrations/$name" ]]; then
    echo "REFUSED: $name is not in this catalogue commit." >&2
    refused=1
    continue
  fi
  owner=""
  for i in "${!tools[@]}"; do
    if [[ -f "${dirs[$i]}/$name" ]] && cmp -s "supabase/migrations/$name" "${dirs[$i]}/$name"; then
      owner=${tools[$i]}
      break
    fi
  done
  if [[ -z "$owner" ]]; then
    echo "REFUSED: $name has no byte-identical copy in ${tools[*]} at the dispatched refs." >&2
    refused=1
  else
    echo "$name $(sha256sum "supabase/migrations/$name" | cut -d' ' -f1) $owner" >> "$plan_file"
  fi
done < <(sed -n 's/^ • //p' "$work/dry.err")

if [[ $refused -ne 0 ]]; then
  echo "Refusing the plan: every pending migration must belong to a tool named in this dispatch." >&2
  exit 1
fi
if [[ ! -s "$plan_file" ]]; then
  echo "The dry run listed no migrations; refusing to plan." >&2
  exit 1
fi
echo "Plan:"
cat "$plan_file"
