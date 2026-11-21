# How MAC Address Pass-Through Works — and why a dock can support one OS but not another

MAC Address Pass-Through looks like a single on/off feature. It isn't. Whether a dock "supports"
it depends on **three parties agreeing**, and — the part that trips everyone up — **each operating
system checks a *different* thing on the card.** That's why the very same dock can pass the MAC
through on Windows but not on Linux, or the other way around.

This page explains the mechanism end to end, so the behaviour stops being mysterious.

---

## Two sides have to agree

Pass-through only happens when **both** of these are true:

1. **The laptop (host) offers its MAC.** Business laptops with the BIOS option enabled publish the
   MAC in an ACPI value named `_AUXMAC_` — Dell exposes it as `\_SB.AMAC`, Lenovo as `\MACA`. No
   BIOS option, no offered MAC, nothing to pass through.
2. **The dock's chip is allowed to take it.** The Realtek USB NIC must be *marked* as pass-through
   capable. Without the mark, the driver reads the host's MAC and simply ignores it.

Side 1 is the laptop's job. **This page is about side 2 — the card — because that's where docks
differ, and where "supported / not supported" is actually decided.**

---

## The card-side switch lives in one byte: `0xCFDB`

At power-on the Realtek chip loads a capability byte, register `0xCFDB`, from its internal memory.
Two bits matter:

- **AUX-clone** — the standard `_AUXMAC_` pass-through used by Dell / Lenovo / HP.
- **RT-clone** — a separate Realtek-only clone mode that does *not* drive `_AUXMAC_` pass-through.

So far, so simple. The twist is what *reads* that byte.

---

## The twist: each layer checks a different thing

### Windows (Realtek driver)

The Windows Realtek driver is **generic**. It reads `0xCFDB`, folds it into an internal value it
calls `AUXMacType`, and clones the host's `_AUXMAC_` MAC whenever the **AUX-clone** bit is set. It
does **not** care what *variant* of Realtek chip it is — only that the AUX bit is on.

The same driver also reads a few **per-adapter registry values** — `EnableCloneMAC`,
`EnableManualCloneMAC`, `AUXMacType`, `AUXMacSupportVer` — that can *force* this from the software
side, even when the chip's bit is off. It works, but it's a Windows-only, local override: those
values live in the registry under **that one adapter instance**, so they don't travel with the
card, don't survive a move to another machine or a clean install, and do nothing at pre-boot or on
Linux. Setting the bit in the chip itself (what RtlPassthru does) is the opposite — it rides along
with the card, and every layer honours it.

### Pre-boot / PXE (laptop firmware, before any OS)

Same requirement, one layer lower: the laptop firmware programs the MAC into the card during
network boot, and the card honours it **if the AUX-clone bit is set.** This is what makes
pass-through useful for imaging and deployment — the machine already has its real identity before
an OS loads.

### Linux (`r8152` driver) — the different one

Linux does **not** trust the `0xCFDB` bit on its own. It first asks **"what *kind* of chip is
this?"** — and only certain factory chip variants are allowed through. From the mainline kernel
(`drivers/net/usb/r8152.c`, `vendor_mac_passthru_addr_read`):

```c
if (tp->lenovo_macpassthru) {                 /* a Lenovo-specific chip   */
        ...                                   /* -> read \MACA            */
} else if ((USB_MISC_0 & AD_MASK) == 0x1000) {/* an RTL8153-AD variant?   */
        if ((EFUSE & PASS_THRU_MASK) != 1)    /* ...then the efuse bit too */
                return -ENODEV;
} else if (!(USB_MISC_1 & (BND_MASK | BD_MASK))) { /* -BND / -BD variant?  */
        return -ENODEV;                       /* none of the above -> no  */
}
/* passed the gate -> read the host MAC from \_SB.AMAC and apply it */
```

Read that carefully, because it's the crux:

- Linux keys on the **chip variant marker**, which lives in a *different* register (`USB_MISC_0` /
  `USB_MISC_1`), not in `0xCFDB`.
- The `0xCFDB` bit is checked **only inside the `-AD` branch**, *after* the variant marker has
  already matched.
- A chip that is **not** a recognised variant (`-AD`, `-BND`, `-BD`, or a Lenovo chip) is rejected
  **even if its `0xCFDB` bit is set.** The driver never gets far enough to look at it.

---

## Why the same feature gives opposite results on different cards

Put the two halves together and the "supported on one OS, not the other" puzzle dissolves. It comes
down to **two independent things**: the **variant marker** (what Linux checks) and the **AUX bit in
`0xCFDB`** (what Windows / PXE check).

| card | chip variant | `0xCFDB` AUX bit | Windows / PXE | Linux |
|---|:---:|:---:|:---:|:---:|
| **A** — an `-AD` chip, AUX bit off | **-AD** ✓ | ✗ | **no** (no AUX bit) | **yes** (variant ✓ + efuse bit) |
| **B** — a generic chip, AUX bit on | none | ✓ | **yes** (AUX bit) | **no** (no recognised variant) |

- **Card A** carries the factory `-AD` marker, so Linux is happy — but its AUX bit is off, so Windows
  and PXE refuse it.
- **Card B** has the AUX bit on, so Windows and PXE are happy — but it's a plain chip with no
  variant marker, so Linux refuses it.

Same feature, mirror-image results. Neither card is "broken"; they simply satisfy *different*
gates. (A chip that has **both** — a recognised variant *and* the AUX bit — works everywhere.)

---

## Chip variants: `-AD`, `-BND`, `-BD`, Lenovo

The variants Linux looks for are **physical factory SKUs of the Realtek chip**, not settings:

- **RTL8153-AD** — the original Dell-oriented variant; gated by the efuse bit as well.
- **RTL8153-BND / -BD** — later variants that activate pass-through on the marker alone, without an
  efuse bit.
- **Lenovo chips** — recognised by their USB vendor ID.

The marker sits in the silicon (the `USB_MISC` registers), set when the chip is manufactured. A
generic, unbranded Realtek NIC is usually **none** of these — which is exactly why it can work on
Windows yet be turned away by Linux.

---

## What this means in practice

- **Windows is the easy case.** Any Realtek chip with the AUX bit set will pass the MAC through.
- **Pre-boot / PXE** follows the same rule, below the OS — which is the valuable part for network
  boot and imaging.
- **Linux is the strict case.** It wants a recognised chip *variant* first. If your dongle is a
  generic chip, Linux may refuse it even when Windows is perfectly happy.
- Setting the AUX bit (what a tool can do to the chip) covers **Windows and PXE universally, and
  Linux too when the chip is already a recognised variant.** It cannot *invent* a factory variant
  marker — that's baked into the silicon.

Once you see pass-through as **two separate conditions checked by three different layers**, the
"why does it work here but not there?" questions answer themselves.
