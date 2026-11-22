# Linux: MAC pass-through without changing the card

> **Not yet tested on hardware.** Written for the same setup as [Registry Fix](../registry-fix/README.md),
> but no run on a real laptop yet. Feedback welcome.

On Linux the `r8152` driver takes the laptop's MAC only for chips it recognises (the *-AD*, *-BND* or *-BD*
variants; see the main README). For any other USB network card — Realtek or not — this script does the same
job from outside the driver:

- it reads the **laptop's ACPI table** (`/sys/firmware/acpi/tables/DSDT`) and finds the pass-through MAC the
  BIOS publishes (`_AUXMAC_`, e.g. Dell *MAC Address Pass-Through*) — or tells you the feature is turned off
  in the BIOS, or missing;
- for **the one card you choose** it installs a `udev` rule: every time that card appears, a small helper
  reads the BIOS MAC again and gives it to the card. Turn the feature off in the BIOS and the card keeps its
  own MAC on the next plug-in;
- `disable` removes the rule and gives the card its own MAC back.

```sh
sudo ./mac-passthrough.sh status                  # BIOS, every USB network card, the rule
sudo ./mac-passthrough.sh enable enx803f5df7929f  # install the rule for this card
sudo ./mac-passthrough.sh disable                 # remove it
```

It installs two files: `/etc/udev/rules.d/90-mac-passthrough.rules` (matched on the card's own MAC, so a
second card never gets the same address) and `/usr/local/sbin/mac-passthrough-apply`.

**Good to know**
- After boot only — before Linux starts (pre-boot / PXE) the card decides by itself.
- If the card already takes the laptop's MAC (`dmesg` shows *Using pass-thru MAC addr*), it needs no rule.
- A network manager set to a *random* or *stable* cloned MAC for this connection overrides it; the default
  (*preserve*) keeps the address the rule set.

⚠️ No warranty: use at your own risk. The change is two files and fully reversible.
