#!/bin/sh

# OriginGame thin Plugin installer: one browser login, then the live catalog's
# Skills and remote MCP servers are projected into the Agent clients you choose.
# It installs no OriginGame binary, runtime, package manager dependency, or daemon.

set -eu

PORTAL_ORIGIN='https://origingame.dev'
GATEWAY_ORIGIN='https://api.origingame.dev'
MANIFEST_URL="$PORTAL_ORIGIN/api/connector/install/manifest.tsv"
CREDENTIAL_DIR="$HOME/.origingame"
CREDENTIAL_FILE="$CREDENTIAL_DIR/connector-credential"
AGENTS_ARG=''

say() { printf '%s\n' "$*"; }
die() { printf 'OriginGame: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install.sh [--agents claude,codex,grok]

Without --agents, the installer detects installed Agent clients and lets you
confirm the selection. Re-run the command at any time to update the Plugin.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agents)
      [ "$#" -ge 2 ] || die '--agents requires a comma-separated value'
      AGENTS_ARG=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

for required in curl unzip grep sed awk head wc tr; do
  command -v "$required" >/dev/null 2>&1 || die "$required is required"
done

if command -v sha256sum >/dev/null 2>&1; then
  file_sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  file_sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  die 'sha256sum or shasum is required'
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/origingame-install.XXXXXX")
cleanup() { rm -rf "$work_dir"; }
trap cleanup 0
trap 'exit 1' HUP INT TERM
manifest_file="$work_dir/manifest.tsv"

say 'OriginGame Plugin'
say 'Fetching the live Skill and MCP catalog…'
curl -fsSL --proto '=https' --tlsv1.2 "$MANIFEST_URL" -o "$manifest_file" \
  || die 'could not fetch the live Plugin catalog'

TAB=$(printf '\t')
catalog_version=''
skill_count=0
mcp_count=0
line_number=0
while IFS="$TAB" read -r kind first second third fourth extra; do
  line_number=$((line_number + 1))
  case "$kind" in
    origin-connector-v1)
      [ "$line_number" -eq 1 ] && [ -n "$first" ] && [ -z "$second$third$fourth$extra" ] \
        || die 'the Plugin catalog header is invalid'
      catalog_version=$first
      ;;
    skill)
      [ -n "$catalog_version" ] && [ -n "$first" ] && [ -n "$second" ] && [ -n "$third" ] && [ -n "$fourth" ] && [ -z "$extra" ] \
        || die "invalid Skill entry on catalog line $line_number"
      case "$first" in *[!a-z0-9._-]*|'') die "invalid Skill id: $first" ;; esac
      case "$second" in "$PORTAL_ORIGIN/api/connector/skills/"*) ;; *) die "untrusted Skill archive URL for $first" ;; esac
      [ "${#third}" -eq 64 ] || die "invalid Skill digest for $first"
      case "$third" in *[!0-9a-f]*) die "invalid Skill digest for $first" ;; esac
      case "$fourth" in *[!0-9]*|'') die "invalid Skill size for $first" ;; esac
      skill_count=$((skill_count + 1))
      ;;
    mcp)
      [ -n "$catalog_version" ] && [ -n "$first" ] && [ -n "$second" ] && [ -n "$third" ] && [ -z "$fourth$extra" ] \
        || die "invalid MCP entry on catalog line $line_number"
      case "$first" in *[!a-z0-9_-]*|'') die "invalid MCP id: $first" ;; esac
      case "$second" in https://*) ;; *) die "MCP $first does not use HTTPS" ;; esac
      case "$second" in *'"'*|*'\'*) die "invalid MCP URL for $first" ;; esac
      case "$third" in
        connection_bearer)
          case "$second" in https://mcp.origingame.dev/*) ;; *) die "untrusted credential destination for $first" ;; esac
          ;;
        none) ;;
        *) die "unknown MCP authorization for $first" ;;
      esac
      mcp_count=$((mcp_count + 1))
      ;;
    '') ;;
    *) die "unknown catalog entry on line $line_number" ;;
  esac
