# Hermes Agent and three-service Oracle A1 runbook

This documents the deployed Postiz + OmniRoute + Hermes Agent installation on
the existing Ubuntu ARM64 VPS at `137.23.47.160`. PostPilot's application
remains untouched and its Caddy container provides the shared reverse proxy.

## Architecture

```text
Internet :80/:443
  -> Caddy
     -> Postiz      127.0.0.1:4007
     -> OmniRoute   127.0.0.1:20128
     -> Hermes web  172.18.0.1:9119 (mTLS + Hermes login)

Hermes Agent 0.21.0
  -> local API      127.0.0.1:8642
  -> OmniRoute      127.0.0.1:20128/v1, model auto
  -> isolated Docker terminal sandbox, 0.75 CPU / 1 GiB RAM
```

Only SSH, HTTP, and HTTPS listen publicly. Postiz, OmniRoute, Temporal UI,
Temporal RPC, and the Hermes agent API remain private. The authenticated Hermes
dashboard is `https://hermes.digitalamritomni.duckdns.org`; Caddy can reach its
backend only through the private `postpilot_edge` Docker bridge.

## 1. Oracle Cloud settings

In Oracle Cloud Console:

1. Open **Compute -> Instances -> your instance**.
2. Confirm the shape has 2 OCPU and 12 GB RAM.
3. Open the attached VNIC, then its subnet.
4. Open the active Security List or Network Security Group.
5. Keep stateful ingress TCP `22` from your own public-IP `/32` where possible.
6. Keep stateful ingress TCP `80` and TCP `443` from `0.0.0.0/0`.
7. Do not add ingress for `20128`, `4007`, `7233`, `8080`, `8642`, `9119`, `5432`, or `6379`.
8. Keep the boot volume at least 100 GB; the current filesystem is about 96 GB.
9. Create an OCI boot-volume backup policy if off-VM disaster recovery matters.

The host does not use UFW. Isolation comes from loopback bindings, Docker
networks, and the Oracle Security List/NSG.

## 2. Connect from Windows PowerShell

```powershell
ssh -i "$env:USERPROFILE\.ssh\postpilot_oracle_ed25519" ubuntu@137.23.47.160
```

Use the private key without `.pub`. Never copy the key contents to the VPS or
put them in a repository.

## 3. Public Hermes dashboard

Open in Microsoft Edge or Google Chrome:

```text
https://hermes.digitalamritomni.duckdns.org
```

The client certificate is installed in the current Windows user's Personal
certificate store. When the browser asks, select **Amrit Hermes Browser**.
Then use the Hermes username and password stored locally at:

```powershell
Get-Content "$env:USERPROFILE\.ssh\hermes-mtls\dashboard-login.txt"
```

Protected client-access files:

```text
C:\Users\amrit\.ssh\hermes-mtls\hermes-browser.p12
C:\Users\amrit\.ssh\hermes-mtls\client-import-password.txt
C:\Users\amrit\.ssh\hermes-mtls\dashboard-login.txt
C:\Users\amrit\.ssh\hermes-mtls\client-ca.crt
```

The `.p12` is required on every additional browser/device. Import it into that
device's personal certificate store using `client-import-password.txt`. Firefox
uses its own certificate store on some installations; import the `.p12` through
Firefox **Settings -> Privacy & Security -> Certificates** if it does not offer
the installed Windows certificate.

The client certificate expires on `2027-10-03`; issue a replacement before
that date. Do not email or upload the `.p12`, dashboard password, or import
password. They are not stored in this repository.

Security layers:

- Let's Encrypt HTTPS with automatic renewal.
- Mandatory mutual TLS client certificate at Caddy; anonymous TLS fails.
- Hermes native scrypt-hashed password; plaintext is not stored on the VPS.
- One-hour Hermes sessions and stable random session-signing secret.
- Native password-login rate limit: ten attempts per minute per client IP.
- HSTS and defensive browser headers.
- Dashboard backend bound only to `172.18.0.1`, not a public host interface.
- Persistent host firewall permits port `9119` only from the Caddy bridge.
- Caddy request bodies capped at 32 MB and sensitive query values redacted.

No public system is unhackable. Mutual TLS sharply reduces the attack surface
because scanners cannot reach the Hermes login or dashboard without the client
private key.

## 4. Use Hermes over SSH

Interactive session after SSH:

```bash
hermes
```

One-shot request:

```bash
hermes -z "Summarize today's scheduled work."
```

Status and logs:

```bash
hermes --version
hermes gateway status
curl -fsS http://127.0.0.1:8642/health
journalctl --user -u hermes-gateway.service -n 100 --no-pager
```

Hermes currently provides the private API, cron scheduler, CLI, memory, and
Docker terminal tools. Telegram, Discord, Slack, and similar channels are not
enabled because no bot credentials were supplied. Add one later with:

```bash
hermes gateway setup
systemctl --user restart hermes-gateway.service
```

Do not enable `GATEWAY_ALLOW_ALL_USERS`. Use platform allowlists or pairing.

## 5. Resource allocation

The ceilings prevent a single service from exhausting the 12 GB host. They are
not preallocated; idle services use only what they need.

| Component | Memory ceiling | CPU ceiling |
| --- | ---: | ---: |
| Postiz application | 3.5 GiB | 1.25 OCPU |
| Temporal | 768 MiB | 0.75 OCPU |
| Temporal Elasticsearch | 768 MiB | 0.50 OCPU |
| Each PostgreSQL | 384 MiB | 0.35 OCPU |
| Postiz Redis | 192 MiB | 0.20 OCPU |
| Temporal UI | 128 MiB | 0.15 OCPU |
| Temporal admin tools | 64 MiB | 0.10 OCPU |
| OmniRoute | 2.5 GiB | 1.00 OCPU |
| OmniRoute Redis | 160 MiB | shared |
| Hermes gateway | 1.25 GiB | 0.75 OCPU |
| Hermes dashboard | 1.25 GiB | 0.75 OCPU |
| Hermes terminal sandbox | 1 GiB | 0.75 OCPU |

