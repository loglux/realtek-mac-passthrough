"""List / classify Realtek diag DLLs by their command set. Read-only, no card.

With no argument: scan the known locations and print one line per detected DLL.
With a path:      classify just that file (used by the GUI's "Locate..." button).

One line per DLL:  <kind>\t<exports>\t<status>\t<path>
  kind    = new | old | none  (none = the file is not a Realtek diag DLL)
  status  = ok   (all required commands present)  |  missing:cmd1,cmd2...  |  not-a-diag-dll
Usage:  python -I dll_list.py            |  python -I dll_list.py "C:\\path\\RtlDirectDiagLib64.dll"
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rtldiag import classify, discover  # noqa: E402


def _line(kind, exports, missing, version, path):
    if kind is None:
        status = "not-a-diag-dll"
    elif missing:
        status = "missing:" + ",".join(missing)
    else:
        status = "ok"
    print(f"{kind or 'none'}\t{exports if exports is not None else 0}\t{status}\t{version or '?'}\t{path}")


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    if len(sys.argv) > 1:
        p = sys.argv[1]
        kind, n, missing, ver = classify(p)
        _line(kind, n, missing, ver, p)
    else:
        for kind, info in discover().items():
            _line(kind, info["exports"], info["missing"], info["version"], info["path"])
