# TR-143 Speed Test Server

A minimal, production-tested nginx configuration (plus an Ansible role and
step-by-step CLI instructions) for running the download/upload endpoints
that CPEs use for **TR-143** bandwidth diagnostics — the same setup this
repo's author runs in production for an ISP customer base, generalized so
any ISP or CPE vendor can stand up their own.

It does two things:

- Serves a set of fixed-size files over plain HTTP GET (`/downloads/...`)
  for `DownloadDiagnostics`.
- Accepts and discards PUT/POST bodies (`/uploads`) for `UploadDiagnostics`,
  returning `200 OK` as fast as possible.

That's the entire server. No application code, no database — nginx is
fast enough to do this at multi-gigabit line rate on its own, which is the
whole point.

## Table of contents

- [What is TR-143?](#what-is-tr-143)
- [How this server implements it](#how-this-server-implements-it)
- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [Install: Option A — Ansible](#install-option-a--ansible)
- [Install: Option B — manual / step-by-step CLI](#install-option-b--manual--step-by-step-cli)
- [Pointing your CPEs at the server](#pointing-your-cpes-at-the-server)
- [Choosing test file sizes](#choosing-test-file-sizes)
- [Security & abuse prevention](#security--abuse-prevention)
- [Server sizing](#server-sizing)
- [Testing your install](#testing-your-install)
- [Troubleshooting](#troubleshooting)

## What is TR-143?

[TR-143](https://www.broadband-forum.org/technical/download/TR-143.pdf)
is a Broadband Forum specification, "Enabling Network Throughput
Performance Tests and Statistical Monitoring," that extends the CPE data
models used by TR-069/CWMP (`InternetGatewayDevice.*`, TR-098) and its
successor TR-181/USP (`Device.*`) with objects an ACS can use to make a
CPE run active network tests **from the CPE's own vantage point** —
which is what makes it useful: it measures the actual access-network
path (DSL/PON/DOCSIS/fixed-wireless link + home wiring), not just server
capacity.

The two objects this repo cares about:

- **`DownloadDiagnostics`** — the ACS sets `DownloadURL` to a location on
  this server and sets `DiagnosticsState` to `Requested`. The CPE
  performs an HTTP (or FTP) `GET` against that URL, and times it:
  `ROMTime` (DNS resolved) → `BOMTime` (first byte / body start) →
  `EOMTime` (transfer complete). Throughput is derived from
  `TestBytesReceived / (EOMTime - BOMTime)`.
- **`UploadDiagnostics`** — mirror image. The ACS sets `UploadURL` and
  `TestFileLength`; the CPE generates that many bytes locally and `PUT`s
  (some stacks `POST`) them to the server, again timing BOM/EOM. The
  server's only job is to receive the bytes and respond `200` — it
  never needs to look at the body.

Both objects also expose `NumberOfConnections`, letting the ACS ask the
CPE to open several parallel TCP streams for a single test — useful on
high-bandwidth-delay-product links where one TCP stream can't fill the
pipe. Nothing server-side needs to change for this; nginx just serves
however many concurrent requests arrive (see [Server
sizing](#server-sizing) for what that costs).

TR-143 also defines UDP-based tests (`UDPEchoConfig`,
`IPLayerCapacity`) for latency/jitter/packet-loss measurement. Those are
handled by a separate small UDP echo responder, not by this repo — this
repo is specifically the HTTP download/upload half.

## How this server implements it

Two `location` blocks in one nginx vhost — see
[`nginx/tr143-speedtest.conf.example`](nginx/tr143-speedtest.conf.example)
for the annotated version and
[`ansible/roles/tr143_speedtest/templates/tr143-speedtest.conf.j2`](ansible/roles/tr143_speedtest/templates/tr143-speedtest.conf.j2)
for the templated one the Ansible role deploys. A few choices are worth
calling out explicitly:

- **`gzip off` on `/downloads/`.** The test files are pre-generated and
  effectively incompressible by construction, but if gzip were ever
  turned on somewhere upstream in the config it would silently deflate a
  sparse/zero-filled file to near-nothing and destroy the measurement.
  Never let compression touch these locations.
- **`sendfile` + `aio threads` + `directio`.** Lets the kernel copy file
  bytes to the socket without round-tripping through nginx's userspace
  buffers, and bypasses the page cache for reads large enough that
  caching them wouldn't help anyway. This is what lets a small VM
  saturate a multi-gigabit NIC serving downloads.
- **`client_body_in_file_only on` on `/uploads`.** nginx streams the PUT
  body straight to a temp file and never loads it into memory; the
  location handler then just returns `200` without reading the file's
  contents. Point `client_body_temp_path` at a `tmpfs` mount (the
  Ansible role does this by default) so upload tests never touch a real
  disk.
- **Plain HTTP, not HTTPS, by default.** See the note in [Security &
  abuse prevention](#security--abuse-prevention) — TLS is supported
  (`tr143_enable_https`) but adds CPU overhead that can itself become
  the throughput bottleneck on fast links, which is exactly what you
  don't want in a tool whose entire purpose is measuring the CPE's real
  bottleneck.
- **`limit_req` / `limit_conn` per source IP.** A speed test endpoint is,
  by construction, an unauthenticated way to pull large files and push
  bandwidth at a server. Rate limiting keeps it from becoming a free
  file host or a target for abuse — see below.

## Repository layout

```
nginx/
  tr143-speedtest.conf.example   # annotated nginx vhost (manual install)
  tr143-limits.conf.example      # http{}-level rate-limit zones
scripts/
  generate-test-files.sh         # creates the fixed-size download files
ansible/
  playbook.yml
  inventory.example.ini
  group_vars/all.yml.example
  roles/tr143_speedtest/         # everything the playbook needs
```

## Requirements

- **OS:** Ubuntu 24.04/25.x or Debian 12 (bookworm). Anything with nginx
  ≥ 1.18 and a recent kernel (for `aio`/`directio` and BBR) works; this
  repo is tested against Ubuntu.
- A public (or CPE-reachable) IPv4/IPv6 address and a hostname, if you
  want TLS.
- Root/sudo on the target host.
- **For the Ansible path:** Ansible ≥ 2.14 on your control machine and
  SSH access to the target(s).

## Install: Option A — Ansible

```bash
cd ansible
cp inventory.example.ini inventory.ini      # edit with your host(s)
cp group_vars/all.yml.example group_vars/all.yml   # edit tr143_server_name etc.
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbook.yml
```

Key variables (full list with defaults in
[`ansible/roles/tr143_speedtest/defaults/main.yml`](ansible/roles/tr143_speedtest/defaults/main.yml)):

| Variable | Default | Purpose |
|---|---|---|
| `tr143_server_name` | `speedtest.example.net` | vhost `server_name`, and cert CN if TLS is enabled |
| `tr143_test_file_sizes_mb` | `[1,10,50,100,200,500,1000]` | download files generated, one per size |
| `tr143_max_upload_size` | `1100M` | `client_max_body_size` for `/uploads` |
| `tr143_uploads_use_tmpfs` | `true` | mount the upload temp path as RAM-backed `tmpfs` |
| `tr143_uploads_tmpfs_size` | `2G` | size that mount — see [sizing](#server-sizing) |
| `tr143_rate_limit_rps` / `tr143_conn_limit_per_ip` | `1` / `4` | abuse guard, per source IP |
| `tr143_allowed_cidrs` | `[]` | if set, only these CIDRs may hit `/downloads` and `/uploads` |
| `tr143_enable_https` | `false` | provision a Let's Encrypt cert via certbot's nginx plugin |

The role is idempotent — re-run `ansible-playbook playbook.yml` any time
you change a variable (e.g. add a new test file size, or flip on TLS).

## Install: Option B — manual / step-by-step CLI

Everything the Ansible role does, by hand, on Ubuntu/Debian. Run every
command below **on the speed test server itself** (SSH into it and work
there) — the commands reference files from this repo by relative path,
so the repo needs to exist on that machine, not just on your laptop.

**0. Get this repo onto the server**

```bash
git clone https://github.com/OktopUSP/tr-143-server.git
cd tr-143-server
```

No `git` on the box, or you'd rather not pull the whole repo (the
Ansible role isn't needed for this path)? Grab just the three files
Option B actually uses:

```bash
mkdir -p tr-143-server/scripts tr-143-server/nginx && cd tr-143-server
curl -fsSLo scripts/generate-test-files.sh https://raw.githubusercontent.com/OktopUSP/tr-143-server/main/scripts/generate-test-files.sh
curl -fsSLo nginx/tr143-speedtest.conf.example https://raw.githubusercontent.com/OktopUSP/tr-143-server/main/nginx/tr143-speedtest.conf.example
curl -fsSLo nginx/tr143-limits.conf.example https://raw.githubusercontent.com/OktopUSP/tr-143-server/main/nginx/tr143-limits.conf.example
```

**1. Install nginx**

```bash
sudo apt update
sudo apt install -y nginx
```

**2. Create the directories**

```bash
sudo mkdir -p /var/www/tr143-speedtest/downloads
sudo mkdir -p /var/lib/tr143-speedtest/uploads
sudo chown www-data:www-data /var/www/tr143-speedtest/downloads /var/lib/tr143-speedtest/uploads
sudo chmod 1777 /var/lib/tr143-speedtest/uploads
```

**3. (Recommended) Mount the upload path as tmpfs**, so upload tests
never hit a real disk:

```bash
echo 'tmpfs /var/lib/tr143-speedtest/uploads tmpfs defaults,size=2G,mode=1777,uid=www-data,gid=www-data 0 0' | sudo tee -a /etc/fstab
sudo mount /var/lib/tr143-speedtest/uploads
```

**4. Generate the download test files**

```bash
sudo cp scripts/generate-test-files.sh /usr/local/sbin/tr143-generate-test-files.sh
sudo chmod +x /usr/local/sbin/tr143-generate-test-files.sh
sudo /usr/local/sbin/tr143-generate-test-files.sh --root=/var/www/tr143-speedtest/downloads --sizes="1 10 50 100 200 500 1000"
```

**5. Install the rate-limit zones and the vhost**

```bash
sudo cp nginx/tr143-limits.conf.example /etc/nginx/conf.d/tr143-limits.conf
sudo cp nginx/tr143-speedtest.conf.example /etc/nginx/sites-available/tr143-speedtest.conf
sudo $EDITOR /etc/nginx/sites-available/tr143-speedtest.conf   # set your server_name
sudo ln -s /etc/nginx/sites-available/tr143-speedtest.conf /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
```

**6. Test and reload**

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl enable --now nginx
```

**7. Open the firewall**

```bash
sudo ufw allow 80/tcp
# sudo ufw allow 443/tcp   # only if you're enabling TLS, see step 8
```

**8. (Optional) Enable HTTPS** — only if your CPE fleet actually
requires HTTPS test URLs (read the [note above](#how-this-server-implements-it)
on the throughput cost first):

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot certonly --nginx --agree-tos -m you@example.net -d speedtest.example.net
```
Then uncomment the `listen 443 ssl http2` block and `ssl_certificate*`
lines in your vhost and reload nginx.

**9. (Recommended for scale) Kernel tuning**

```bash
sudo cp ansible/roles/tr143_speedtest/templates/99-tr143-speedtest.conf.j2 /etc/sysctl.d/99-tr143-speedtest.conf
sudo sysctl --system
```

## Pointing your CPEs at the server

Set these via your ACS, on whichever data model your CPE fleet speaks:

**TR-098 (CWMP, `InternetGatewayDevice`):**
```
InternetGatewayDevice.DownloadDiagnostics.DownloadURL = http://speedtest.example.net/downloads/200MB.file
InternetGatewayDevice.UploadDiagnostics.UploadURL     = http://speedtest.example.net/uploads
```

**TR-181 (CWMP or USP/TR-369, `Device`):**
```
Device.DownloadDiagnostics.DownloadURL = http://speedtest.example.net/downloads/200MB.file
Device.UploadDiagnostics.UploadURL     = http://speedtest.example.net/uploads
Device.UploadDiagnostics.TestFileLength = 209715200
```

Pick the download file per subscriber plan speed — see the next section.

## Choosing test file sizes

TCP slow start means a test that finishes in 1-2 seconds mostly measures
ramp-up, not steady-state throughput. Rule of thumb: pick a file size
large enough that the transfer takes **at least 10-15 seconds** at the
subscriber's contracted speed.

| Plan speed | Minimum file for a 10s test | Recommended file |
|---|---|---|
| ≤ 50 Mbps | ~62 MB | `50MB.file` |
| 100 Mbps | ~125 MB | `200MB.file` |
| 300 Mbps | ~375 MB | `500MB.file` |
| 1 Gbps | ~1.25 GB | `1000MB.file` (or higher — add a `2000` entry to `tr143_test_file_sizes_mb`) |

For symmetric multi-gigabit plans, either add larger file sizes or lean
on `NumberOfConnections` plus a shorter per-connection file — both are
legitimate; the trade-off is disk (or page-cache) footprint versus test
duration accuracy.

## Security & abuse prevention

This endpoint is, by design, an unauthenticated way to pull an arbitrary
amount of data from your network and push an arbitrary amount of data
into it — TR-143 has no provision for auth on `DownloadURL`/`UploadURL`.
Treat it accordingly:

- **Restrict source IPs where you can.** If every CPE that will ever run
  this test lives in known address space (CGNAT pools, static ranges,
  a management VRF), set `tr143_allowed_cidrs` (Ansible) or the `allow`/
  `deny` lines (manual config) to that space instead of leaving the
  endpoint open to the internet.
- **Keep the per-IP rate/connection limits on.** They're sized for "one
  CPE running one diagnostic," not for bulk downloading — a real
  diagnostic client never needs more than a couple of connections per
  IP at a time.
- **Never enable directory listing** (`autoindex`) on `/downloads/` —
  it's off by default in the provided config; keep it that way, or the
  location turns into a public file drop.
- **`gzip off` and no other processing on these locations** — beyond the
  measurement-accuracy reason above, it also means nginx never has to
  do CPU work per request beyond `sendfile()`, which keeps a single box
  cheap to run at scale.

## Server sizing

The two things that actually cost money here are **network egress** and
**NIC capacity** — not CPU or RAM. Size for those first.

### Network egress is the real cost driver

A single 200 MB download test costs 200 MB of egress; run that against
10,000 subscribers once a month and that's ~2 TB/month just for
on-demand tests — and a lot more if this feeds continuous/automated
fleet monitoring rather than occasional troubleshooting. On a
metered-egress cloud provider (commonly $0.08-0.12/GB) that adds up
fast and scales with your subscriber base, which is exactly the wrong
direction for a tool meant to run at ISP scale.

**Host this on-net.** Put the server inside your own network (or at
your peering/IX point), not on a third-party cloud VM. Traffic between
a CPE and a server on your own AS costs you nothing incremental in
egress fees, and — as a bonus — actually measures what you want to
measure (the access network), instead of also including a leg across
the public internet to a distant cloud region.

### CPU

Static file serving via `sendfile`/`directio` with TLS off is bound by
the NIC and the kernel's networking stack, not CPU — a couple of vCPUs
can push several Gbps. TLS changes this: without AES-NI (virtually all
modern x86/ARM server CPUs have it), budget roughly **1 core per ~1-2
Gbps of TLS traffic** as a starting point, less with TLS 1.3 and modern
ciphers. This is the concrete cost of the HTTPS option mentioned above.

### RAM

nginx's own footprint is negligible (tens of MB per worker). What
actually needs RAM:

- **Page cache for download files**, so repeated `GET`s are served from
  RAM instead of disk — keep total RAM comfortably above the sum of
  your `tr143_test_file_sizes_mb` set (a few GB covers a generous file
  set with room to spare).
- **The uploads `tmpfs`**, sized to `max_concurrent_uploads ×
  tr143_max_upload_size` with headroom. This is also the reason the
  default upload cap is ~1 GB rather than unbounded — an unbounded cap
  times many concurrent uploads is an easy way to OOM the box.

### Disk

Only matters if you don't use `tmpfs` for uploads (not recommended at
any real scale) or if your download file set is large enough to not
fit in page cache. NVMe if you do need disk-backed uploads — many
concurrent PUT streams are effectively many concurrent random-ish
writes.

### NIC and sizing tiers

Use realistic concurrency, not total subscriber count — diagnostics run
occasionally per-CPE, not continuously across your whole base.
`required_bandwidth ≈ expected_concurrent_tests × avg_plan_speed × 1.3-1.5
(headroom)`.

| Tier | Subscriber base | Assumed concurrent tests | vCPU | RAM | NIC | Notes |
|---|---|---|---|---|---|---|
| Lab / small ISP | < 5,000 | ~10 | 2 | 4 GB | 1 GbE | single box is plenty |
| Medium ISP | 5,000-50,000 | ~50-100 | 4-8 | 8-16 GB | 10 GbE | still one box, on-net |
| Large ISP / multi-region | 50,000+ | 200+ | 8-16 per node | 32 GB+ | 25-100 GbE per node | scale **out**, not up — see below |

### Scaling to multiple regions

Once you outgrow one box (or your network spans multiple regions/PoPs),
run one speed test server per region rather than one large central
one, and have your ACS pick the nearest server per CPE's
region/PoP/BNG. This keeps each test measuring the local access network
rather than your own backbone, and keeps any one node's blast radius
and bandwidth bill small. Each node is sized independently using the
table above against its own regional subscriber count.

## Testing your install

```bash
# Download test
curl -o /dev/null -w '%{speed_download} bytes/sec\n' http://speedtest.example.net/downloads/100MB.file

# Upload test
dd if=/dev/zero bs=1M count=100 2>/dev/null | curl -X PUT --data-binary @- -w '%{http_code}\n' http://speedtest.example.net/uploads
```

The upload command should print `200`.

## Troubleshooting

- **`nginx -t` fails on `limit_req_zone`/`limit_conn_zone`:** those
  directives must live in the `http {}` context — confirm
  `/etc/nginx/conf.d/tr143-limits.conf` exists and that your
  `nginx.conf` includes `conf.d/*.conf` (it does by default on
  Debian/Ubuntu).
- **Uploads return 413:** raise `client_max_body_size` /
  `tr143_max_upload_size` to at least your largest `TestFileLength`.
- **Uploads are slow/disk-bound:** confirm
  `/var/lib/tr143-speedtest/uploads` is actually mounted as `tmpfs`
  (`mount | grep tr143-speedtest`), not falling back to the
  underlying disk.
- **Throughput plateaus well below your NIC speed:** check
  `net.ipv4.tcp_congestion_control` (BBR recommended, see the sysctl
  template) and confirm TLS isn't in the path if you don't need it.
