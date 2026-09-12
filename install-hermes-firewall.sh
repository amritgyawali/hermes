#!/usr/bin/env bash
set -euo pipefail

PERSISTENT_RULES="/etc/iptables/rules.v4"
COMMENT="Hermes dashboard from Caddy edge bridge only"
RULE_TEXT="-A INPUT -s 172.18.0.0/16 -d 172.18.0.1/32 -p tcp -m tcp --dport 9119 -m conntrack --ctstate NEW -m comment --comment \"$COMMENT\" -j ACCEPT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

test -f "$PERSISTENT_RULES"
cp "$PERSISTENT_RULES" "$PERSISTENT_RULES.pre-hermes-$STAMP"

if ! grep -Fq "$COMMENT" "$PERSISTENT_RULES"; then
  sed -i "/^-A INPUT -j REJECT --reject-with icmp-host-prohibited$/i $RULE_TEXT" "$PERSISTENT_RULES"
fi

iptables-restore --test < "$PERSISTENT_RULES"

if ! iptables -C INPUT -s 172.18.0.0/16 -d 172.18.0.1/32 -p tcp --dport 9119 \
  -m conntrack --ctstate NEW -m comment --comment "$COMMENT" -j ACCEPT 2>/dev/null; then
  iptables -I INPUT 7 -s 172.18.0.0/16 -d 172.18.0.1/32 -p tcp --dport 9119 \
    -m conntrack --ctstate NEW -m comment --comment "$COMMENT" -j ACCEPT
fi

echo "Hermes bridge-only firewall rule installed and persisted."
