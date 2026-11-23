"""Per-layer pass-through verdicts (tools/passthru.py), checked against cards measured on real hardware.

Run:  python -m pytest -q
"""
import passthru as pt


def yes_no(r):
    return tuple(r[layer][0] for layer in pt.LAYERS)   # (Windows, PXE, Linux)


def test_plain_1g_chip_with_aux_bit():
    # UGREEN RTL8153: 0xCFDB=0x03 from the factory, no variant marker. Measured: Linux refused it (r8152, own MAC).
    r = pt.verdict(0x0000, 0x40, 0x03)
    assert r["variant"] is None
    assert yes_no(r) == (True, True, False)


def test_ad_chip_after_burn():
    # WAVLINK / Eth6 RTL8156 after the burn: USB_MISC_0=0x1000, 0xCFDB=0x03.
    # Measured: Dell pre-boot, Windows and Linux ("Using pass-thru MAC addr") all took the host MAC.
    r = pt.verdict(0x1000, 0x00, 0x03)
    assert r["variant"] == "AD"
    assert yes_no(r) == (True, True, True)


def test_ad_chip_factory_rt_only():
    # The same RTL8156 as shipped: 0xCFDB=0x01. Measured: no pass-through in Windows or pre-boot.
    # Linux = yes is what r8152's -AD branch implies (variant + bit0); not measured on this state.
    r = pt.verdict(0x1000, 0x00, 0x01)
    assert yes_no(r) == (False, False, True)


def test_aux_only_is_why_the_option_was_removed():
    # 0x02 on an AD chip: Windows yes, Linux NO (the -AD branch needs bit0), pre-boot never tested -> unknown.
    assert yes_no(pt.verdict(0x1000, 0x00, 0x02)) == (True, None, False)


def test_pxe_only_claims_what_was_measured():
    assert pt.verdict(0x1000, 0x00, 0x03)["PXE"][0] is True     # measured: works
    assert pt.verdict(0x1000, 0x00, 0x01)["PXE"][0] is False    # measured: fails
    assert pt.verdict(0x1000, 0x00, 0x02)["PXE"][0] is None     # never measured
    assert "?" in pt.format_lines(pt.verdict(0x1000, 0x00, 0x02))[2]


def test_bnd_and_bd_need_no_efuse_bit():
    assert pt.chip_variant(0x0000, 0x04) == "BND"
    assert pt.chip_variant(0x0000, 0x01) == "BD"
    assert pt.verdict(0x0000, 0x04, 0x00)["Linux"][0] is True
    assert pt.verdict(0x0000, 0x01, 0x00)["Linux"][0] is True


def test_ad_mask_ignores_pcut_status_bit():
    # USB_MISC_0 bit0 is PCUT_STATUS - outside AD_MASK, must not break AD detection.
    assert pt.chip_variant(0x1001, 0x00) == "AD"
    assert pt.chip_variant(0x3000, 0x00) is None     # extra masked bit -> not AD


def test_lenovo_vid():
    assert pt.chip_variant(0x0000, 0x00, vid=0x17EF) == "Lenovo"
    assert pt.verdict(0x0000, 0x00, 0x00, vid=0x17EF)["Linux"][0] is True


def test_format_lines_are_stable():
    lines = pt.format_lines(pt.verdict(0x0000, 0x40, 0x03))
    assert lines[0] == "  chip variant (r8152) = none"
    assert lines[1].startswith("PASSTHRU Windows = YES  (")
    assert lines[3].startswith("PASSTHRU Linux   = NO   (")


def test_driver_profile_from_usb_revision():
    # Realtek's INF picks the install section from the low byte of bcdDevice (the card maker's choice)
    assert pt.driver_profile(0x310D) == "Sta"          # the RTL8153E dongle, UGREEN (0x31FD) too
    assert pt.driver_profile(0x31FD) == "Sta"
    assert pt.driver_profile(0x3104) == "Gaming"       # WAVLINK: "Realtek Gaming USB 2.5GbE ..."
    assert pt.driver_profile(0x3102) == "Mapt"
    assert [pt.driver_profile(r) for r in (0x300F, 0x31EF, 0x31FF)] == ["BasicFunc", "BasicFunc (Enterprise)",
                                                                             "BasicFunc"]
    assert pt.driver_profile(0x31E4) == "standard (Enterprise)"
    assert pt.driver_profile(0x3113) is None            # a one-off RTL8156B section, not in the table


def test_windows_needs_the_driver_clone_switch_too():
    on = pt.verdict(0x1000, 0, 0x03)
    assert on["Windows"][0] is True
    # BasicFunc profile: EnableCloneMAC = 0 in the registry -> Windows off despite 0xCFDB = 0x03
    off = pt.verdict(0x1000, 0, 0x03, clone=False, profile="BasicFunc")
    assert off["Windows"][0] is False and "BasicFunc" in off["Windows"][1]
    # registry not readable, but the revision says BasicFunc -> off
    assert pt.verdict(0x1000, 0, 0x03, profile="BasicFunc")["Windows"][0] is False
    # BasicFunc card after a registry fix (EnableCloneMAC = 1) -> works
    assert pt.verdict(0x1000, 0, 0x03, clone=True, profile="BasicFunc")["Windows"][0] is True
    # the clone switch only matters to Windows: pre-boot and Linux unchanged
    assert off["PXE"] == on["PXE"] and off["Linux"] == on["Linux"]
    # no AUX bit: that stays the reason, whatever the registry says
    assert "0xCFDB bit1" in pt.verdict(0x1000, 0, 0x01, clone=False)["Windows"][1]