done < "$manifest_file"
[ -n "$catalog_version" ] && [ "$skill_count" -gt 0 ] && [ "$mcp_count" -gt 0 ] \
  || die 'the Plugin catalog is empty or incomplete'

detected_agents=''
for agent in claude codex grok; do
  if command -v "$agent" >/dev/null 2>&1; then
    detected_agents="$detected_agents $agent"
  fi
done
detected_agents=${detected_agents# }

normalize_agents() {
  value=$(printf '%s' "$1" | tr ',' ' ')
  selected=''
  if [ "$value" = all ]; then value=$detected_agents; fi
  for agent in $value; do
    case "$agent" in claude|codex|grok) ;; *) die "unsupported Agent: $agent" ;; esac
    command -v "$agent" >/dev/null 2>&1 || die "$agent is not installed or not on PATH"
    case " $selected " in *" $agent "*) ;; *) selected="$selected $agent" ;; esac
  done
  selected=${selected# }
  [ -n "$selected" ] || die 'select at least one installed Agent'
}

if [ -n "$AGENTS_ARG" ]; then
  normalize_agents "$AGENTS_ARG"
else
  [ -n "$detected_agents" ] || die 'no supported Agent found (install Claude Code, Codex, or Grok first)'
  selected=$detected_agents
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf 'Detected: %s\nInstall for these Agents? [Y/n or comma-separated list] ' "$detected_agents" > /dev/tty
    answer=''
    IFS= read -r answer < /dev/tty || true
    case "$answer" in
      ''|y|Y|yes|YES) ;;
      n|N|no|NO) die 'installation cancelled' ;;
      *) normalize_agents "$answer" ;;
    esac
  fi
fi
say "Agents: $selected"

json_string() {
  key=$1
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$2" | head -n 1
}

json_number() {
  key=$1
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$2" | head -n 1
}

valid_credential() {
  candidate=$1
  [ "${#candidate}" -eq 51 ] || return 1
  [ "${candidate#sk-}" != "$candidate" ] || return 1
  case "${candidate#sk-}" in *[!0-9A-Za-z]*) return 1 ;; esac
  return 0
}

credential=''
if [ -f "$CREDENTIAL_FILE" ]; then
  candidate=$(cat "$CREDENTIAL_FILE")
  if valid_credential "$candidate"; then
    status=$(curl -sS --max-time 20 -o "$work_dir/provisioning.json" -w '%{http_code}' \
      -H "Authorization: Bearer $candidate" \
      "$GATEWAY_ORIGIN/api/connector/provisioning" || printf '000')
    case "$status" in
      200) credential=$candidate; say 'Using your existing OriginGame login.' ;;
      404) ;;
      *) die 'could not validate the existing OriginGame login; try again later' ;;
    esac
  fi
fi

open_browser() {
  target=$1
  if command -v open >/dev/null 2>&1; then
    open "$target" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$target" >/dev/null 2>&1 || true
  elif command -v wslview >/dev/null 2>&1; then
    wslview "$target" >/dev/null 2>&1 || true
  fi
}

