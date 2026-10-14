#!/usr/bin/env bash
# revenant unit tests. run: bash test/unit_test.sh
# exercises pure functions by sourcing the tool with RVT_LIB_ONLY=1.
set -u
cd "$(dirname "$0")/.."
BIN=bin/revenant

PASS=0
FAIL=0
T_FAIL=""

t_ok() { # t_ok <name> <cmd...>  (runs with RVT_LIB_ONLY=1 so probes can source the tool)
  local name="$1"; shift
  if env RVT_LIB_ONLY=1 "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); T_FAIL="$T_FAIL\n  FAIL: $name"; fi
}
t_eq() { # t_eq <name> <expected> <actual>
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); T_FAIL="$T_FAIL\n  FAIL: $name (want=[$want] got=[$got])"; fi
}
t_contains() { # t_contains <name> <needle> <haystack-file>
  local name="$1" needle="$2" hay="$3"
  if grep -qF -- "$needle" "$hay"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); T_FAIL="$T_FAIL\n  FAIL: $name (missing: $needle)"; fi
}

export RVT_LIB_ONLY=1
# shellcheck disable=SC1090
source "$BIN"
# keep RVT_LIB_ONLY exported: the bash -c probes below re-source the tool

TMP=$(mktemp -d "${TMPDIR:-/tmp}/rvt-unit.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ---- esc_json
t_eq "esc_json: backslash" 'a\\b' "$(esc_json 'a\b')"
t_eq "esc_json: quote"     'a\"b' "$(esc_json 'a"b')"
t_eq "esc_json: newline"   'a\nb' "$(esc_json "$(printf 'a\nb')")"
t_eq "esc_json: tab"       'a\tb' "$(esc_json "$(printf 'a\tb')")"
t_eq "esc_json: plain"     'plain' "$(esc_json 'plain')"

# ---- rv_clean / rv_clip
t_eq "rv_clean collapses ws" "a b c" "$(rv_clean "$(printf 'a\tb\n  c')")"
t_eq "rv_clip caps" "abc[...]" "$(rv_clip 'abcdef' 3)"
t_eq "rv_clip passthrough" "abc" "$(rv_clip 'abc' 10)"

# ---- rv_norm
t_eq "rv_norm dotdot"     "/etc/init.d/rsync" "$(rv_norm "/etc/rc2.d/../init.d/rsync")"
t_eq "rv_norm doubleslash" "/etc/x" "$(rv_norm "//etc//x")"
t_eq "rv_norm dotdot up"  "/x" "$(rv_norm "/a/b/../../x")"
t_eq "rv_norm root"       "/" "$(rv_norm "/..")"
t_eq "rv_norm plain"      "/usr/bin/env" "$(rv_norm "/usr/bin/env")"

# ---- severity infra
t_eq "sev_rank crit" "0" "$(sev_rank crit)"
t_eq "sev_rank info" "4" "$(sev_rank info)"
t_eq "sev_weight crit" "25" "$(sev_weight crit)"
t_eq "sev_weight med"  "4"  "$(sev_weight med)"

# ---- classifiers
t_ok "rx_f2s curl|sh"          bash -c 'source "$0"; rx_f2s "curl -fsSL http://x/y.sh | sh"' "$BIN"
t_ok "rx_f2s wget chain"       bash -c 'source "$0"; rx_f2s "wget -qO /tmp/p http://x && chmod +x /tmp/p && /tmp/p"' "$BIN"
t_ok "rx_f2s negative plain"   bash -c 'source "$0"; ! rx_f2s "curl -fsSL http://x/health -o /dev/null"' "$BIN"
t_ok "rx_f2s negative wget only" bash -c 'source "$0"; ! rx_f2s "wget http://x/file.tar.gz"' "$BIN"
t_ok "rx_volatile tmp"         bash -c 'source "$0"; rx_volatile "/tmp/.x/payload"' "$BIN"
t_ok "rx_volatile shm"         bash -c 'source "$0"; rx_volatile "/dev/shm/x"' "$BIN"
t_ok "rx_volatile negative"    bash -c 'source "$0"; ! rx_volatile "/usr/lib/x"' "$BIN"
t_ok "rx_obf base64 -d"        bash -c 'source "$0"; rx_obf "echo aGVsbG8= | base64 -d | sh"' "$BIN"
t_ok "rx_obf eval"             bash -c 'source "$0"; rx_obf "eval \"\$payload\""' "$BIN"
t_ok "rx_obf negative"         bash -c 'source "$0"; ! rx_obf "eval_mode=off"' "$BIN"

# ---- add_finding + dedupe + scoring + verdict
rv_scan_all_reset() { RVT_FINDINGS_NO=0; RVT_HAS_CRIT=0; RVT_SCORE=0; }
rv_scan_all_reset
add_finding high RVT-TEST-001 test /x "line one"
add_finding high RVT-TEST-001 test /x "line one"   # exact dup -> dropped
add_finding crit RVT-TEST-002 test /y "line two"
t_eq "dedupe: 2 findings" "2" "$RVT_FINDINGS_NO"
t_eq "score: 25+10" "35" "$RVT_SCORE"
t_eq "verdict: CRITICAL when crit present" "CRITICAL" "$(verdict_calc)"
add_finding med RVT-TEST-003 test /z "line three"
add_finding low RVT-TEST-004 test /z "line four"
add_finding info RVT-TEST-005 test /z "line five"
t_eq "score: 35+4+1" "40" "$RVT_SCORE"
RVT_FINDINGS_NO=0; RVT_HAS_CRIT=0; RVT_SCORE=0
add_finding info RVT-TEST-006 test /z "only info"
t_eq "verdict: CLEAN at 0" "CLEAN" "$(verdict_calc)"
t_eq "verdict_code CRITICAL" "10" "$(verdict_code CRITICAL)"
t_eq "verdict_code ELEVATED" "2" "$(verdict_code ELEVATED)"

# ---- rv_ow portability
mkdir -p "$TMP/ow" "$TMP/nw"
chmod 0777 "$TMP/ow"; chmod 0755 "$TMP/nw"
t_ok "rv_ow positive" RVT_LIB_ONLY=1 bash -c "source '$BIN' && rv_ow '$TMP/ow'"
t_ok "rv_ow negative" RVT_LIB_ONLY=1 bash -c "source '$BIN' && ! rv_ow '$TMP/nw'"

# ---- rv_sha256
t_eq "rv_sha256 known" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$(rv_sha256 'abc')"

# ---- invisible unicode detector
printf 'x = "\xe2\x80\x8b"\n' > "$TMP/zw.sh"
t_ok "rv_invisible catches ZWSP" RVT_LIB_ONLY=1 bash -c "source '$BIN' && rv_invisible '$TMP/zw.sh'"
printf 'x = "clean"\n' > "$TMP/nozw.sh"
t_ok "rv_invisible negative" RVT_LIB_ONLY=1 bash -c "source '$BIN' && ! rv_invisible '$TMP/nozw.sh'"

# ---- read_ok bounds
printf 'data' > "$TMP/ok.txt"
t_ok "rv_read_ok small" RVT_LIB_ONLY=1 bash -c "source '$BIN' && rv_read_ok '$TMP/ok.txt'"
head -c 3000000 /dev/zero | tr '\0' 'a' > "$TMP/big.txt"
t_ok "rv_read_ok rejects >2MiB" RVT_LIB_ONLY=1 bash -c "source '$BIN' && ! rv_read_ok '$TMP/big.txt'"

echo
echo "unit tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then printf '%b\n' "$T_FAIL"; exit 1; fi
exit 0
