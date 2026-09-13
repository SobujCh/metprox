# metprox

Add extra IPv4 addresses on a Debian VPS and run a 3proxy instance on each one.

## Setup

```bash
chmod +x setup.sh restore.sh
sudo ./setup.sh
```

If `auth.txt` is missing, enter credentials as:

```
username:password
```

If `ip.txt` is missing, paste the full list and finish with an empty line:

```
103.174.50.4/24 103.174.50.1
103.200.10.2/24 103.200.10.1
```

You can also create those files yourself before running the script.

## What it does

- Backs up `/etc/network/interfaces.d/50-cloud-init` once as `50-cloud-init_backup` (never overwrites an existing backup)
- Adds each IP from `ip.txt` and source-routes it
- Installs 3proxy with one port per IPv4, starting at `30000`

Example: first IP uses port `30000`, second uses `30001`, and so on.

Connect with the username and password from `auth.txt`.

## Restore

```bash
sudo ./restore.sh
```

Puts the original network file back, removes the extra IPs, and stops 3proxy.

## Options

```bash
INTERFACE=ens3 PROXY_START_PORT=10000 sudo ./setup.sh
```
