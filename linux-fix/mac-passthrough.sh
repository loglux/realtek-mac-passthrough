#!/bin/sh
# mac-passthrough.sh - MAC pass-through on Linux for a USB network card (dock or dongle), without changing the card.
#
# The laptop's BIOS publishes its pass-through MAC in the ACPI DSDT (_AUXMAC_#AABBCCDDEEFF#, e.g. Dell
# "MAC Address Pass-Through"). This tool reads it and, for the one card you choose, installs a udev rule:
# every time that card appears, a small helper reads the BIOS MAC again and gives it to the card.
# Turn the feature off in the BIOS and the card keeps its own MAC on the next plug-in. Fully reversible.
#
#   sudo ./mac-passthrough.sh status            what the BIOS publishes, every USB network card, the rule
#   sudo ./mac-passthrough.sh enable <iface>    install the rule for this card (e.g. enx803f5df7929f)
#   sudo ./mac-passthrough.sh disable           remove the rule and give the card its own MAC back
#
# Linux only, after boot (not pre-boot / PXE). Needs: sh, grep, ip (iproute2), udevadm. Run as root.
set -u

RULE=/etc/udev/rules.d/90-mac-passthrough.rules
HELPER=/usr/local/sbin/mac-passthrough-apply
DSDT=/sys/firmware/acpi/tables/DSDT

say()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root (sudo $0 $*)"; }

fmt_mac() { echo "$1" | tr 'A-F' 'a-f' | sed 's/../&:/g; s/:$//'; }

# BIOS: prints the published MAC (aa:bb:..) or nothing; returns 0 = published, 1 = feature present but off, 2 = no feature
bios_mac() {
    [ -r "$DSDT" ] || return 2
    m=$(grep -a -o '_AUXMAC_#[0-9A-Fa-f]\{12\}#' "$DSDT" 2>/dev/null | head -n 1 | sed 's/_AUXMAC_#//; s/#//')
    if [ -n "$m" ]; then fmt_mac "$m"; return 0; fi
    if grep -a -q -e 'AMAC' -e 'MACA' -e '_AUXMAC_' "$DSDT" 2>/dev/null; then return 1; fi
    return 2
}

# USB network interfaces: "iface vendor:product driver mac"
usb_cards() {
    for n in /sys/class/net/*; do
        i=$(basename "$n")
        dev=$(readlink -f "$n/device" 2>/dev/null) || continue
        case "$dev" in *usb*) ;; *) continue ;; esac
        u="$dev"
        while [ "$u" != / ] && [ ! -f "$u/idVendor" ]; do u=$(dirname "$u"); done
        [ -f "$u/idVendor" ] || continue
        drv=$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null)
        printf '%s %s:%s %s %s\n' "$i" "$(cat "$u/idVendor")" "$(cat "$u/idProduct")" "${drv:-?}" "$(cat "$n/address")"
    done
}

rule_mac() { [ -f "$RULE" ] && sed -n 's/.*ATTR{address}=="\([0-9a-f:]*\)".*/\1/p' "$RULE" | head -n 1; }

cmd_status() {
    say "LAPTOP (BIOS, ACPI DSDT)"
    bm=$(bios_mac); rc=$?
    case $rc in
        0) say "  publishes its MAC     $bm" ;;
        1) say "  pass-through present, but turned OFF - switch on 'MAC Address Pass-Through' in BIOS setup" ;;
        *) [ -r "$DSDT" ] && say "  no pass-through feature in this BIOS" || say "  cannot read $DSDT (run as root)" ;;
    esac
    say ""
    say "USB NETWORK CARDS"
    own=$(rule_mac)
    cards=$(usb_cards)
    if [ -z "$cards" ]; then say "  none found - plug in the dock or dongle"; fi
    echo "$cards" | while read -r i id drv mac; do
        [ -n "$i" ] || continue
        st="its own MAC"
        [ -n "$bm" ] && [ "$mac" = "$bm" ] && st="HAS THE LAPTOP'S MAC"
        tag=""
        if [ -n "$own" ] && { [ "$mac" = "$own" ] || { [ -n "$bm" ] && [ "$mac" = "$bm" ]; }; }; then tag="  [the rule's card]"; fi
        say "  $i   $id   driver $drv   MAC $mac   - $st$tag"
    done
    say ""
    say "THE RULE"
    if [ -f "$RULE" ]; then
        say "  installed for the card whose own MAC is $own  ($RULE)"
    else
        say "  not installed"
    fi
    if command -v dmesg >/dev/null 2>&1 && dmesg 2>/dev/null | grep -q 'Using pass-thru MAC addr'; then
        say ""
        say "NOTE: the r8152 driver itself applied pass-through on this boot (dmesg) - that card needs no rule."
    fi
}