if [ -z "$credential" ]; then
  curl -fsS --proto '=https' --tlsv1.2 \
    -H 'Content-Type: application/json' \
    -d '{"device_name":"Shell installer"}' \
    "$GATEWAY_ORIGIN/api/connector/device/authorizations" \
    -o "$work_dir/device.json" \
    || die 'could not start OriginGame login'
  device_code=$(json_string device_code "$work_dir/device.json")
  user_code=$(json_string user_code "$work_dir/device.json")
  verification_uri=$(json_string verification_uri_complete "$work_dir/device.json")
  expires_in=$(json_number expires_in "$work_dir/device.json")
  interval=$(json_number interval "$work_dir/device.json")
  [ -n "$device_code" ] && [ -n "$user_code" ] && [ -n "$verification_uri" ] \
    || die 'OriginGame returned an invalid login response'
  [ "${#device_code}" -eq 64 ] || die 'OriginGame returned an invalid device code'
  case "$device_code" in *[!0-9A-Za-z]*) die 'OriginGame returned an invalid device code' ;; esac
  case "$verification_uri" in "$PORTAL_ORIGIN/connector/authorize?user_code="*) ;; *) die 'OriginGame returned an untrusted login URL' ;; esac
  case "$expires_in" in *[!0-9]*|'') die 'OriginGame returned an invalid login lifetime' ;; esac
  case "$interval" in *[!0-9]*|'') die 'OriginGame returned an invalid polling interval' ;; esac
  [ "$expires_in" -ge 60 ] && [ "$expires_in" -le 900 ] || die 'OriginGame returned an invalid login lifetime'
  [ "$interval" -ge 2 ] && [ "$interval" -le 30 ] || die 'OriginGame returned an invalid polling interval'

  say ''
  say "Confirm code $user_code in your browser:"
  say "$verification_uri"
  open_browser "$verification_uri"

  deadline=$(($(date +%s) + expires_in))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep "$interval"
    status=$(curl -sS --max-time 20 -o "$work_dir/token.json" -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -d "{\"device_code\":\"$device_code\"}" \
      "$GATEWAY_ORIGIN/api/connector/device/token" || printf '000')
    case "$status" in
      200)
        candidate=$(json_string access_token "$work_dir/token.json")
        valid_credential "$candidate" || die 'OriginGame returned an invalid credential'
        credential=$candidate
        break
        ;;
      400)
        error_code=$(json_string error "$work_dir/token.json")
        case "$error_code" in
          authorization_pending) ;;
          expired_token) die 'the login code expired; run the installer again' ;;
          *) die "OriginGame login failed: ${error_code:-invalid response}" ;;
        esac
        ;;
      429) sleep "$interval" ;;
      *) die 'OriginGame login is temporarily unavailable' ;;
    esac
  done
  [ -n "$credential" ] || die 'the login code expired; run the installer again'
  umask 077
  mkdir -p "$CREDENTIAL_DIR"
  printf '%s\n' "$credential" > "$CREDENTIAL_FILE.tmp.$$"
  mv "$CREDENTIAL_FILE.tmp.$$" "$CREDENTIAL_FILE"
  chmod 600 "$CREDENTIAL_FILE"
  say 'OriginGame login complete.'
fi

has_agent() {
  case " $selected " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

skill_root() {
  case "$1" in
    claude) printf '%s/.claude/skills' "$HOME" ;;
    codex) printf '%s/.agents/skills' "$HOME" ;;
    grok) printf '%s/.grok/skills' "$HOME" ;;
  esac
}

install_skill() {
  id=$1
  archive_url=$2
  expected_sha=$3
  expected_size=$4
  archive="$work_dir/$id.zip"
  entries="$work_dir/$id.entries"
  stage="$work_dir/$id.stage"

  curl -fsSL --proto '=https' --tlsv1.2 "$archive_url" -o "$archive" \
    || die "could not download Skill $id"
  actual_size=$(wc -c < "$archive" | tr -d '[:space:]')
  [ "$actual_size" = "$expected_size" ] || die "size verification failed for Skill $id"
  actual_sha=$(file_sha256 "$archive")
  [ "$actual_sha" = "$expected_sha" ] || die "digest verification failed for Skill $id"
  unzip -Z1 "$archive" > "$entries" || die "Skill $id is not a readable ZIP archive"
  [ -s "$entries" ] || die "Skill $id is empty"
  if grep -Eq '(^/|(^|/)\.\.(/|$)|\\)' "$entries"; then
    die "Skill $id contains an unsafe archive path"
  fi
  grep -qx 'SKILL.md' "$entries" || die "Skill $id has no root SKILL.md"
  mkdir -p "$stage"
  unzip -qq "$archive" -d "$stage" || die "could not extract Skill $id"

  for agent in $selected; do
    root=$(skill_root "$agent")
    target="$root/$id"
    mkdir -p "$root"
    if [ -e "$target" ] || [ -L "$target" ]; then
      if [ -f "$target/.origingame-managed" ]; then
        rm -rf "$target"
      else
        backup="$target.before-origingame-$(date +%Y%m%d%H%M%S)-$$"
        mv "$target" "$backup" || die "could not back up existing Skill $target"
        say "Backed up existing $target to $backup"
      fi
    fi
    cp -R "$stage" "$target" || die "could not install Skill $id for $agent"
    printf '%s\n' "$catalog_version" > "$target/.origingame-managed"
    [ -f "$target/SKILL.md" ] || die "Skill verification failed for $agent: $id"
  done
}

