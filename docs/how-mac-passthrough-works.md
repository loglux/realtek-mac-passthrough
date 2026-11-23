# How MAC Address Pass-Through Works — and why a dock can work on one OS but not another

MAC Address Pass-Through looks like a single on/off feature. It isn't. Whether a dock "supports" it
depends on **two sides agreeing** — and the part that trips everyone up is that **different operating
systems check different values in the dock's chip.** That is why the very same dock can pass the
laptop's MAC through on Windows but not on Linux, or the other way around.

This page explains the mechanism end to end.

---

## Two sides have to agree

Pass-through only happens when **both** of these are true:

1. **The laptop offers its MAC.** Business laptops with the BIOS option enabled publish the laptop's
   own MAC through ACPI as a string `_AUXMAC_#AABBCCDDEEFF#` — Dell in the object `\_SB.AMAC`, Lenovo
   in `\MACA`. No BIOS option, no offered MAC, nothing to pass through.
2. **The driver accepts it for this dock.** The driver reads a few values from the dock's Realtek
   chip and decides from them whether to use the offered MAC. If the check fails, it ignores the MAC.

Side 1 is the laptop's job. **This page is about side 2 — because that is where docks differ.**

---

## What the drivers read from the chip

The chip holds only **numbers in its registers**; the drivers read them over USB. The names in the
third column are what the drivers call those values — nothing is written in the chip.

| Register | Bits checked | Value that counts | Known as |
|---|---|---|---|
| `0xCFDB` (1 byte) | bit 1 | 1 | **AUX MAC clone** *(Windows driver)* |
| `0xCFDB` (1 byte) | bit 0 | 1 | **RT MAC clone** *(Windows driver)*, `PASS_THRU` *(Linux driver)* |
| `USB_MISC_0` (`0xD81A`, 16 bit) | bits 15–9 and 7–5 (mask `0xFEE0`) | `0x1000`: bit 12 = 1, the rest 0 | **RTL8153-AD** *(Linux driver)* |
| `USB_MISC_1` (`0xD81F`, 1 byte) | bit 2 / bit 0 | 1 | **RTL8153-BND** / **RTL8153-BD** *(Linux driver)* |

`0xCFDB` is one byte — eight bits, each either 0 or 1; only the two lowest matter here:

| Bit | 7 | 6 | 5 | 4 | 3 | 2 | **1** | **0** |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| Hex value | `0x80` | `0x40` | `0x20` | `0x10` | `0x08` | `0x04` | **`0x02`** | **`0x01`** |
| Windows driver | — | — | — | — | — | — | AUX MAC clone | RT MAC clone |
| Linux driver | — | — | — | — | — | — | — | `PASS_THRU` |
| **Required value** | — | — | — | — | — | — | **1** | **1** |

Bit 1 is what Windows and pre-boot need, bit 0 what Linux needs on `-AD` chips; the other bits are
not checked. RtlPassthru sets both — `0x03`.

Where the values come from:

- **`0xCFDB`** is filled at every power-on: first with the chip's built-in default, then with any
  setting records stored in the chip's efuse (one-time-programmable memory), which overwrite it.
  That is why it can be changed by burning a record into the efuse — what RtlPassthru does
  (`0xCFDB = 0x03`, both bits).
- **`USB_MISC_0` / `USB_MISC_1`** come from the chip itself at the factory — and, like `0xCFDB`, an
  efuse record can set them on top at power-on. On a plain RTL8153 RtlPassthru burns one such record,
  `USB_MISC_0 = 0x1000` (the *-AD* marker), to enable Linux.

Where the names come from:

- **Windows driver** (`rtump64x64`, function `NIC_QuerySpecificHwCaps`) reads `0xCFDB` and logs
  *"Is RT MAC clone support system"* when bit 0 is set and *"Is AUX MAC clone support system"* when
  bit 1 is set.
- **Realtek's configuration tool** names the bits per chip generation (see the table in the
  README). On an RTL8156 bit 1 is `AUX_MAC_CLONE` and bit 0 is `MAC_CLONE`; on the earliest chips
  the same places hold `SELF_POWER` and `DOCKING`. (Realtek's diagnostic DLLs contain none of these
  names; they only read and write registers by number.)