cmd_enable() {
    need_root "$@"
    i=${1:-}; [ -n "$i" ] || die "which card? e.g.: $0 enable enx803f5df7929f   (see: $0 status)"
    [ -e "/sys/class/net/$i" ] || die "no network interface '$i'"
    usb_cards | grep -q "^$i " || die "'$i' is not a USB network card"
    bm=$(bios_mac); rc=$?
    [ $rc = 0 ] || { [ $rc = 1 ] && die "the BIOS has pass-through but it is turned off - switch it on in BIOS setup first"; die "this BIOS publishes no pass-through MAC - nothing to give the card"; }
    if [ -f "$RULE" ]; then die "a rule is already installed (for $(rule_mac)) - run '$0 disable' first"; fi
    cur=$(cat "/sys/class/net/$i/address")
    perm=$(ethtool -P "$i" 2>/dev/null | sed -n 's/.*: //p')
    own=${perm:-$cur}
    [ "$own" = "00:00:00:00:00:00" ] && own=$cur
    [ "$own" = "$bm" ] && die "cannot tell this card's own MAC (it already shows the laptop's) - unplug it, plug it back, try again"

    cat > "$HELPER" <<'EOF'
#!/bin/sh
# mac-passthrough-apply <iface> - give the card the MAC the laptop's BIOS publishes right now (called by udev)
m=$(grep -a -o '_AUXMAC_#[0-9A-Fa-f]\{12\}#' /sys/firmware/acpi/tables/DSDT 2>/dev/null | head -n 1 | sed 's/_AUXMAC_#//; s/#//')
[ -n "$m" ] || exit 0
mac=$(echo "$m" | tr 'A-F' 'a-f' | sed 's/../&:/g; s/:$//')
ip link set dev "$1" address "$mac" && logger -t mac-passthrough "$1: pass-through MAC $mac from the BIOS"
EOF
    chmod 755 "$HELPER"
    printf '# mac-passthrough.sh: give this card (own MAC %s) the laptop BIOS pass-through MAC on every plug-in\nACTION=="add", SUBSYSTEM=="net", ATTR{address}=="%s", RUN+="%s %%k"\n' "$own" "$own" "$HELPER" > "$RULE"
    udevadm control --reload
    say "Rule installed for $i (own MAC $own)."
    if ip link set dev "$i" address "$bm" 2>/dev/null; then
        say "Applied now: $i -> $bm  (from the BIOS)."
    else
        say "Could not change the MAC while the card is up - unplug it and plug it back in."
    fi
    say "Undo with: sudo $0 disable"
}

cmd_disable() {
    need_root "$@"
    [ -f "$RULE" ] || { say "No rule installed - nothing to remove."; exit 0; }
    own=$(rule_mac)
    rm -f "$RULE" "$HELPER"
    udevadm control --reload
    say "Rule removed."
    bm=$(bios_mac)
    for n in /sys/class/net/*; do
        i=$(basename "$n")
        if [ -n "$bm" ] && [ "$(cat "$n/address")" = "$bm" ] && usb_cards | grep -q "^$i "; then
            if ip link set dev "$i" address "$own" 2>/dev/null; then
                say "Gave $i its own MAC back: $own"
            else
                say "Unplug $i and plug it back in to get its own MAC ($own) back."
            fi
        fi
    done
}

case "${1:-status}" in
    status)  cmd_status ;;
    enable)  shift; cmd_enable "$@" ;;
    disable) shift; cmd_disable "$@" ;;
    -h|--help|help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command '$1' - use status, enable <iface> or disable" ;;
esac
