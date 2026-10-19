# Notice

This repository is an **independent, unofficial companion toolkit** for
**A2DP-Windows-Bridge** by **SeiyaFunaokaJP**
(<https://github.com/SeiyaFunaokaJP/A2DP-Windows-Bridge>). It is not affiliated
with, endorsed by, or maintained by the upstream author, and it contains **no
upstream source code**. SeiyaFunaokaJP is the author of A2DPWB and is credited
for it here and in the README.

The toolkit's own code is released under the MIT licence (see `LICENSE`).
Upstream A2DP-Windows-Bridge is dual-licensed **Apache-2.0 / MIT**; its licence
governs the upstream project, not this repository.

## BTstack (BlueKitchen GmbH)

The A2DPWB binaries embed **BTstack**. BTstack's licence (BlueKitchen GmbH)
permits use and redistribution **only for personal, non-commercial purposes**.
Therefore this toolkit, and any use of A2DPWB together with it, must remain
**personal and non-commercial** unless a commercial BTstack licence is obtained
from BlueKitchen GmbH. This applies regardless of A2DPWB's own Apache-2.0/MIT
licence.

## Realtek firmware

The Realtek firmware files (`rtl8852bu_fw.bin`, `rtl8852bu_config.bin`) are
**proprietary** and are **not included** in this repository. The helper script
`scripts/fetch-realtek-fw.ps1` only downloads them from the **linux-firmware**
project. The Linux firmware is distributed under its own licence; consult the
`linux-firmware` tree for the terms that apply to each blob.