remove_codex_managed_block() {
  id=$1
  config="$HOME/.codex/config.toml"
  [ -f "$config" ] || return 0
  begin="# BEGIN ORIGINGAME MCP $id"
  end="# END ORIGINGAME MCP $id"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { managed = 1; next }
    $0 == end { managed = 0; next }
    !managed { print }
  ' "$config" > "$work_dir/codex-config.toml"
  mv "$work_dir/codex-config.toml" "$config"
}

configure_codex_mcp() {
  id=$1
  url=$2
  authorization=$3
  config_dir="$HOME/.codex"
  config="$config_dir/config.toml"
  mkdir -p "$config_dir"
  [ -f "$config" ] || : > "$config"

  if grep -Fq "# BEGIN ORIGINGAME MCP $id" "$config"; then
    remove_codex_managed_block "$id"
  else
    codex mcp remove "$id" >/dev/null 2>&1 || true
  fi
  if grep -Fq "[mcp_servers.\"$id\"]" "$config" || grep -Fq "[mcp_servers.$id]" "$config"; then
    die "Codex still has an unmanaged MCP named $id; remove it and re-run the installer"
  fi
  {
    printf '\n# BEGIN ORIGINGAME MCP %s\n' "$id"
    printf '[mcp_servers."%s"]\n' "$id"
    printf 'url = "%s"\n' "$url"
    if [ "$authorization" = connection_bearer ]; then
      printf 'http_headers = { Authorization = "Bearer %s" }\n' "$credential"
    fi
    printf '# END ORIGINGAME MCP %s\n' "$id"
  } >> "$config"
  chmod 600 "$config"
}

configure_mcp() {
  id=$1
  url=$2
  authorization=$3
  if has_agent claude; then
    claude mcp remove "$id" --scope user >/dev/null 2>&1 || true
    if [ "$authorization" = connection_bearer ]; then
      claude mcp add --transport http --scope user "$id" "$url" --header "Authorization: Bearer $credential" >/dev/null 2>&1 \
        || die "could not configure MCP $id for Claude Code"
    else
      claude mcp add --transport http --scope user "$id" "$url" >/dev/null 2>&1 \
        || die "could not configure MCP $id for Claude Code"
    fi
  fi
  if has_agent codex; then
    configure_codex_mcp "$id" "$url" "$authorization"
  fi
  if has_agent grok; then
    grok mcp remove "$id" >/dev/null 2>&1 || true
    if [ "$authorization" = connection_bearer ]; then
      grok mcp add --transport http "$id" "$url" --header "Authorization: Bearer $credential" >/dev/null 2>&1 \
        || die "could not configure MCP $id for Grok"
    else
      grok mcp add --transport http "$id" "$url" >/dev/null 2>&1 \
        || die "could not configure MCP $id for Grok"
    fi
  fi
}

say "Installing $skill_count Skills from catalog $catalog_version…"
while IFS="$TAB" read -r kind first second third fourth extra; do
  [ "$kind" = skill ] || continue
  install_skill "$first" "$second" "$third" "$fourth"
done < "$manifest_file"

say "Configuring $mcp_count remote MCP servers with the same login…"
while IFS="$TAB" read -r kind first second third fourth extra; do
  [ "$kind" = mcp ] || continue
  configure_mcp "$first" "$second" "$third"
done < "$manifest_file"

for agent in $selected; do
  case "$agent" in
    claude) claude mcp list >/dev/null 2>&1 || die 'Claude Code rejected its MCP configuration' ;;
    codex) codex mcp list >/dev/null 2>&1 || die 'Codex rejected its MCP configuration' ;;
    grok) grok mcp list >/dev/null 2>&1 || die 'Grok rejected its MCP configuration' ;;
  esac
done

say ''
say "OriginGame Plugin is ready for: $selected"
say "$skill_count Skills and $mcp_count MCP servers share one revocable login."
say 'Re-run the same command to update. Revoke access any time from Dashboard → Devices.'
