#!/usr/bin/env bash
#
# claude-quota.sh — show Claude Code subscription quota (5-hour + weekly).
#
#   claude-quota.sh            full readable report
#   claude-quota.sh --short    one line: 5h:83% (2h21m)  7d:85% (3d10h)
#   claude-quota.sh --json     raw API JSON
#
# Reuses the Claude Code CLI's stored OAuth token (macOS Keychain, or
# ~/.claude/.credentials.json on Linux/WSL), refreshes it if expired, and calls
# the same private endpoint the CLI's /usage command uses.
#
# Deps: curl, jq.  macOS also uses `security` (Keychain).

set -euo pipefail

USAGE_URL="https://api.anthropic.com/api/oauth/usage"
TOKEN_URL="https://platform.claude.com/v1/oauth/token"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_BETA="oauth-2025-04-20"
SERVICE="Claude Code-credentials"
UA="claude-cli/2.1.185 (external, cli)"
CRED_FILE="$HOME/.claude/.credentials.json"
REFRESH_SKEW_MS=60000   # refresh if it expires within a minute

die() { echo "Error: $*" >&2; exit 1; }
command -v jq   >/dev/null || die "jq not found"
command -v curl >/dev/null || die "curl not found"

# ---- credential read/write -------------------------------------------------
read_blob() {
  if [[ "$(uname)" == "Darwin" ]]; then
    security find-generic-password -s "$SERVICE" -w 2>/dev/null \
      || die "no Keychain item '$SERVICE' (is Claude Code logged in?)"
  else
    [[ -f "$CRED_FILE" ]] || die "no credentials at $CRED_FILE"
    cat "$CRED_FILE"
  fi
}

write_blob() {  # $1 = full JSON blob
  if [[ "$(uname)" == "Darwin" ]]; then
    security add-generic-password -U -s "$SERVICE" -a "$USER" -w "$1"
  else
    umask 177; printf '%s' "$1" > "$CRED_FILE"
  fi
}

# ---- get a valid access token (refresh if needed) --------------------------
get_token() {
  local blob exp now_ms
  blob="$(read_blob)"
  exp="$(jq -r '.claudeAiOauth.expiresAt // 0' <<<"$blob")"
  now_ms=$(( $(date +%s) * 1000 ))

  if (( now_ms < exp - REFRESH_SKEW_MS )); then
    jq -r '.claudeAiOauth.accessToken' <<<"$blob"
    return
  fi

  echo "• access token expired — refreshing…" >&2
  local refresh resp access new_refresh expires_in new_exp new_blob
  refresh="$(jq -r '.claudeAiOauth.refreshToken' <<<"$blob")"
  resp="$(curl -sS -X POST "$TOKEN_URL" \
    -H "Content-Type: application/json" \
    -H "anthropic-beta: $OAUTH_BETA" \
    -H "User-Agent: $UA" \
    -d "$(jq -n --arg rt "$refresh" --arg cid "$CLIENT_ID" \
            '{grant_type:"refresh_token",refresh_token:$rt,client_id:$cid}')")"

  access="$(jq -r '.access_token // empty' <<<"$resp")"
  [[ -n "$access" ]] || die "refresh failed: $resp"
  new_refresh="$(jq -r '.refresh_token // empty' <<<"$resp")"
  [[ -n "$new_refresh" ]] || new_refresh="$refresh"   # fall back if not rotated
  expires_in="$(jq -r '.expires_in // 0' <<<"$resp")"
  new_exp=$(( now_ms + expires_in * 1000 ))

  # merge rotated tokens back into the full blob (preserves mcpOAuth etc.)
  new_blob="$(jq --arg at "$access" --arg rt "$new_refresh" --argjson exp "$new_exp" \
    '.claudeAiOauth.accessToken=$at | .claudeAiOauth.refreshToken=$rt | .claudeAiOauth.expiresAt=$exp' \
    <<<"$blob")"
  write_blob "$new_blob"
  printf '%s' "$access"
}

# ---- fetch usage -----------------------------------------------------------
TOKEN="$(get_token)"
USAGE="$(curl -sS "$USAGE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-beta: $OAUTH_BETA" \
  -H "User-Agent: $UA")"

jq -e 'has("five_hour")' <<<"$USAGE" >/dev/null 2>&1 || die "unexpected response: $USAGE"

# shared jq helpers: % left, and a humanized "time until reset"
JQ_HELPERS='
  def left: if .==null then null else (100 - .utilization) end;
  def secs(iso): if iso==null then null
    else ((iso|sub("\\.[0-9]+";"")|sub("\\+00:00";"Z")|fromdateiso8601) - now) end;
  def human(s): if s==null then "n/a" elif s<=0 then "now"
    else (s/86400|floor) as $d | ((s%86400)/3600|floor) as $h | ((s%3600)/60|floor) as $m
      | if $d>0 then "\($d)d\($h)h" elif $h>0 then "\($h)h\($m)m" else "\($m)m" end end;
'

# ---- output modes ----------------------------------------------------------
mode="${1:-full}"
NOW_STR="$(date '+%-I:%M %p' | tr 'A-Z' 'a-z')"   # e.g. "11:06 pm" (local machine time)
case "$mode" in
  --json)
    jq . <<<"$USAGE" ;;

  --short|-s)
    jq -r --arg now "$NOW_STR" "$JQ_HELPERS"'
      [ (if .five_hour then "5h:\(.five_hour|left|floor)% left (\(human(secs(.five_hour.resets_at))))" else empty end),
        (if .seven_day then "7d:\(.seven_day|left|floor)% left (\(human(secs(.seven_day.resets_at))))" else empty end),
        "now \($now)"
      ] | join("  ·  ")' <<<"$USAGE" ;;

  full|"")
    jq -r --arg now "$NOW_STR" "$JQ_HELPERS"'
      def bar(u): (u/5|floor) as $f | ("█"*$f) + ("░"*(20-$f));
      def row(lbl;w): if w==null then "  \(lbl|.+" "*(16-length))(not active)"
        else "  \(lbl|.+" "*(16-length))\(bar(w.utilization))  \((w|left|floor)|tostring|(" "*(3-length))+.)% left  (used \(w.utilization|floor)%)  resets in \(human(secs(w.resets_at)))" end;
      "\n  Claude Code quota",
      "  Current Time: \($now)",
      "  " + ("─"*70),
      row("5-hour session"; .five_hour),
      row("7-day (all)";    .seven_day),
      (if .seven_day_opus   then row("7-day Opus";   .seven_day_opus)   else empty end),
      (if .seven_day_sonnet then row("7-day Sonnet"; .seven_day_sonnet) else empty end),
      ""' <<<"$USAGE" ;;

  *) die "unknown option: $mode (use --short, --json, or no arg)" ;;
esac
