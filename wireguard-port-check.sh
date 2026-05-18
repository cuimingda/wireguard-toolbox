#!/usr/bin/env bash

set -u

SERVER_CONFIG_FILE="/etc/wireguard/wg0.conf"
CLIENT_CONFIG_FILE="/root/wg0-client.conf"

FAILURES=()
PORT_ENTRIES=()

add_failure() {
  FAILURES+=("$*")
}

add_port_entry() {
  local role="$1"
  local file="$2"
  local line_no="$3"
  local field="$4"
  local port="$5"

  PORT_ENTRIES+=("${role}|${file}|${line_no}|${field}|${port}")
}

check_readable_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    add_failure "config file not found: $file"
    return 1
  fi

  if [[ ! -r "$file" ]]; then
    add_failure "config file is not readable: $file"
    return 1
  fi

  return 0
}

collect_ports_from_file() {
  local role="$1"
  local file="$2"
  local line
  local line_no=0
  local matched
  local port
  local remaining

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_no++))

    if [[ "$line" =~ ^[[:space:]]*ListenPort[[:space:]]*= ]]; then
      if [[ "$line" =~ ^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
        add_port_entry "$role" "$file" "$line_no" "ListenPort" "${BASH_REMATCH[1]}"
      else
        add_failure "invalid ListenPort at $file:$line_no"
      fi
    fi

    if [[ "$line" =~ ^[[:space:]]*Endpoint[[:space:]]*= ]]; then
      if [[ "$line" =~ ^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*.+:([0-9]+)[[:space:]]*$ ]]; then
        add_port_entry "$role" "$file" "$line_no" "Endpoint" "${BASH_REMATCH[1]}"
      else
        add_failure "invalid Endpoint port at $file:$line_no"
      fi
    fi

    remaining="$line"
    while [[ "$remaining" =~ --dport[[:space:]]+([0-9]+) ]]; do
      matched="${BASH_REMATCH[0]}"
      port="${BASH_REMATCH[1]}"
      add_port_entry "$role" "$file" "$line_no" "--dport" "$port"
      remaining="${remaining#*"$matched"}"
    done
    if [[ "$remaining" =~ --dport ]]; then
      add_failure "invalid --dport at $file:$line_no"
    fi

    remaining="$line"
    while [[ "$remaining" =~ --add-port(=|[[:space:]]+)([0-9]+)/udp ]]; do
      matched="${BASH_REMATCH[0]}"
      port="${BASH_REMATCH[2]}"
      add_port_entry "$role" "$file" "$line_no" "--add-port" "$port"
      remaining="${remaining#*"$matched"}"
    done
    if [[ "$remaining" =~ --add-port ]]; then
      add_failure "invalid --add-port at $file:$line_no"
    fi

    remaining="$line"
    while [[ "$remaining" =~ --remove-port(=|[[:space:]]+)([0-9]+)/udp ]]; do
      matched="${BASH_REMATCH[0]}"
      port="${BASH_REMATCH[2]}"
      add_port_entry "$role" "$file" "$line_no" "--remove-port" "$port"
      remaining="${remaining#*"$matched"}"
    done
    if [[ "$remaining" =~ --remove-port ]]; then
      add_failure "invalid --remove-port at $file:$line_no"
    fi
  done <"$file"
}

first_port_for() {
  local role="$1"
  local field="$2"
  local entry
  local entry_role
  local entry_file
  local entry_line
  local entry_field
  local entry_port

  for entry in "${PORT_ENTRIES[@]}"; do
    IFS='|' read -r entry_role entry_file entry_line entry_field entry_port <<<"$entry"
    if [[ "$entry_role" == "$role" && "$entry_field" == "$field" ]]; then
      echo "$entry_port"
      return 0
    fi
  done

  return 1
}

has_port_for() {
  local role="$1"
  local field="$2"

  first_port_for "$role" "$field" >/dev/null
}

check_ports_match() {
  local baseline_port="$1"
  local entry
  local role
  local file
  local line_no
  local field
  local port

  for entry in "${PORT_ENTRIES[@]}"; do
    IFS='|' read -r role file line_no field port <<<"$entry"
    if [[ "$port" != "$baseline_port" ]]; then
      add_failure "$file:$line_no $field port $port does not match ListenPort $baseline_port"
    fi
  done
}

print_port_entries() {
  local entry
  local role
  local file
  local line_no
  local field
  local port

  echo "Parsed port settings:"
  if [[ ${#PORT_ENTRIES[@]} -eq 0 ]]; then
    echo "  - none"
    return
  fi

  for entry in "${PORT_ENTRIES[@]}"; do
    IFS='|' read -r role file line_no field port <<<"$entry"
    echo "  - ${role}: ${file}:${line_no} ${field}=${port}"
  done
}

print_failures() {
  local failure

  echo "Failures:"
  for failure in "${FAILURES[@]}"; do
    echo "  - $failure"
  done
}

audit_wireguard_ports() {
  local server_file="${1:-$SERVER_CONFIG_FILE}"
  local client_file="${2:-$CLIENT_CONFIG_FILE}"
  local baseline_port=""

  FAILURES=()
  PORT_ENTRIES=()

  if check_readable_file "$server_file"; then
    collect_ports_from_file "server" "$server_file"
  fi

  if check_readable_file "$client_file"; then
    collect_ports_from_file "client" "$client_file"
  fi

  baseline_port=$(first_port_for "server" "ListenPort" || true)
  if [[ -z "$baseline_port" ]]; then
    add_failure "missing server ListenPort in $server_file"
  fi

  if ! has_port_for "client" "Endpoint"; then
    add_failure "missing client Endpoint port in $client_file"
  fi

  if [[ -n "$baseline_port" ]]; then
    check_ports_match "$baseline_port"
  fi

  if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo "WireGuard port audit failed."
    print_port_entries
    print_failures
    return 1
  fi

  echo "WireGuard port audit passed. Port: $baseline_port"
  print_port_entries
  return 0
}

main() {
  audit_wireguard_ports "$SERVER_CONFIG_FILE" "$CLIENT_CONFIG_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
