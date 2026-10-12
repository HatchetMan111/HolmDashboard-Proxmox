# Holm auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Ordners): `https://github.com/man15h/holm`
> (SvelteKit + Node 22, SQLite eingebaut – Dashboard pro Person, Launcher, App-Suche)
> Dieser Ordner enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit + Start-Config.
> Die App läuft nativ (Node + `git clone` + `npm ci` + `npm run build`, ohne Docker) – vollständig lokal, keine Cloud nötig.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HolmDashboard-Proxmox/main/install/holm.sh)"
```

> Installer-Repo: `https://github.com/HatchetMan111/HolmDashboard-Proxmox`
> (Unit + Config lädt das Script von dort; ohne Netz greift der Inline-Fallback).

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HolmDashboard-Proxmox/main/install/holm.sh)"
bash holm.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --storage local-lvm
bash holm.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/holm-install-*.log
```

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `holm` |
| Zweck | Self-hosted Dashboard: eigene Startseite pro Person, Launcher (`Ctrl+K`), Suche in Immich/Paperless/Nextcloud/Jellyfin/…, Onboarding, ein YAML-File |
| Tech-Stack | Node.js 22 + SvelteKit, Build in `/opt/holm` (`npm ci` → `npm test` → `npm run build`), Laufzeit `node /opt/holm/build` |
| GitHub-Repo (Upstream) | `https://github.com/man15h/holm` |
| Web UI | `http://<LXC-IP>:3000` (bind `0.0.0.0:3000` via `HOST`/`PORT`), Health = `GET /` |
| Standard-Ressourcen | 2 vCPU / 2048 MB RAM / 8 GB Disk |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `holm` (`onboot: 1`, unprivilegiert),
3. installiert im Container Node 22 (NodeSource) + git/curl, legt User `holm` an,
   klont/aktualisiert Upstream nach `/opt/holm`, baut (`npm ci` + `npm test` + `npm run build`),
   legt `/etc/holm/config.yml` (Start-Set: `auth.enabled: false`, sofort nutzbar)
   und `/etc/holm/holm.env` (`HOLM_SECRET_KEY`, 600, nur erzeugt wenn fehlt)
   sowie `/var/lib/holm` (SQLite via `DATABASE_PATH`) an,
   schreibt `holm.service`, `systemctl enable --now holm`,
4. verifiziert `systemctl is-active holm` + HTTP auf `localhost:3000/`
   und gibt die finale URL + Container-IP aus.

Entscheidung (selbstständig): **LXC statt VM** – Holm ist genügsam (ein Container, SQLite eingebaut,
Upstream-Image `node:22-alpine`), `nesting=1` reicht; keine GPU/VM nötig. Nur wenn der Build
auf winzigen Hosts OOM geht, RAM per Flag erhöhen (`RAM=3072`).

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active holm = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:3000/).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Holm – Dashboard fuer Team/Familie/Org
  Container    : CT 100 (Hostname: holm, unprivilegiert, onboot=1)
  Ressourcen   : 2 vCPU / 2048 MB RAM / 8 GB Disk
  Web UI       : http://192.168.1.100:3000
  ...
  Log          : /tmp/holm-install-2026-....log
══════════════════════════════════════════════════════════
```

## OIDC / echter Betrieb (optional)

Start-Config ist `auth.enabled: false` (jeder mit Netz-Zugang ist „Guest" – nur im LAN lassen!).
Für Login: im Container `/etc/holm/config.yml` nach
[`config.example.yml`](https://github.com/man15h/holm/blob/main/config.example.yml) umbauen
(`auth.enabled: true`, `auth.oidc.issuer`, `redirect_base`, Apps), OIDC-Client beim Provider
anlegen (Redirect-URI `https://<holm-host>/auth/callback`), Secrets in `/etc/holm/holm.env`
(`OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`) ergänzen, dann `systemctl restart holm`.
`HOLM_SECRET_KEY` nie teilen/überschreiben (verschlüsselt App-Credentials + Sessions).

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active holm
curl -fs http://<LXC-IP>:3000/ >/dev/null && echo WEB_UI_OK
```

Erwartet: `active` + `WEB_UI_OK`. Beleg: `journalctl -u holm -n 50`
im Container zeigt Neustart + Listener auf `:3000` nach Reboot.

## Update / Deinstall

```bash
bash holm.sh --ctid 100            # Update: idempotent (git pull + rebuild + restart)
pct stop 100 && pct destroy 100    # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/holm-install-*.log`.
- `bash holm.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status holm --no-pager`, `journalctl -u holm -n 100`,
  Config/Env prüfen: `cat /etc/holm/config.yml`, `ls -l /etc/holm/holm.env /var/lib/holm/`.

## Dateien

- `install/holm.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/holm.service` – Unit (`After=network-online.target`, `Restart=always`, User `holm`, `HOST=0.0.0.0`, `CONFIG_PATH`/`DATABASE_PATH`).
- `config/config.yml` – Start-Config (`auth.enabled: false`, Demo-App-Set, DuckDuckGo-Fallback).
