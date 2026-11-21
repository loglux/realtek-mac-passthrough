# How it works

## The idea
Some business laptops publish a *pass-through MAC* through firmware: a MAC address the machine
wants its wired network connection to present, no matter which dock or USB adapter is attached.
This lets network access control / DHCP recognize the laptop however it is docked.

## The three participants
1. **Host firmware (BIOS/UEFI)** — when "MAC Address Pass-Through" is enabled, it publishes the MAC
   into the ACPI **DSDT** table as the entry `_AUXMAC_#AABBCCDDEEFF#`.
2. **ACPI DSDT** — a firmware table the operating system and drivers can read.
3. **Realtek USB NIC driver** — reads that MAC and applies it to the dock's network card.

## Why a generic dock needs this tool
The Realtek driver reads the firmware MAC, but by default applies it only for docks it treats as a
recognized branded vendor dock. A generic dock with the same Realtek chip is left on its own MAC.
The registry values below tell the driver to apply the firmware MAC regardless of dock brand.

## The registry values
Per-adapter key `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-...}\<NNNN>`, type **REG_DWORD**:

| Value | Set to | Meaning |
|---|---|---|
| `EnableManualCloneMAC` | `1` | apply pass-through regardless of the dock's detected brand |
| `AUXMacType`           | `3` | pass-through method selector (enable) |
| `AUXMacSupportVer`     | `1` | protocol version |
| `EnableCloneMAC`       | `1` | enable the clone (already the default) |

The MAC itself always comes from the firmware's DSDT entry — this tool never sets a MAC value.

## End to end
```
BIOS            ->  DSDT: _AUXMAC_#AABBCCDDEEFF#
registry values ->  driver: apply it regardless of dock brand
driver          ->  dock NIC MAC = AABBCCDDEEFF
```

## Notes
- The host must have the firmware feature enabled; without the `_AUXMAC_` entry there is nothing to apply.
- Re-initialize by physically replugging the dock — not by Disable/Enable of the adapter.

## References
- Linux kernel `r8152` driver — host MAC pass-through (`drivers/net/usb/r8152.c`, `vendor_mac_passthru_addr_read`).
- Vendor "MAC Address Pass-Through" firmware feature (Dell / Lenovo / HP documentation).
- Microsoft `GetSystemFirmwareTable` API — reading the ACPI DSDT.
