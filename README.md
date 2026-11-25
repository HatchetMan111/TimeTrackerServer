# TimeTracker-Proxmox

Ein-Klick-Installation von [TimeTracker](https://github.com/DRYTRIX/TimeTracker)
(self-hosted Zeiterfassung, Rechnungen, Peppol e-Invoicing, GPL-3.0) als
**unprivilegierter LXC-Container** auf Proxmox VE – im Stil der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

- **Web-UI:** `http://<CT-IP>:8080` (bindet `0.0.0.0`, Port im CT offen)
- **Stack im CT:** Python 3.11 + Flask, PostgreSQL 16 (nativ), Gunicorn/eventlet,
  Node 20 nur für den einmaligen Asset-Build
- **Reboot-sicher:** `systemd`-Service `timetracker` (`Restart=always`,
  `After=network-online.target postgresql.service`), CT mit `onboot: 1`
- **Daten persistent** unter `/data` (DB im CT, Uploads/Logs unter `/data`)

> Die App bringt ihr eigenes Server-Template-UI (Tailwind + vendor-JS) mit –
> kein React nötig; die Assets werden beim Install einmalig im CT gebaut.

---

## Einzeiler-Installation

Auf dem Proxmox-Host als root:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TimeTrackerServer/main/install/timetracker.sh)"
```

Das Script:

1. nimmt die **nächste freie CT-ID** (`pvesh get /cluster/nextid`),
2. erstellt einen unprivilegierten LXC (Standard: 2 vCPU, 2 GB RAM, 8 GB Disk,
   `nesting=1`, `onboot=1`, DHCP auf `vmbr0`),
3. installiert im Container alle Abhängigkeiten + PostgreSQL 16 + die App,
4. baut die Frontend-Assets, schreibt `.env` + systemd-Unit und startet den Service,
5. **verifiziert** danach `systemctl is-active` + HTTP `/_health` und gibt die
   finale URL aus.

### Optionen

```bash
# Eigene CT-ID / Ressourcen / Hostname / Port
... -- --id 150 --ram 4096 --disk 12 --cores 4 --hostname zeiterfassung --port 8080

# Ohne Rückfrage (Automatisierung)
... -- --yes
```

### Erwartete Ausgabe (Auszug)

```
=== TimeTracker – Neu-Installation ===
ℹ CT-ID: 150  Hostname: timetracker  RAM: 2048MB  Disk: 8GB  Cores: 2
ℹ Host-Architektur: amd64
✔ Template: debian-12-standard_12.7-1_amd64.tar.zst
=== Erstelle Container 150 ===
✔ Container läuft.
✔ CT-IP: 10.120.1.77
=== In-Container Setup (dauert einige Minuten) ===
[..] node: v20.18.1  npm: 10.8.2
[..] PostgreSQL bereit (DB timetracker).
[..] pip install fertig.
[..] Assets gebaut: dist=3 vendor=12
[..] Upstream /_health = 200
=== Verifikation ===
✔ systemctl is-active: active
✔ HTTP /_health = 200
╔══════════════════════════════════════════════════════════╗
║  TimeTracker ist installiert und läuft!                  ║
╚══════════════════════════════════════════════════════════╝
  🆔 CT-ID     : 150
  🌐 URL       : http://10.120.1.77:8080
  🔑 Erster Login wird Admin (Benutzer: admin).
```

Beim ersten Aufruf der Weboberfläche den Admin-Account anlegen
(Benutzername `admin`, Passwort frei wählen).

---

## Update

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TimeTrackerServer/main/install/timetracker.sh)" -- --update
```

Aktualisiert App-Code + Assets im bestehenden Container (findet ihn per Hostname
`timetracker`, starten ihn bei Bedarf) und startet den Service neu. Mit `--id <N>`
erzwingst du eine bestimmte CT-ID.

## Deinstallieren

```bash
... -- --uninstall          # löscht den Container (Daten in /data gehen verloren)
... -- --uninstall --id 150 # bestimmte CT-ID
```

## Status

```bash
... -- --status             # CT-Status, Service-Status, HTTP-Code, URL
```

## Reboot-Test (Verifikation)

```bash
pct reboot 150
# danach:
pct exec 150 -- systemctl is-active timetracker     # → active
pct exec 150 -- curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/_health   # → 200
```

---

## Debugging

Bei Fehlern gibt das Script die **vollständige Fehlerkette** aus (Exit-Code,
Zeile, Modus, CT-ID, letzte 40 Zeilen des Setup-Logs, Diagnose-Kommandos) und
bietet ein `bash -x`-Log an:

```bash
bash -x install/timetracker.sh 2>&1 | tee /tmp/timetracker-install-debug.log
```

In-Container-Logs:

```bash
pct exec <CTID> -- journalctl -u timetracker -n 100 --no-pager
pct exec <CTID> -- tail -n 100 /data/timetracker.log
```

---

## Projektstruktur

```
install/timetracker.sh      Proxmox-Einzeiler (Community-Scripts-konform)
systemd/timetracker.service Referenz-Unit (der Installer schreibt sie in den CT)
.env.example                Referenz-.env
README.md
```

Upstream: <https://github.com/DRYTRIX/TimeTracker> · Lizenz GPL-3.0.