# 📕 Open PDF Studio — Proxmox LXC Installer

[Open PDF Studio](https://github.com/OpenAEC-Foundation/open-pdf-studio) ist ein freier
(LGPL-3.0+), komplett lokaler PDF-Editor für Leute, die mit Zeichnungen arbeiten:
**Markup & Bemaßung, skalengenaues Messen, Revisionsvergleich, Symbolbibliotheken,
CAD-Import** — ohne Account, ohne Abo, ohne Wasserzeichen. Dieser Installer bringt die
**Browser-Version** als statische Web-App in einen LXC-Container auf deinem Proxmox-Server.

> Die Browser-Version verarbeitet PDFs **ausschließlich clientseitig** (PDF.js im Browser):
> Dokumente bleiben auf deinem Rechner, nichts wird auf dem Server gespeichert und nichts
> verlässt dein LAN. Desktop-only-Features (OCR, DWG-Export, Signaturen) sind der
> Browser-Variante nicht verfügbar — alles andere schon.

## 🚀 Einzeiler-Installation (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenPDF/main/install/openpdfstudio.sh)"
```

Das Script (Community-Scripts-Stil):
- erzeugt selbstständig einen **unprivilegierten LXC** (Standard: 2 vCPU, 2 GB RAM,
  8 GB Disk, Debian 13, DHCP, `onboot=1`, `nesting=1`) mit dem Namen **`open-pdf-studio`**
  und nimmt die **nächste freie CT-ID** (per Prompt überschreibbar)
- installiert **nginx** und deployt den fertigen Web-UI-Build (`dist/` aus diesem Repo —
  kein Node/npm im Container nötig)
- richtet die Web-UI **reboot-sicher** ein (systemd-Drop-in: `Restart=on-failure`,
  `After=network-online.target`; Container startet automatisch)
- **verifiziert** sich selbst: `systemctl is-active nginx`, HTTP-Check `localhost:8080`,
  App-Titel-Grep, Erreichbarkeit vom Host
- gibt am Ende die **finale URL** mit der Container-IP aus

Danach erreichst du die App unter **`http://<LXC-IP>:8080`**.

### Variablen (per Env überschreibbar)

| Variable | Standard | Bedeutung |
|---|---|---|
| `OPDS_CTID` | nächste freie | Container-ID |
| `OPDS_PORT` | `8080` | Web-UI-Port (im CT, bind 0.0.0.0) |
| `OPDS_RAM` | `2048` | RAM in MiB |
| `OPDS_DISK` | `8` | Root-Disk in GB |
| `OPDS_CORES` | `2` | vCPUs |
| `OPDS_STORAGE` | `local-lvm` | Proxmox-Storage |
| `OPDS_BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `OPDS_VERSION_TEMPLATE` | `13` | Debian-Vorlage |

Beispiel mit eigenen Werten:

```bash
OPDS_CTID=120 OPDS_PORT=8090 OPDS_RAM=1024 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenPDF/main/install/openpdfstudio.sh)"
```

## 🔄 Update

Einfach **denselben Einzeiler erneut ausführen** — der Installer erkennt die bestehende
Installation und läuft im Update-Modus (neues `dist/` wird deployt, nginx-Konfig frisch,
Daten bleiben — es gibt keine serverseitigen Daten).

Eine neue Upstream-Version einspielen:

```bash
# 1. In tools/build-dist.sh nichts ändern — einfach:
UPSTREAM_REF=v2026.48.0 bash tools/build-dist.sh
# 2. dist/ + VERSION committen & pushen
# 3. Installer re-run auf dem Host
```

## 🗑️ Deinstallation

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenPDF/main/install/openpdfstudio.sh)" --uninstall
```

(Sicherheitsnetz: es wird nur ein CT mit dem Hostnamen `open-pdf-studio` gelöscht —
oder das per `OPDS_CTID=<id>` benannte, wenn dessen Hostname passt.)

## 📊 Status

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenPDF/main/install/openpdfstudio.sh)" --status
```

zeigt CT-Status, IP, nginx-Status, HTTP-Code der Web-UI und die installierte Version.

> Hinweis: `bash -c "$(wget …)" --flag` überreicht das Flag als `$0` — der Installer
> erkennt das (`$0`-Fallback) und behandelt es korrekt.

## 🧰 Wie es funktioniert

```
install/openpdfstudio.sh           Host-Script: CT anlegen, DNS prüfen, pushen, verifizieren
install/openpdfstudio-install.sh   Läuft im CT: apt (nur bei Frischinstall), dist-Deploy,
                                   nginx-vHost, systemd-Drop-in, Selbst-Verifikation
systemd/nginx-openpdfstudio.conf   systemd-Drop-in für nginx.service (reboot-sicher)
dist/                              Fertiger statischer Web-UI-Build (vite --mode hosted)
tools/build-dist.sh                Reproduzierbarer Upstream-Build (sparse-clone @ Tag)
VERSION                            Getaggte Upstream-Version im dist/ (z. B. v2026.47.0)
```

Der Build ist **exakt der Upstream-CI-Build** (`.github/workflows/live.yml`:
`vite build --mode hosted` bzw. `OPDS_WEB_BUILD=1`) — kein Fork, keine Code-Änderungen
am Upstream. Rust/CMake ist **nicht** nötig (nur für die Tauri-Desktop-Shell).

## 🐞 Debugging

Bei Fehlern gibt der Installer die **volle Fehlerkette** aus (fehlgeschlagener Befehl,
Exit-Code, Script-Zeile, Log-Auszüge aus dem CT, nginx-Status, DNS-Diagnostik).
Für einen vollständigen Trace:

```bash
wget -qO /tmp/openpdfstudio.sh https://raw.githubusercontent.com/HatchetMan111/OpenPDF/main/install/openpdfstudio.sh
bash -x /tmp/openpdfstudio.sh
```

Innerhalb des CT: `bash -x /tmp/openpdfstudio-install.sh` (Log liegt unter
`/var/log/openpdfstudio-install.log`).

## ✅ Lizenz / Urheber

- Installer: MIT (c) 2026 Phil — Upstream-App unangetastet
- [Open PDF Studio](https://github.com/OpenAEC-Foundation/open-pdf-studio): LGPL-3.0-or-later,
  © OpenAEC Foundation
