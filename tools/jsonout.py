"""Machine-readable results for the GUI.

With --json a tool still prints its human text (shown in Details / the report; 'STEP = ...' lines drive the
progress bar) and then, last, exactly one line:   JSON {...}
The GUI reads only that line, by field name - the wording of the human text can change freely.
"""
import json

FLAG = "--json"


def wanted(argv) -> bool:
    return FLAG in argv


def emit(obj) -> None:
    print("JSON " + json.dumps(obj, ensure_ascii=False, separators=(",", ":")), flush=True)
