#!/bin/bash
# Template for the host table wake-lab.sh sources. Copy it to ~/.config/wake-lab/hosts.sh (or
# anywhere WAKE_LAB_HOSTS points), fill in the real values, and keep that copy out of git:
#
#   mkdir -p ~/.config/wake-lab
#   cp scripts/wake-lab-hosts.example.sh ~/.config/wake-lab/hosts.sh
#   chmod 600 ~/.config/wake-lab/hosts.sh && $EDITOR ~/.config/wake-lab/hosts.sh
#
# This is the only part of the lab's wiring that is site data rather than reviewable logic: the
# fleet's MAC addresses and LAN IPs. Everything else — the lore, the router endpoints, the ssh
# aliases, the logic — is tracked in ludics-lite, so an in-place edit shows up in `git status`
# (ludics-lite#31). The MACs below are 00:00:00 placeholders on purpose; a real one in this file
# is a leak, and scripts/test-wake-lab.sh fails the repository if one appears. The IPs are
# likewise fictitious, from RFC 5737's documentation range (192.0.2.0/24) rather than from any
# real LAN: a template carrying the author's leases would be site data by another name.
#
# The box names must be the ones the script knows: rog, minix, asus (lan_of/ts_of/wsl_of in
# wake-lab.sh are the tracked half of the same table). Each function echoes the value(s) for a
# known box and returns 1 for anything else; wake-lab.sh refuses to run unless all three exist.
# Sourced by a `set -u` script under bash 3.2: no associative arrays.

# Every MAC of a box, Wi-Fi and Ethernet. wake() sends a magic packet to each — the Wi-Fi ones
# never wake anything (see the lore in wake-lab.sh) but cost nothing and keep this table readable
# against the router's own host list. A Wi-Fi-only box gets one entry and can never be woken.
mac_of() { case "$1" in
  rog)   echo 00:00:00:00:00:01 00:00:00:00:00:02 ;;  # Wi-Fi, Ethernet
  minix) echo 00:00:00:00:00:03 00:00:00:00:00:04 ;;  # Wi-Fi, Ethernet
  asus)  echo 00:00:00:00:00:05 ;;                    # Wi-Fi only
  *) return 1 ;; esac; }

# The Ethernet MAC alone — the one whose link state actually means something. link_active() asks
# the router about this MAC, and `status` prints the answer as eth-link. A box with no cabled NIC
# belongs in neither branch: returning 1 is what makes its link read `?`.
eth_mac_of() { case "$1" in
  rog)   echo 00:00:00:00:00:02 ;;
  minix) echo 00:00:00:00:00:04 ;;
  *) return 1 ;; esac; }

# The LAN IP of each box's cabled NIC. Nothing in wake-lab.sh calls this today — the -lan ssh
# aliases resolve these through ~/.ssh/config — but it is the record of which lease is the live
# one, which is exactly the question a stale Wi-Fi lease makes hard to answer.
ip_of() { case "$1" in
  rog)   echo 192.0.2.30 ;;  # Ethernet; its Wi-Fi lease is a different address
  minix) echo 192.0.2.31 ;;  # Ethernet
  asus)  echo 192.0.2.29 ;;  # Wi-Fi
  *) return 1 ;; esac; }
