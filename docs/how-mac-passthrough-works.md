# How MAC Address Pass-Through Works — and why a dock can support one OS but not another

MAC Address Pass-Through looks like a single on/off feature. It isn't. Whether a dock "supports"
it depends on **two sides agreeing** — and the part that trips everyone up is that **different
operating systems check a *different* marker on the card.** That is why the very same dock can pass
the MAC through on Windows but not on Linux, or the other way around.

This page explains the mechanism end to end, so the behaviour stops being mysterious.

---

## Two sides have to agree

Pass-through only happens when **both** of these are true:

1. **The laptop (host) offers its MAC.** Business laptops with the BIOS option enabled publish the
   laptop's own MAC in an ACPI value named `_AUXMAC_` — Dell exposes it as `\_SB.AMAC`, Lenovo as
   `\MACA`. No BIOS option, no offered MAC, nothing to pass through.
2. **The dock's card is allowed to take it.** The dock's Realtek USB NIC must be *marked* as
   pass-through capable. Without the mark, the driver reads the offered MAC and simply ignores it.

Side 1 is the laptop's job. **This page is about side 2 — the card — because that is where docks
differ, and where "supported / not supported" is actually decided.**

---

## The card's markers

A Realtek USB NIC carries two separate markers that matter here. They live in *different* places on
the chip, and — this is the crux — *different* layers look at *different* ones.

**Marker 1 — the capability byte, register `0xCFDB`.**
At power-on the chip loads a capability byte, register `0xCFDB`, from its internal memory. Two bits
in it matter:

- **bit 1, AUX MAC clone** — it drives standard `_AUXMAC_` pass-through on Windows and at pre-boot.
- **bit 0, RT MAC clone** (Linux calls it `PASS_THRU`) — Windows and pre-boot don't rely on it, but
  Linux checks it on `-AD` chips (see below).

The names are Realtek's and the drivers' own: the Windows Realtek driver (`rtump64x64`,
`NIC_QuerySpecificHwCaps`) logs *"Is RT MAC clone support system"* for bit 0 and *"Is AUX MAC clone
support system"* for bit 1; Realtek's programming tool (RTUNicPG) calls the same bits `DOCKING` and
`SELF_POWER`; the Linux driver defines bit 0 as `PASS_THRU_MASK`.

These bits are settings: they can be burned into the chip's efuse, which is exactly what the
companion tool, RtlPassthru, does (it writes `0x03`, both bits).

**Marker 2 — the chip variant, in the `USB_MISC` registers.**
Separately, the chip records *which factory variant* it is — `RTL8153-AD`, `-BND`, `-BD`, or a
Lenovo chip. This marker lives in the `USB_MISC` registers, which are **not** `0xCFDB`. It is set at
the factory; RtlPassthru does not change it.

Keep these two apart. The next section is entirely about which layer reads which one.

---

## Each layer checks a different marker

### Windows (Realtek driver)

The Windows Realtek driver is **generic**. It reads `0xCFDB`, derives an internal value it calls
`AUXMacType`, and applies pass-through whenever the **AUX bit** is set. It does **not** care what
*variant* of Realtek chip it is — any Realtek chip with the AUX bit on will do.

The same driver can also be *forced* in software, through a few **per-adapter registry values** —
`EnableCloneMAC`, `EnableManualCloneMAC`, `AUXMacType`, `AUXMacSupportVer` — which switch
pass-through on even when the chip's AUX bit is off. This works, but it is a **Windows-only, local
override**: those values sit in the registry under **one adapter instance**, so they do **not**
travel with the card, do **not** survive a move to another machine or a clean install, and do
nothing at pre-boot or on Linux. Burning the AUX bit into the chip itself (what RtlPassthru does) is
the opposite — it rides along with the card, and every layer that honours the AUX bit sees it.

### Pre-boot / PXE (laptop firmware, before any OS)

Same requirement as Windows, one layer lower. During network boot the laptop firmware programs the
MAC into the card, and the card honours it **if the AUX bit is set.** This is the valuable part for
imaging and deployment — the machine already carries its real identity before any OS loads.

### Linux (`r8152` driver) — the different one

