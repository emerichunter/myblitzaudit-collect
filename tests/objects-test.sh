#!/usr/bin/env bash
# Verifie un bundle d'objets : chaque compteur annonce doit correspondre a un
# fichier reel, et chaque table du catalogue doit avoir son CREATE.
# Usage : ./tests/objects-test.sh <bundle>
set -euo pipefail

BUNDLE="${1:-}"
[[ -d "$BUNDLE" ]] || { echo "usage: $0 <bundle>" >&2; exit 2; }
OBJ="${BUNDLE}/objects"
[[ -d "$OBJ" ]] || { echo "ECHEC: pas de dossier objects/ dans $BUNDLE" >&2; exit 1; }

fail=0
say() { printf '%-6s %s\n' "$1" "$2"; }
ok()   { say "PASS" "$1"; }
ko()   { say "FAIL" "$1"; fail=$((fail+1)); }

# 1. resume lisible
[[ -f "$OBJ/objects_summary.json" ]] && ok "objects_summary.json present" \
  || ko "objects_summary.json absent"

# 2. structure non vide
for f in tables columns indexes fks checks partitions histograms schemata; do
  if [[ -f "$OBJ/${f}.tsv.gz" ]]; then
    n=$(zcat "$OBJ/${f}.tsv.gz" | wc -l)
    ok "${f}.tsv.gz : ${n} lignes"
  else
    ko "${f}.tsv.gz absent"
  fi
done

# 3. DDL : nombre de CREATE egal au nombre de tables du catalogue
if compgen -G "$OBJ/ddl/*.gz" > /dev/null; then
  n_ddl=$(zcat "$OBJ"/ddl/*.gz | grep -c '^CREATE ' || true)
  n_cat=$(python3 - "$BUNDLE" <<'PY'
import json, glob, sys
total = 0
for f in glob.glob(sys.argv[1] + '/catalog_db_*.json'):
    d = json.load(open(f))
    total += len(d.get('tables') or [])
print(total)
PY
)
  if [[ "$n_ddl" -ge "$n_cat" ]]; then
    ok "DDL : ${n_ddl} CREATE pour ${n_cat} tables"
  else
    ko "DDL : ${n_ddl} CREATE pour ${n_cat} tables"
  fi
else
  ko "aucun fichier DDL"
fi

# 4. instance : comptes agreges, jamais d'empreinte
if [[ -f "$OBJ/instance.json" ]]; then
  if grep -q 'authentication_string' "$OBJ/instance.json"; then
    ko "instance.json contient authentication_string"
  else
    ok "instance.json sans empreinte de mot de passe"
  fi
  python3 - "$OBJ/instance.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = d.get('comptes') or {}
print(f"       comptes: {c.get('nb','?')} | plugins: {c.get('plugins',{})}")
PY
else
  ko "instance.json absent"
fi

echo
if [[ "$fail" -eq 0 ]]; then
  echo "OBJETS: OK"
else
  echo "OBJETS: ${fail} echec(s)"
  exit 1
fi