- **Linux driver** ([`drivers/net/usb/r8152.c`](https://github.com/torvalds/linux/blob/master/drivers/net/usb/r8152.c))
  defines `EFUSE 0xcfdb` and `PASS_THRU_MASK 0x1`, and `AD_MASK 0xfee0`, `BND_MASK 0x0004`,
  `BD_MASK 0x0001` for the `USB_MISC` checks; its comments name the variants `RTL8153-AD`,
  `RTL8153-BND` and `RTL8153-BD`.

---

## How each system decides

### Windows (Realtek driver)

The Windows driver reads `0xCFDB` and builds an internal value, `AUXMacType`: bit 0 of `0xCFDB` adds
2, bit 1 adds 1. It applies pass-through when `AUXMacType & 1` — that is, **when bit 1 (AUX MAC clone)
is set.** It does not look at the `USB_MISC` values, so any Realtek chip with bit 1 set will do.

The same driver can also be *forced* in software, through a few **per-adapter registry values** —
`EnableCloneMAC`, `EnableManualCloneMAC`, `AUXMacType`, `AUXMacSupportVer` — which switch
pass-through on even when bit 1 is off. This works, but it is a **Windows-only, local override**:
those values sit in the registry under **one adapter instance**, so they do **not** travel with the
card, do **not** survive a move to another machine or a clean install, and do nothing at pre-boot or
on Linux. Burning bit 1 into the chip itself (what RtlPassthru does) travels with the card.

### Pre-boot / PXE (laptop firmware, before any OS)

During network boot the laptop's own firmware drives the card. We tested it on a Dell with BIOS
*MAC Address Pass-Through* enabled: a dock whose `0xCFDB` read `0x01` (bit 0 only) came up under its
own MAC; after we burned `0x03` (both bits) it came up under the laptop's MAC. So pre-boot needs
bit 1, like Windows. This is the valuable part for imaging and deployment — the machine carries its
real identity before any OS loads.

### Linux (`r8152` driver)

Linux checks the chip variant first. From `vendor_mac_passthru_addr_read()` in the mainline kernel
(excerpt, unchanged):

```c
	if (tp->lenovo_macpassthru) {
		mac_obj_name = "\\MACA";
		mac_obj_type = ACPI_TYPE_STRING;
		mac_strlen = 0x16;
	} else {
		/* test for -AD variant of RTL8153 */
		ocp_data = ocp_read_word(tp, MCU_TYPE_USB, USB_MISC_0);
		if ((ocp_data & AD_MASK) == 0x1000) {
			/* test for MAC address pass-through bit */
			ocp_data = ocp_read_byte(tp, MCU_TYPE_USB, EFUSE);
			if ((ocp_data & PASS_THRU_MASK) != 1) {
				netif_dbg(tp, probe, tp->netdev,
						"No efuse for RTL8153-AD MAC pass through\n");
				return -ENODEV;
			}
		} else {
			/* test for RTL8153-BND and RTL8153-BD */
			ocp_data = ocp_read_byte(tp, MCU_TYPE_USB, USB_MISC_1);
			if ((ocp_data & BND_MASK) == 0 && (ocp_data & BD_MASK) == 0) {
				netif_dbg(tp, probe, tp->netdev,
						"Invalid variant for MAC pass through\n");
				return -ENODEV;
			}
		}

		mac_obj_name = "\\_SB.AMAC";
		mac_obj_type = ACPI_TYPE_BUFFER;
		mac_strlen = 0x17;
	}
```

In plain words:

- **Lenovo devices** (`tp->lenovo_macpassthru`, set from the device's USB vendor ID) skip the chip
  checks and read Lenovo's `\MACA`.
- Otherwise, if `USB_MISC_0 & 0xFEE0 == 0x1000` (the driver's *-AD variant*), it also needs **bit 0
  of `0xCFDB`** (`PASS_THRU`).
- Otherwise it needs **bit 2 or bit 0 of `USB_MISC_1`** (the driver's *-BND / -BD variants*). If
  neither is set it gives up — whatever `0xCFDB` says.
- **Linux never looks at bit 1 of `0xCFDB`** — the bit Windows and pre-boot need.

---

## Side by side

| Register | Bits checked | Value that counts | Windows | Pre-boot / PXE | Linux |
|---|---|---|:---:|:---:|:---:|
| `0xCFDB` | bit 1 *(AUX MAC clone)* | 1 | required | required | not used |
| `0xCFDB` | bit 0 *(RT MAC clone / `PASS_THRU`)* | 1 | not used | not enough alone | required if the `-AD` test matches |
| `USB_MISC_0` | mask `0xFEE0` *(-AD)* | `0x1000` | not used | not used | this, **or** … |
| `USB_MISC_1` | bit 2 / bit 0 *(-BND / -BD)* | either = 1 | not used | not used | … this |

*Not enough alone*: `0x01` (bit 0 only) did not give pass-through at pre-boot; `0x03` did.
Lenovo devices on Linux skip the chip checks (see above).

So:

- **Bit 1 set, chip not an `-AD` / `-BND` / `-BD` variant** → Windows and pre-boot: yes. Linux: no.
- **Variant matches, bit 1 not set** (on an `-AD` chip, with bit 0 set) → Linux: yes. Windows and
  pre-boot: no.
- **Both** → works everywhere.

---

## What this means in practice

- **Windows and pre-boot** need bit 1 of `0xCFDB` on any Realtek chip. That is what RtlPassthru
  burns (it writes `0x03`, so bit 0 is set too).
- **Linux** needs the `USB_MISC` values to match one of its variants, and on an `-AD` match also
  bit 0. On a plain RTL8153 that already has bit 0, RtlPassthru burns the *-AD* marker
  (`USB_MISC_0 = 0x1000`).

Confirmed on hardware: our RTL8156 reads `USB_MISC_0 = 0x1000`, so Linux's *-AD* test matches it;
after burning `0xCFDB = 0x03` it took the laptop's MAC in Windows, at Dell pre-boot and on Ubuntu
(`r8152 … Using pass-thru MAC addr`). An RTL8153 adapter with `USB_MISC_0 = 0x0000` and no BND/BD bit
kept its own MAC on Ubuntu, exactly as the code above says. An RTL8153E dongle in the same state took
the laptop's MAC on Ubuntu once the *-AD* marker was burned into its efuse: after a re-plug its
`USB_MISC_0` read `0x1000`, and `r8152` logged *"Using pass-thru MAC addr"*.
