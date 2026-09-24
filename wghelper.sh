#!/bin/bash
# wghelper — privileged helper for wireguard-muti (macOS).
# Mirrors wgshell: Homebrew wireguard-tools + wg-quick, several tunnels at once.
set -euo pipefail

VERSION="4"
WG_DIR="/opt/homebrew/etc/wireguard"
WG_RUN_DIR="/var/run/wireguard"
WG_BIN=""
WG_QUICK_BIN=""
BREW_PREFIX="/opt/homebrew"

init_paths() {
  BREW_PREFIX="/opt/homebrew"
  WG_DIR="/opt/homebrew/etc/wireguard"
  WG_BIN="${BREW_PREFIX}/bin/wg"
  WG_QUICK_BIN="${BREW_PREFIX}/bin/wg-quick"
  [[ -x "$WG_BIN" ]] || WG_BIN="$(command -v wg || true)"
  [[ -x "$WG_QUICK_BIN" ]] || WG_QUICK_BIN="$(command -v wg-quick || true)"
  export PATH="${BREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

die() {
  echo "wghelper: $*" >&2
  exit 1
}

need_wg() {
  [[ -x "${WG_BIN:-}" && -x "${WG_QUICK_BIN:-}" ]] \
    || die "wg not found. Install with: brew install wireguard-tools"
}

valid_iface() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || die "invalid interface: $1"
}

valid_key() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || die "key name must be letters, numbers, '_' or '-'"
}

b64_file() {
  if [[ -f "$1" ]]; then
    base64 < "$1" | tr -d '\n'
  fi
  printf '\n'
}

b64_text() {
  if [[ -n "${1:-}" ]]; then
    printf '%s' "$1" | base64 | tr -d '\n'
  fi
  printf '\n'
}

list_wg_ifaces() {
  shopt -s nullglob
  local f
  for f in "${WG_DIR}"/*.conf; do
    basename "$f" .conf
  done | sort -V
}

# Key files (name-privatekey) without a matching .conf get a wgN.conf stub,
# same mapping wgshell uses under /opt/homebrew/etc/wireguard.
sync_orphan_keys() {
  mkdir -p "$WG_DIR"
  umask 077
  shopt -s nullglob
  local keyfile name iface priv pub
  for keyfile in "${WG_DIR}"/*-privatekey "${WG_DIR}"/*_private.key; do
    [[ -f "$keyfile" ]] || continue
    name="$(keyname_from_file "$keyfile")"
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    iface="$(iface_for_key "$name" || true)"
    [[ -z "$iface" ]] || continue
    priv="$(tr -d '[:space:]' < "$keyfile" 2>/dev/null || true)"
    [[ -n "$priv" ]] || continue
    iface="$(next_iface)"
    pub=""
    if [[ -x "${WG_BIN:-}" ]]; then
      pub="$(printf '%s\n' "$priv" | "$WG_BIN" pubkey 2>/dev/null || true)"
    fi
    printf '# Key = %s\n[Interface]\nPrivateKey = %s\n' "$name" "$priv" > "${WG_DIR}/${iface}.conf"
    chmod 600 "${WG_DIR}/${iface}.conf"
    if [[ ! -e "${WG_DIR}/${name}-publickey" && ! -e "${WG_DIR}/${name}_public.key" && -n "$pub" ]]; then
      printf '%s\n' "$pub" > "${WG_DIR}/${name}-publickey"
      chmod 600 "${WG_DIR}/${name}-publickey"
    fi
  done
}

real_iface() {
  local iface="$1" real
  local name_file="${WG_RUN_DIR}/${iface}.name"

  if [[ -x "${WG_BIN:-}" ]] && "$WG_BIN" show interfaces 2>/dev/null | tr ' ' '\n' | grep -qx "$iface"; then
    printf '%s\n' "$iface"
    return 0
  fi
  [[ -f "$name_file" ]] || return 0
  real="$(tr -d '[:space:]' < "$name_file" 2>/dev/null || true)"
  [[ "$real" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || return 0
  [[ -S "${WG_RUN_DIR}/${real}.sock" ]] || return 0
  if [[ -x "${WG_BIN:-}" ]] && "$WG_BIN" show interfaces 2>/dev/null | tr ' ' '\n' | grep -qx "$real"; then
    printf '%s\n' "$real"
  fi
}

keyname_from_file() {
  local base
  base="$(basename "$1")"
  case "$base" in
    *-privatekey) printf '%s\n' "${base%-privatekey}" ;;
    *_private.key) printf '%s\n' "${base%_private.key}" ;;
    *) printf '%s\n' "$base" ;;
  esac
}

key_for_iface() {
  local iface="$1"
  local conf="${WG_DIR}/${iface}.conf"
  local key priv keyfile file_priv

  [[ -f "$conf" ]] || return 0
  key="$(awk '/^# Key[[:space:]]*=/ { sub(/^# Key[[:space:]]*=[[:space:]]*/, ""); print; exit }' "$conf" 2>/dev/null || true)"
  [[ -n "$key" ]] && { printf '%s\n' "$key"; return; }

  priv="$(awk '/^[[:space:]]*PrivateKey[[:space:]]*=/ {
    sub(/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*/, "")
    gsub(/[[:space:]]/, "")
    print
    exit
  }' "$conf" 2>/dev/null || true)"
  [[ -n "$priv" ]] || return 0

  while IFS= read -r keyfile; do
    [[ -n "$keyfile" ]] || continue
    file_priv="$(tr -d '[:space:]' < "$keyfile" 2>/dev/null || true)"
    if [[ -n "$file_priv" && "$file_priv" == "$priv" ]]; then
      keyname_from_file "$keyfile"
      return
    fi
  done < <(find "$WG_DIR" -maxdepth 1 \( -name '*-privatekey' -o -name '*_private.key' \) -print 2>/dev/null)
}