Hermes cron concurrency is `1`; maximum agent iterations are `100`. Browser
and computer-use engines were intentionally not installed. The terminal runs
inside a Docker container with no host working-directory mount, no forwarded
secrets, a configured 8 GB disk ceiling where the Docker storage driver
supports quotas, and a 15-minute lifetime. Sandboxes are not persisted across
Hermes processes, limiting stale disk use.

Host protections:

- 8 GiB swap, `vm.swappiness=15`.
- Docker live-restore enabled.
- Docker JSON logs rotate at 10 MiB, retaining three files.
- Unattended Ubuntu security updates enabled.
- No unattended application-image updater; application upgrades are deliberate.

## 6. Automatic recovery

```bash
systemctl status docker --no-pager
systemctl status postiz-watchdog.timer omniroute-watchdog.timer --no-pager
systemctl --user status hermes-gateway.service hermes-dashboard.service --no-pager
systemctl --user status hermes-healthcheck.timer hermes-dashboard-healthcheck.timer --no-pager
```

- Docker restart policies recover crashed containers.
- `postiz-watchdog.timer` checks every two minutes and restarts stopped or
  unhealthy Postiz/Temporal containers.
- `omniroute-watchdog.timer` uses two failed checks before restarting OmniRoute.
- Hermes runs as a lingering systemd user service with `Restart=always`.
- `hermes-healthcheck.timer` checks `/health` every two minutes and restarts a
  hung gateway.
- `hermes-dashboard-healthcheck.timer` checks the private dashboard backend
  every two minutes and restarts it if needed.

No single-VPS design can promise zero downtime: host failure, Oracle outages,
full disks, upstream model outages, or bad upgrades can still interrupt it.
These controls provide automatic recovery from normal process/container faults.

## 7. Backups

| Data | Schedule | Retention | Location |
| --- | --- | --- | --- |
| Postiz PostgreSQL | Daily | 7 days | `/opt/backups/postiz` |
| Postiz uploads/config/deployment | Weekly | 14 days | `/opt/backups/postiz-files` |
| OmniRoute database/config | Daily | 7 days | `/opt/backups/omniroute` |
| Hermes state/config/sessions | Daily | 7 days | `/opt/backups/hermes` |

Run and inspect backups:

```bash
sudo systemctl start postiz-backup.service
sudo systemctl start postiz-files-backup.service
sudo systemctl start omniroute-backup.service
sudo systemctl start hermes-backup.service

systemctl list-timers \
  postiz-backup.timer postiz-files-backup.timer \
  omniroute-backup.timer hermes-backup.timer --no-pager
```

Local backups do not survive loss of the boot volume. Copy them to separately
protected storage or use OCI boot-volume backups for disaster recovery.

## 8. Updates

Hermes:

```bash
sudo systemctl start hermes-backup.service
hermes update
hermes doctor
systemctl --user restart hermes-gateway.service
systemctl --user restart hermes-dashboard.service
curl -fsS http://127.0.0.1:8642/health
```

Postiz:

```bash
sudo systemctl start postiz-backup.service
cd /opt/postiz
docker compose pull
docker compose up -d
docker compose ps
```

`/opt/postiz/.env` makes Docker Compose automatically load both
`docker-compose.production.yaml` and `docker-compose.resources.yaml`; do not
run only the production file or the limits will be omitted.

OmniRoute is pinned to `3.8.49`. Follow the separate OmniRoute runbook before
changing that image.

## 9. Full health check

```bash
curl -fsS https://postiz.pachey.duckdns.org/ -o /dev/null
curl -fsS https://digitalamritomni.duckdns.org/api/monitoring/health
curl -fsS http://127.0.0.1:8642/health
curl -fsS http://172.18.0.1:9119/api/status

cd /opt/postiz && docker compose ps
cd /opt/omniroute && docker compose ps
hermes gateway status
systemctl --user status hermes-dashboard.service --no-pager

docker stats --no-stream
free -h
df -h /
systemctl --failed --no-pager
systemctl --user --failed --no-pager
```

Expected public endpoints:

- `https://postiz.pachey.duckdns.org` -> HTTP 200.
- `https://digitalamritomni.duckdns.org` -> HTTP 200/redirect to its UI.
- `https://hermes.digitalamritomni.duckdns.org` -> requires the client
  certificate, then redirects to the Hermes login.
- `127.0.0.1:8642/health` -> JSON status `ok`.

Important files:

```text
/home/ubuntu/.hermes/config.yaml
/home/ubuntu/.hermes/.env                 mode 0600
/home/ubuntu/.config/systemd/user/hermes-gateway.service
/home/ubuntu/.config/systemd/user/hermes-gateway.service.d/resources.conf
/home/ubuntu/.config/systemd/user/hermes-dashboard.service
/home/ubuntu/postpilot/infra/sites/hermes.caddy
/home/ubuntu/postpilot/infra/sites/hermes-client-ca.crt
/opt/postiz/docker-compose.production.yaml
/opt/postiz/docker-compose.resources.yaml
/opt/postiz/.env
/opt/omniroute/.env                       mode 0600
/etc/docker/daemon.json
```

Never print or copy `.env` contents into logs, support tickets, or repositories.