Linux does **not** look at the `0xCFDB` AUX bit first. It asks **"what *kind* of chip is this?"**
and only lets recognised factory variants through. From the mainline kernel
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

The key points:

- Linux keys on the **chip variant marker**, which lives in the `USB_MISC_0` / `USB_MISC_1`
  registers — a *different* register from `0xCFDB`.
- A chip that is **not** a recognised variant (`-AD`, `-BND`, `-BD`, or a Lenovo chip) is rejected
  **even if its `0xCFDB` AUX bit is set.** The driver never gets far enough to look at that bit.
- Only inside the `-AD` branch does Linux *also* check an efuse bit (`0xCFDB` bit 0), and only
  *after* the variant marker has already matched. For the `-BND` / `-BD` variants, the matching
  variant marker alone is enough.

---

## The one thing to take away

Line the layers up against the card's markers and the puzzle dissolves:

| the card's marker | Windows | PXE | Linux |
|---|:---:|:---:|:---:|
| **AUX bit** (`0xCFDB` bit 1) | checks it | checks it | ignores it |
| **PASS_THRU bit** (`0xCFDB` bit 0) | not the gate | not enough on its own | checks it — `-AD` chips only |
| **chip variant** (`-AD` / `-BND` / `-BD` / Lenovo) | ignores it | ignores it | checks it |

**Windows and PXE look at the AUX bit; Linux looks at the chip variant.** They are checking
*different markers*, so the same card can be accepted by one system and refused by another. Nothing
is "broken" — the card simply satisfies one gate and not the other.

Three cases make it concrete:

- **Only the AUX bit set** (a generic chip, burned) → **Windows and PXE: yes. Linux: no** (it is
  not a recognised variant).
- **Only a recognised variant** (a factory `-AD` / `-BND` / `-BD` / Lenovo chip, AUX bit off — on an
  `-AD` chip, with bit 0 set) → **Linux: yes. Windows and PXE: no** (no AUX bit to read).
- **Both** (a recognised variant *and* the AUX bit set) → **works everywhere.**

---

## Chip variants: `-AD`, `-BND`, `-BD`, Lenovo

The variants Linux looks for are **factory SKUs of the Realtek chip**, not user settings:

- **RTL8153-AD** — the original Dell-oriented variant; gated by an efuse bit (`0xCFDB` bit 0) as
  well as the variant marker.
- **RTL8153-BND / -BD** — later variants that pass on the variant marker alone, with no efuse bit
  required.
- **Lenovo chips** — recognised by their USB vendor ID.

The variant marker sits in the `USB_MISC` registers and is set at the factory. A generic, unbranded
Realtek NIC is usually **none** of these — which is exactly why
such a chip can work on Windows yet be turned away by Linux.

> These variant names aren't ours — they come straight from the Linux driver that gates on them: the
> `AD_MASK` / `BND_MASK` / `BD_MASK` defines and the `-AD` / `-BND` / `-BD` comments in
> [`drivers/net/usb/r8152.c`](https://github.com/torvalds/linux/blob/master/drivers/net/usb/r8152.c),
> added over the years by the kernel patches that taught Linux about each new dock generation.

---

## What this means in practice

- **Windows is the easy case.** Any Realtek chip with the AUX bit set will pass the MAC through.
- **Pre-boot / PXE** follows the same rule, below the OS — the valuable part for network boot and
  imaging.
- **Linux is the strict case.** It wants a recognised chip *variant* first. A generic dongle can be
  refused by Linux even when Windows is perfectly happy.
- **Setting the AUX bit** (what the tool does to the chip) covers **Windows and PXE on any Realtek
  chip, and Linux too when the chip is already a recognised variant.** It does not set the
  chip-variant marker.

As a worked example: pass-through on Linux was **confirmed** on an RTL8156 whose AUX bit we had
burned — an AD-class chip that Linux recognises — running Ubuntu. That is the one Linux result we
have proven directly; it does not extend to generic, non-variant chips, which Linux still refuses.

Once you see pass-through as **different markers checked by different layers**, the "why does it
work here but not there?" questions answer themselves.
