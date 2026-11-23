"""The Windows driver's own settings for one adapter - read-only, from its registry key.

Every network adapter has a key under Control\\Class\\{4d36e972-...}\\NNNN; NetCfgInstanceId names it by the
interface GUID. Realtek's driver keeps there the install section Windows chose for the card (InfSection - the
driver profile, picked by the card's USB revision) and EnableCloneMAC, which its MAC pass-through needs
(not set = on, the driver's default; the BasicFunc profile writes 0).
"""
import winreg

CLASS_NET = r"SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"


def _value(key, name):
    try:
        return winreg.QueryValueEx(key, name)[0]
    except OSError:
        return None


def as_flag(v):
    """A registry value as True / False (REG_SZ "1"/"0" from the INF, REG_DWORD from a tool), None if not set."""
    if v is None:
        return None
    try:
        return int(str(v).strip(), 0) != 0
    except ValueError:
        return None


def adapter_settings(guid: str) -> dict:
    """{'key', 'inf_section', 'enable_clone_mac'} for the adapter with this interface GUID; empty dict if none."""
    guid = guid.strip().lower()
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, CLASS_NET) as cls:
        i = 0
        while True:
            try:
                sub = winreg.EnumKey(cls, i)
            except OSError:
                return {}
            i += 1
            try:
                with winreg.OpenKey(cls, sub) as k:
                    if str(_value(k, "NetCfgInstanceId") or "").lower() != guid:
                        continue
                    return {"key": sub, "inf_section": _value(k, "InfSection"),
                            "enable_clone_mac": as_flag(_value(k, "EnableCloneMAC"))}
            except OSError:
                continue
