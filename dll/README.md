# Put the Realtek DLL here

This folder ships **empty on purpose**. The tool needs Realtek's own diagnostic library, which is
Realtek's property and is **not distributed with this project** — you supply your own copy (it's a
free, one-minute download).

Copy **both** of these here (flat in this folder is fine):

- `RtlDirectDiagLib64.dll`
- `RTDiagLibV2.dll`

They live inside Realtek's free **Ethernet Diagnostic Program** — download it from Realtek's
**USB Ethernet Family Controller Software** page
(<https://www.realtek.com/download/List?cate_id=585>), unzip it, and take both files from its
`EXE\64\` folder.

See the main [README](../README.md#setup) for the full walkthrough.