iface_for_key() {
  local want="$1" iface key
  valid_key "$want"
  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    key="$(key_for_iface "$iface")"
    if [[ "$key" == "$want" ]]; then
      printf '%s\n' "$iface"
      return
    fi
  done < <(list_wg_ifaces)
}

next_iface() {
  mkdir -p "$WG_DIR"
  local n=0
  while [[ -e "${WG_DIR}/wg${n}.conf" ]]; do
    n=$((n + 1))
  done
  printf 'wg%s\n' "$n"
}

conf_value() {
  awk -v field="$2" '
    $0 ~ "^[[:space:]]*" field "[[:space:]]*=" {
      sub("^[[:space:]]*" field "[[:space:]]*=[[:space:]]*", "")
      if (n++) printf ", "
      printf "%s", $0
    }
    END { if (n) print "" }
  ' "$1" 2>/dev/null || true
}

restore_macos_dns() {
  local iface="$1"
  local conf="${WG_DIR}/${iface}.conf"
  local tun_dns svc current
  [[ -f "$conf" ]] || return 0
  tun_dns="$(conf_value "$conf" "DNS")"
  tun_dns="${tun_dns%%,*}"
  tun_dns="${tun_dns//[[:space:]]/}"

  if [[ -n "$tun_dns" ]]; then
    while IFS= read -r svc; do
      [[ -n "$svc" && "$svc" != \** ]] || continue
      current="$(networksetup -getdnsservers "$svc" 2>/dev/null || true)"
      if printf '%s\n' "$current" | grep -Fqx "$tun_dns"; then
        networksetup -setdnsservers "$svc" Empty >/dev/null 2>&1 || true
      fi
    done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
  fi
  dscacheutil -flushcache >/dev/null 2>/dev/null || true
  killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

write_key_files() {
  local keyname="$1" priv="$2"
  local pub=""
  valid_key "$keyname"
  mkdir -p "$WG_DIR"
  umask 077
  if [[ -n "$priv" && -x "${WG_BIN:-}" ]]; then
    pub="$(printf '%s\n' "$priv" | "$WG_BIN" pubkey 2>/dev/null || true)"
  fi
  printf '%s\n' "$priv" > "${WG_DIR}/${keyname}-privatekey"
  printf '%s\n' "$pub" > "${WG_DIR}/${keyname}-publickey"
  chmod 600 "${WG_DIR}/${keyname}-privatekey" "${WG_DIR}/${keyname}-publickey" 2>/dev/null || true
}

strip_key_comment() {
  awk 'BEGIN{skip=1} skip && /^# Key[[:space:]]*=/ { next } { skip=0; print }'
}

# wg-quick errors on a bare [Peer] with no PublicKey.
drop_empty_peers() {
  awk '
    function flush(    has_key) {
      if (block == "") return
      has_key = (block ~ /(^|\n)[[:space:]]*PublicKey[[:space:]]*=/)
      if (has_key) printf "%s", block
      block = ""
    }
    /^\[Peer\]/ {
      flush()
      inpeer = 1
      block = $0 "\n"
      next
    }
    /^\[/ {
      flush()
      inpeer = 0
      print
      next
    }
    inpeer { block = block $0 "\n"; next }
    { print }
    END { flush() }
  '
}

priv_from_conf() {
  awk '/^[[:space:]]*PrivateKey[[:space:]]*=/ {
    sub(/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*/, "")
    gsub(/[[:space:]]/, "")
    print
    exit
  }'
}

cmd_version() {
  init_paths
  echo "WGHELPER ${VERSION}"
  echo "DIR=${WG_DIR}"
  echo "WG=${WG_BIN:-}"
  echo "WGQUICK=${WG_QUICK_BIN:-}"
  if [[ -x "${WG_BIN:-}" && -x "${WG_QUICK_BIN:-}" ]]; then
    echo "TOOLS=ok"
  else
    echo "TOOLS=missing"
  fi
}

cmd_snapshot() {
  init_paths
  echo "WGHELPER_SNAPSHOT ${VERSION}"
  echo "DIR=${WG_DIR}"
  echo "WG=${WG_BIN:-}"
  echo "WGQUICK=${WG_QUICK_BIN:-}"
  if [[ -x "${WG_BIN:-}" && -x "${WG_QUICK_BIN:-}" ]]; then
    echo "TOOLS=ok"
  else
    echo "TOOLS=missing"
  fi

  mkdir -p "$WG_DIR"
  sync_orphan_keys
  local iface live key dump
  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    live="$(real_iface "$iface" || true)"
    [[ -n "$live" ]] || live="-"
    key="$(key_for_iface "$iface" || true)"
    [[ -n "$key" ]] || key="$iface"
    echo "TUNNEL iface=${iface} live=${live} key=${key}"
    printf 'CONF '
    b64_file "${WG_DIR}/${iface}.conf"
    printf 'DUMP '
    dump=""
    if [[ "$live" != "-" && -x "${WG_BIN:-}" ]]; then
      dump="$("$WG_BIN" show "$live" dump 2>/dev/null || true)"
    fi
    b64_text "$dump"
    echo "END"
  done < <(list_wg_ifaces)
}

cmd_up() {
  init_paths
  need_wg
  local iface="$1" live out status
  valid_iface "$iface"
  [[ -f "${WG_DIR}/${iface}.conf" ]] || die "no ${WG_DIR}/${iface}.conf"
  local cleaned
  cleaned="$(drop_empty_peers < "${WG_DIR}/${iface}.conf")"
  printf '%s\n' "$cleaned" > "${WG_DIR}/${iface}.conf"
  chmod 600 "${WG_DIR}/${iface}.conf"
  live="$(real_iface "$iface" || true)"
  if [[ -n "$live" ]] && "$WG_BIN" show "$live" >/dev/null 2>&1; then
    echo "OK"
    return 0
  fi
  set +e
  out="$("$WG_QUICK_BIN" up "$iface" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]] || printf '%s\n' "$out" | grep -qiE 'already exists|already up'; then
    echo "OK"
    return 0
  fi
  printf '%s\n' "$out" >&2
  exit 1
}

cmd_down() {
  init_paths
  need_wg
  local iface="$1" live
  valid_iface "$iface"
  live="$(real_iface "$iface" || true)"
  if [[ -z "$live" ]]; then
    restore_macos_dns "$iface"
    echo "OK"
    return 0
  fi
  "$WG_QUICK_BIN" down "$iface"
  restore_macos_dns "$iface"
  echo "OK"
}

cmd_upsert() {
  init_paths
  need_wg
  local keyname="$1" iface conf priv body
  valid_key "$keyname"
  mkdir -p "$WG_DIR"
  umask 077
  iface="$(iface_for_key "$keyname" || true)"
  if [[ -z "$iface" ]]; then
    iface="$(next_iface)"
  fi
  conf="${WG_DIR}/${iface}.conf"
  body="$(strip_key_comment | drop_empty_peers | sed -e '${/^$/d;}')"
  {
    printf '# Key = %s\n' "$keyname"
    printf '%s\n' "$body"
  } > "$conf"
  chmod 600 "$conf"
  priv="$(priv_from_conf < "$conf")"
  write_key_files "$keyname" "$priv"
  echo "OK"
  echo "IFACE=${iface}"
  echo "KEY=${keyname}"
}

cmd_delete() {
  init_paths
  local target="$1" iface key live f
  if [[ "$target" =~ ^wg[0-9]+$ ]]; then
    iface="$target"
  else
    valid_key "$target"
    iface="$(iface_for_key "$target" || true)"
  fi
  [[ -n "$iface" ]] || die "no tunnel matching: ${target}"
  valid_iface "$iface"
  key="$(key_for_iface "$iface" || true)"
  live="$(real_iface "$iface" || true)"
  if [[ -n "$live" ]]; then
    need_wg
    "$WG_QUICK_BIN" down "$iface" || die "${iface} still up, not deleted"
    restore_macos_dns "$iface"
  fi
  rm -f "${WG_DIR}/${iface}.conf"
  if [[ -n "$key" ]]; then
    for f in \
      "${WG_DIR}/${key}-privatekey" \
      "${WG_DIR}/${key}-publickey" \
      "${WG_DIR}/${key}_private.key" \
      "${WG_DIR}/${key}_public.key"
    do
      rm -f "$f"
    done
  fi
  echo "OK"
}

cmd_genkey() {
  init_paths
  need_wg
  local keyname="$1" priv pub conf iface
  valid_key "$keyname"
  mkdir -p "$WG_DIR"
  umask 077
  if [[ -e "${WG_DIR}/${keyname}-privatekey" || -e "${WG_DIR}/${keyname}-publickey" ]]; then
    die "key already exists: ${keyname}"
  fi
  if [[ -n "$(iface_for_key "$keyname" || true)" ]]; then
    die "key already exists: ${keyname}"
  fi
  iface="$(next_iface)"
  conf="${WG_DIR}/${iface}.conf"
  priv="$("$WG_BIN" genkey)"
  pub="$(printf '%s\n' "$priv" | "$WG_BIN" pubkey)"
  printf '%s\n' "$priv" > "${WG_DIR}/${keyname}-privatekey"
  printf '%s\n' "$pub" > "${WG_DIR}/${keyname}-publickey"
  printf '# Key = %s\n[Interface]\nPrivateKey = %s\n' "$keyname" "$priv" > "$conf"
  chmod 600 "${WG_DIR}/${keyname}-privatekey" "${WG_DIR}/${keyname}-publickey" "$conf"
  echo "OK"
  echo "IFACE=${iface}"
  echo "KEY=${keyname}"
  echo "PUBLIC=${pub}"
}

cmd_exist() {
  init_paths
  need_wg
  local keyname="$1" priv pub derived iface conf
  valid_key "$keyname"
  priv="$(tr -d '[:space:]' < /dev/stdin)"
  pub="$(printf '%s\n' "$priv" | "$WG_BIN" pubkey 2>/dev/null || true)"
  pub="$(printf '%s' "$pub" | tr -d '[:space:]')"
  [[ -n "$priv" ]] || die "missing private key"
  [[ -n "$pub" ]] || die "invalid private key (wg pubkey failed)"
  if [[ -e "${WG_DIR}/${keyname}-privatekey" || -e "${WG_DIR}/${keyname}-publickey" ]]; then
    die "key already exists: ${keyname}"
  fi
  if [[ -n "$(iface_for_key "$keyname" || true)" ]]; then
    die "key already exists: ${keyname}"
  fi
  mkdir -p "$WG_DIR"
  umask 077
  iface="$(next_iface)"
  conf="${WG_DIR}/${iface}.conf"
  printf '%s\n' "$priv" > "${WG_DIR}/${keyname}-privatekey"
  printf '%s\n' "$pub" > "${WG_DIR}/${keyname}-publickey"
  printf '# Key = %s\n[Interface]\nPrivateKey = %s\n' "$keyname" "$priv" > "$conf"
  chmod 600 "${WG_DIR}/${keyname}-privatekey" "${WG_DIR}/${keyname}-publickey" "$conf"
  echo "OK"
  echo "IFACE=${iface}"
  echo "KEY=${keyname}"
  echo "PUBLIC=${pub}"
}

main() {
  case "${1:-}" in
    version) cmd_version ;;
    snapshot) cmd_snapshot ;;
    up)
      [[ $# -eq 2 ]] || die "usage: wghelper up <wgN>"
      cmd_up "$2"
      ;;
    down)
      [[ $# -eq 2 ]] || die "usage: wghelper down <wgN>"
      cmd_down "$2"
      ;;
    upsert)
      [[ $# -eq 2 ]] || die "usage: wghelper upsert <key>"
      cmd_upsert "$2"
      ;;
    delete)
      [[ $# -eq 2 ]] || die "usage: wghelper delete <key|wgN>"
      cmd_delete "$2"
      ;;
    genkey)
      [[ $# -eq 2 ]] || die "usage: wghelper genkey <key>"
      cmd_genkey "$2"
      ;;
    exist)
      [[ $# -eq 2 ]] || die "usage: wghelper exist <key>"
      cmd_exist "$2"
      ;;
    *) die "unknown command: ${1:-}" ;;
  esac
}

main "$@"
