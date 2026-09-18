#!/bin/bash
# Acceptance: the CLI must never delete anything it cannot prove it can restore,
# and must never widen its scope beyond what was asked for.
#
# SAFETY: this script runs `reclaim --confirm`, which really does delete. It is
# therefore pinned to a throwaway catalogue under $TMP via RECLAIM_CATALOGUE, so
# the real bundled catalogue — which points at ~/.ollama, ~/.npm and friends — is
# never in scope. On 2026-09-09 an earlier version of this script omitted that
# pin and destroyed 37GB of real caches. Do not remove it.
set -euo pipefail

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/npm-cache"
DECOY="$TMP/decoy-cache"
mkdir -p "$FIXTURE" "$DECOY"
head -c 4096 /dev/zero > "$FIXTURE/blob"
head -c 4096 /dev/zero > "$DECOY/blob"

# A catalogue containing only fixtures. The decoy is catalogued and fully
# reclaimable, so it proves that an explicit path narrows the run.
export RECLAIM_CATALOGUE="$TMP/catalogue.json"
cat > "$RECLAIM_CATALOGUE" <<EOF
{"version":1,"entries":[
  {"id":"decoy.cache","displayName":"decoy","path":"$DECOY","tier":"exact",
   "recipeKind":"npmCleanInstall","validator":"alwaysProven"}
]}
EOF

swift build -q

echo "== scan =="
SCAN=$(swift run -q reclaim scan "$FIXTURE")
echo "$SCAN"
# Must actually report the fixture, so a stub binary cannot pass this script.
echo "$SCAN" | grep -q "$FIXTURE" || { echo "FAIL: scan did not report the fixture"; exit 1; }
echo "$SCAN" | grep -q "unknown" || { echo "FAIL: uncatalogued fixture not marked unknown"; exit 1; }

echo
echo "== an explicit path narrows the scan to that path =="
echo "$SCAN" | grep -q "$DECOY" && { echo "FAIL: scan widened beyond the explicit path"; exit 1; }
echo "ok: catalogued decoy was not surveyed"

echo
echo "== reclaim without --confirm (must not delete) =="
swift run -q reclaim reclaim "$FIXTURE"
test -e "$FIXTURE/blob" || { echo "FAIL: deleted without --confirm"; exit 1; }
echo "ok: fixture survived"

echo
echo "== unknown paths are never actioned even with --confirm =="
RECLAIM_OUT=$(swift run -q reclaim reclaim --confirm "$FIXTURE")
echo "$RECLAIM_OUT"
test -e "$FIXTURE/blob" || { echo "FAIL: deleted an unclassified path"; exit 1; }
echo "ok: unclassified fixture survived --confirm"

echo
echo "== --confirm on an explicit path does not touch the rest of the catalogue =="
test -e "$DECOY/blob" || { echo "FAIL: reclaimed a catalogue entry that was not in scope"; exit 1; }
echo "ok: out-of-scope catalogue entry survived --confirm"

echo
echo "== a template recipe is not proof of restorability =="
TEMPLATE="$TMP/ollama"
mkdir -p "$TEMPLATE"
head -c 4096 /dev/zero > "$TEMPLATE/blob"
cat > "$RECLAIM_CATALOGUE" <<EOF
{"version":1,"entries":[
  {"id":"ollama.models","displayName":"ollama","path":"$TEMPLATE","tier":"exact",
   "recipeKind":"ollamaPull","validator":"alwaysProven"}
]}
EOF
PLAN_OUT=$(swift run -q reclaim plan "$TEMPLATE")
echo "$PLAN_OUT"
# Validation downgrades a template recipe to irreplaceable, so the executor's
# own template guard (covered by RegressionTests) never gets the chance to fire.
echo "$PLAN_OUT" | grep -q "irreplaceable" || { echo "FAIL: template recipe was accepted as proof"; exit 1; }
echo "$PLAN_OUT" | grep -q "reclaimable: 0.0 B" || { echo "FAIL: template recipe counted as reclaimable"; exit 1; }
swift run -q reclaim reclaim --confirm "$TEMPLATE" > /dev/null
test -e "$TEMPLATE/blob" || { echo "FAIL: deleted with only a template recipe"; exit 1; }
echo "ok: template recipe refused"

echo
echo "ACCEPTANCE PASS"
