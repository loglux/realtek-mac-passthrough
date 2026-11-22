import json

import jsonout


def test_json_line(capsys):
    jsonout.emit({"tool": "diag", "chip": {"name": "RTL8153UG (type 0x3106)"}, "cfdb": 3})
    line = capsys.readouterr().out.strip()
    assert line.startswith("JSON {")
    assert json.loads(line[5:]) == {"tool": "diag", "chip": {"name": "RTL8153UG (type 0x3106)"}, "cfdb": 3}
    assert jsonout.wanted(["{guid}", "--json"]) and not jsonout.wanted(["{guid}"])
