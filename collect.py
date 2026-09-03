#!/usr/bin/env python3
"""Data collector for the banan.bananet (Bananet) Omarchy bar widget.

Prints one JSON document describing:
  * every network interface (Wi-Fi, Ethernet, Tailscale, ZeroTier, WireGuard,
    OpenVPN / generic tun) with addresses, counters, routes and DNS
  * where default (internet) traffic really exits (honours policy routing)
  * every established socket with owning process and the interface it egresses on
  * listening services
  * tunnel-specific detail (Tailscale peers, ZeroTier networks/peers, WireGuard peers)

Runs without root. Some detail needs extra privileges and degrades gracefully:
  * `ss -p` only shows process names for your own processes; root daemons are guessed by port
  * `wg show` and `zerotier-cli` need root (or a passwordless sudo rule / user auth token)
The collector tries `sudo -n` for those once and remembers the answer for 10 minutes.
"""
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time

HOME = os.path.expanduser("~")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.join(HOME, ".cache")), "omarchy-bananet")
RDNS_CACHE = os.path.join(CACHE_DIR, "rdns.json")
SUDO_CACHE = os.path.join(CACHE_DIR, "sudo.json")
HISTORY_FILE = os.path.join(CACHE_DIR, "history.jsonl")
HISTORY_STEP = 30          # seconds between stored samples
HISTORY_KEEP = 24 * 3600   # seconds of history to keep

OPTS = {
    "rdns": True,
    "sudo": True,
    "max_rdns": 6,
    "rdns_wait": 0.7,
    "labels": {},
    "loopback": False,
    "history": False,
    "demo": False,
}

WELL_KNOWN_PORTS = {
    41641: "tailscaled",
    3478: "stun",
    9993: "zerotier-one",
    51820: "wireguard",
    1194: "openvpn",
    22: "ssh",
    53: "dns",
    853: "dns-over-tls",
    5353: "mdns",
    67: "dhcp",
    68: "dhcp",
    123: "ntp",
}

LOOPBACK_RE = re.compile(r"^(127\.|::1$|0\.0\.0\.0$|::$)")
WARNINGS = []
SETUP = []


# --------------------------------------------------------------------------- helpers

def run(cmd, timeout=2.5):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return -1, "", str(e)


def run_json(cmd, timeout=2.5):
    rc, out, _ = run(cmd, timeout)
    if rc != 0 or not out.strip():
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def which(name):
    for d in os.environ.get("PATH", "/usr/bin:/bin").split(":"):
        p = os.path.join(d, name)
        if os.access(p, os.X_OK):
            return p
    return None


def load_json_file(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json_file(path, value):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(value, f)
        os.replace(tmp, path)
    except OSError:
        pass


_sudo_state = None


def sudo_run(cmd, key, timeout=2.5):
    """Run `sudo -n cmd`. Remember for 10 minutes when a password would be required."""
    global _sudo_state
    if not OPTS["sudo"]:
        return -1, "", "sudo disabled"
    if _sudo_state is None:
        _sudo_state = load_json_file(SUDO_CACHE, {})
    now = time.time()
    entry = _sudo_state.get(key)
    # A negative answer is remembered for 10 minutes, unless the sudoers
    # configuration changed since (the user just added a rule): then retry now.
    sudoers_mtime = 0.0
    for path in ("/etc/sudoers.d", "/etc/sudoers"):
        try:
            sudoers_mtime = max(sudoers_mtime, os.stat(path).st_mtime)
        except OSError:
            pass
    if entry and not entry.get("ok") and now - entry.get("ts", 0) < 600 and entry.get("ts", 0) > sudoers_mtime:
        return -1, "", "sudo needs password"
    rc, out, err = run(["sudo", "-n"] + cmd, timeout)
    needs_pw = rc != 0 and ("password" in err.lower() or "a terminal is required" in err.lower())
    _sudo_state[key] = {"ok": rc == 0, "ts": now}
    save_json_file(SUDO_CACHE, _sudo_state)
    if needs_pw:
        return -1, "", "sudo needs password"
    return rc, out, err


def is_loopback(ip):
    return bool(LOOPBACK_RE.match(ip))


def is_private(ip):
    return bool(re.match(r"^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|fd|fe80|fc)", ip, re.I))


def split_hostport(text):
    """'10.0.0.1:443' -> ('10.0.0.1', 443); '[::1]:22' -> ('::1', 22); strips %iface."""
    text = text.strip()
    scope = ""
    if text.startswith("["):
        host, _, rest = text[1:].partition("]")
        if rest.startswith("%"):
            scope, _, rest = rest[1:].partition(":")
            port = rest
        else:
            port = rest.lstrip(":")
    else:
        host, _, port = text.rpartition(":")
    if "%" in host:
        host, scope = host.split("%", 1)
    if host.lower().startswith("::ffff:") and host.count(".") == 3:
        host = host[7:]
    try:
        port_n = int(port)
    except ValueError:
        port_n = 0
    return host, port_n, scope


def human_bytes(n):
    n = float(n or 0)
    for unit in ("B", "kB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d %s" if unit == "B" else "%.1f %s") % (n, unit)
        n /= 1024.0
    return "%.1f TB" % n


# --------------------------------------------------------------------------- interfaces

def read_proc_net_dev():
    counters = {}
    try:
        with open("/proc/net/dev") as f:
            for line in f.readlines()[2:]:
                name, _, rest = line.partition(":")
                fields = rest.split()
                if len(fields) >= 16:
                    counters[name.strip()] = {
                        "rx": int(fields[0]), "rxPackets": int(fields[1]), "rxErrors": int(fields[2]), "rxDrop": int(fields[3]),
                        "tx": int(fields[8]), "txPackets": int(fields[9]), "txErrors": int(fields[10]), "txDrop": int(fields[11]),
                    }
    except OSError:
        pass
    return counters


def nm_devices():
    devices = {}
    rc, out, _ = run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "dev", "status"])
    if rc != 0:
        return devices
    for line in out.splitlines():
        parts = line.split(":")
        if len(parts) < 4:
            continue
        devices[parts[0]] = {"type": parts[1], "state": parts[2], "connection": ":".join(parts[3:])}
    return devices


def nm_active_connections():
    conns = []
    rc, out, _ = run(["nmcli", "-t", "-f", "NAME,TYPE,DEVICE,UUID", "con", "show", "--active"])
    if rc != 0:
        return conns
    for line in out.splitlines():
        parts = line.rsplit(":", 3)
        if len(parts) == 4:
            conns.append({"name": parts[0], "type": parts[1], "device": parts[2], "uuid": parts[3]})
    return conns


def nm_wifi_active():
    rc, out, _ = run(["nmcli", "-t", "-f", "ACTIVE,SSID,SIGNAL,FREQ,RATE", "dev", "wifi", "list", "--rescan", "no"])
    if rc != 0:
        return None
    for line in out.splitlines():
        parts = line.split(":")
        if len(parts) < 5 or parts[0] != "yes":
            continue
        return {"ssid": ":".join(parts[1:-3]), "signal": int(parts[-3] or 0), "freq": parts[-2], "rate": parts[-1]}
    return None


def nm_connection_fields(name):
    rc, out, _ = run(["nmcli", "-t", "connection", "show", name])
    fields = {}
    if rc != 0:
        return fields
    for line in out.splitlines():
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return fields


def nm_wireguard_peers(name):
    fields = nm_connection_fields(name)
    peers = {}
    for key, value in fields.items():
        m = re.match(r"^wireguard-peer\[(\d+)\]\.(.+)$", key)
        if not m:
            continue
        idx, prop = int(m.group(1)), m.group(2)
        peer = peers.setdefault(idx, {})
        if prop == "public-key":
            peer["publicKey"] = value
        elif prop == "endpoint":
            peer["endpoint"] = value
        elif prop == "allowed-ips":
            peer["allowedIps"] = [x.strip() for x in value.split(",") if x.strip()]
        elif prop == "persistent-keepalive":
            peer["keepalive"] = value
    result = [peers[k] for k in sorted(peers)]
    for p in result:
        p.setdefault("source", "nm")
    return result, fields


def parse_wg_dump(text):
    """`wg show all dump`: first line per iface = private/public/port/fwmark, then one line per peer."""
    devs = {}
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) == 5:
            devs[parts[0]] = {"publicKey": parts[2], "listenPort": parts[3], "fwmark": parts[4], "peers": []}
        elif len(parts) == 9:
            dev = devs.setdefault(parts[0], {"peers": []})
            try:
                handshake = int(parts[5])
            except ValueError:
                handshake = 0
            dev["peers"].append({
                "publicKey": parts[1],
                "endpoint": "" if parts[3] == "(none)" else parts[3],
                "allowedIps": [] if parts[4] == "(none)" else parts[4].split(","),
                "latestHandshake": handshake,
                "handshakeAge": int(time.time()) - handshake if handshake else None,
                "rx": int(parts[6] or 0),
                "tx": int(parts[7] or 0),
                "keepalive": parts[8],
                "source": "wg",
            })
    return devs


def collect_routes():
    routes = []
    for family in ("-4", "-6"):
        data = run_json(["ip", "-j", family, "route", "show", "table", "all"]) or []
        for r in data:
            if r.get("table") == "local" or r.get("type") in ("local", "broadcast", "multicast", "anycast"):
                continue
            routes.append({
                "family": "v6" if family == "-6" else "v4",
                "dst": r.get("dst", ""),
                "gateway": r.get("gateway", ""),
                "dev": r.get("dev", ""),
                "table": str(r.get("table", "main")),
                "metric": r.get("metric"),
                "protocol": r.get("protocol", ""),
                "scope": r.get("scope", ""),
                "type": r.get("type", "unicast"),
            })
    return routes


def collect_rules():
    rules = []
    for family in ("-4", "-6"):
        for r in run_json(["ip", "-j", family, "rule", "show"]) or []:
            desc = "from %s" % r.get("src", "all")
            if r.get("fwmark"):
                desc += " fwmark %s" % r["fwmark"]
            if r.get("fwmask"):
                desc += "/%s" % r["fwmask"]
            if r.get("table"):
                desc += " lookup %s" % r["table"]
            if r.get("action"):
                desc += " %s" % r["action"]
            rules.append({"family": "v6" if family == "-6" else "v4", "priority": r.get("priority"), "text": desc})
    return rules


def route_get(target, v6=False):
    cmd = ["ip", "-j"] + (["-6"] if v6 else []) + ["route", "get", target]
    data = run_json(cmd, 1.5)
    if not data:
        return None
    r = data[0]
    return {"dst": r.get("dst", target), "dev": r.get("dev", ""), "gateway": r.get("gateway", ""), "src": r.get("prefsrc", ""), "table": str(r.get("table", "main"))}


def collect_dns():
    servers, domains, default_route = {}, {}, {}
    rc, out, _ = run(["resolvectl", "dns"])
    if rc == 0:
        for line in out.splitlines():
            m = re.match(r"^(Global|Link \d+ \(([^)]+)\)):\s*(.*)$", line.strip())
            if m:
                servers[m.group(2) or "global"] = m.group(3).split()
    rc, out, _ = run(["resolvectl", "domain"])
    if rc == 0:
        current = None
        for line in out.splitlines():
            m = re.match(r"^(Global|Link \d+ \(([^)]+)\)):\s*(.*)$", line.strip())
            if m:
                current = m.group(2) or "global"
                domains[current] = m.group(3).split()
            elif current and line.startswith(" "):
                domains[current].extend(line.split())
    rc, out, _ = run(["resolvectl", "default-route"])
    if rc == 0:
        for line in out.splitlines():
            m = re.match(r"^(Global|Link \d+ \(([^)]+)\)):\s*(.*)$", line.strip())
            if m:
                default_route[m.group(2) or "global"] = m.group(3).strip() == "yes"
    return servers, domains, default_route


# --------------------------------------------------------------------------- tunnels

def collect_tailscale():
    if not which("tailscale"):
        return None
    status = run_json(["tailscale", "status", "--json"], 3.5)
    if not status:
        return {"installed": True, "state": "Unavailable"}
    self_node = status.get("Self") or {}
    exit_status = status.get("ExitNodeStatus")
    peers = []
    ip_names = {}
    for peer in (status.get("Peer") or {}).values():
        ips = peer.get("TailscaleIPs") or []
        name = peer.get("HostName") or (peer.get("DNSName") or "").rstrip(".").split(".")[0]
        for ip in ips:
            ip_names[ip] = name
        peers.append({
            "name": name,
            "dns": (peer.get("DNSName") or "").rstrip("."),
            "os": peer.get("OS", ""),
            "ips": ips,
            "ip": next((x for x in ips if "." in x), ips[0] if ips else ""),
            "online": bool(peer.get("Online")),
            "active": bool(peer.get("Active")),
            "exitNode": bool(peer.get("ExitNode")),
            "exitNodeOption": bool(peer.get("ExitNodeOption")),
            "relay": peer.get("Relay", ""),
            "curAddr": peer.get("CurAddr", ""),
            "rx": peer.get("RxBytes", 0),
            "tx": peer.get("TxBytes", 0),
            "lastHandshake": peer.get("LastHandshake", ""),
            "primaryRoutes": peer.get("PrimaryRoutes") or [],
            "allowedIps": peer.get("AllowedIPs") or [],
        })
    peers.sort(key=lambda p: (not p["active"], not p["online"], p["name"].lower()))
    exit_node = None
    if exit_status:
        exit_node = {
            "id": exit_status.get("ID", ""),
            "online": bool(exit_status.get("Online")),
            "ips": exit_status.get("TailscaleIPs") or [],
            "name": next((p["name"] for p in peers if p["exitNode"]), ""),
        }
    for ip in self_node.get("TailscaleIPs") or []:
        ip_names[ip] = self_node.get("HostName", "") or "self"
    return {
        "installed": True,
        "state": status.get("BackendState", "Unknown"),
        "running": status.get("BackendState") == "Running",
        "self": {
            "name": self_node.get("HostName", ""),
            "dns": (self_node.get("DNSName") or "").rstrip("."),
            "ips": self_node.get("TailscaleIPs") or [],
            "relay": self_node.get("Relay", ""),
            "online": bool(self_node.get("Online")),
        },
        "tailnet": (status.get("CurrentTailnet") or {}).get("Name", ""),
        "magicDns": status.get("MagicDNSSuffix", ""),
        "exitNode": exit_node,
        "peers": peers,
        "ipNames": ip_names,
        "health": status.get("Health") or [],
    }


def zerotier_cli(args):
    """Try without root (user token) then sudo -n."""
    rc, out, err = run(["zerotier-cli", "-j"] + args, 3)
    if rc == 0 and out.strip():
        return out, ""
    if "authtoken" in (err + out).lower() or rc != 0:
        rc2, out2, err2 = sudo_run(["zerotier-cli", "-j"] + args, "zerotier", 3)
        if rc2 == 0 and out2.strip():
            return out2, ""
        return "", (err or out or err2).strip()
    return "", (err or out).strip()


def collect_zerotier():
    if not which("zerotier-cli"):
        return None
    out, err = zerotier_cli(["listnetworks"])
    if not out:
        hint = ""
        if "authtoken" in err.lower() or "as root" in err.lower():
            hint = "zerotier-cli needs the auth token. Copy it once into your home directory (below) and networks, peers and latency will show up here."
            SETUP.append({
                "id": "zerotier",
                "title": "ZeroTier needs a one-time setup",
                "detail": "Without the token only the interface and routes are visible. Click to open a terminal with the command (sudo will ask for your password); right click copies it.",
                "command": "sudo cp /var/lib/zerotier-one/authtoken.secret ~/.zeroTierOneAuthToken && sudo chown \"$USER\" ~/.zeroTierOneAuthToken && chmod 600 ~/.zeroTierOneAuthToken",
                "iface": "zerotier",
            })
        else:
            WARNINGS.append("ZeroTier: " + (err or "zerotier-cli is not responding"))
        return {"installed": True, "available": False, "error": err, "hint": hint, "networks": [], "peers": []}
    try:
        networks_raw = json.loads(out)
    except ValueError:
        networks_raw = []
    networks = []
    for n in networks_raw:
        networks.append({
            "id": n.get("nwid") or n.get("id", ""),
            "name": n.get("name", ""),
            "status": n.get("status", ""),
            "type": n.get("type", ""),
            "dev": n.get("portDeviceName", ""),
            "addrs": n.get("assignedAddresses") or [],
            "mac": n.get("mac", ""),
            "mtu": n.get("mtu"),
            "bridge": bool(n.get("bridge")),
            "routes": [{"target": r.get("target", ""), "via": r.get("via") or ""} for r in (n.get("routes") or [])],
            "dns": (n.get("dns") or {}).get("servers") or [],
            "allowDefault": bool(n.get("allowDefault")),
            "allowGlobal": bool(n.get("allowGlobal")),
            "allowManaged": bool(n.get("allowManaged")),
        })
    peers = []
    out, _ = zerotier_cli(["listpeers"])
    if out:
        try:
            for p in json.loads(out):
                paths = [{"address": x.get("address", ""), "preferred": bool(x.get("preferred")), "active": bool(x.get("active"))} for x in (p.get("paths") or [])]
                peers.append({
                    "address": p.get("address", ""),
                    "latency": p.get("latency"),
                    "role": p.get("role", ""),
                    "version": p.get("version", ""),
                    "paths": paths,
                    "direct": any(x["active"] for x in paths),
                })
        except ValueError:
            pass
    leafs = [p for p in peers if p["role"] == "LEAF"]
    roots = [p for p in peers if p["role"] != "LEAF"]
    return {"installed": True, "available": True, "networks": networks, "peers": leafs, "rootCount": len(roots), "rootsDirect": sum(1 for p in roots if p["direct"])}


def collect_wireguard(links, active_conns):
    devs = [l["name"] for l in links if l.get("infoKind") == "wireguard"]
    result = {}
    dump = {}
    if devs and which("wg"):
        rc, out, err = run(["wg", "show", "all", "dump"], 2)
        if rc != 0:
            rc, out, err = sudo_run(["wg", "show", "all", "dump"], "wg", 2)
        if rc == 0:
            dump = parse_wg_dump(out)
        else:
            SETUP.append({
                "id": "wireguard",
                "title": "WireGuard: no access to `wg show`",
                "detail": "Peers, endpoints and handshakes need root. Click to add a passwordless sudo rule for `wg show` only (asks for your password); right click copies the command.",
                "command": "echo \"$USER ALL=(root) NOPASSWD: /usr/bin/wg show *\" | sudo tee /etc/sudoers.d/omarchy-bananet-wg >/dev/null && echo OK",
                "iface": "wireguard",
            })
    elif devs:
        WARNINGS.append("WireGuard: wireguard-tools (`wg`) is not installed; showing NetworkManager data only.")
    nm_by_dev = {c["device"]: c for c in active_conns if c["type"] == "wireguard"}
    for dev in devs:
        entry = {"dev": dev, "peers": [], "listenPort": "", "nmName": ""}
        if dev in dump:
            entry.update({k: v for k, v in dump[dev].items() if k != "publicKey"})
            entry["publicKey"] = dump[dev].get("publicKey", "")
        if dev in nm_by_dev:
            entry["nmName"] = nm_by_dev[dev]["name"]
            if not entry["peers"]:
                peers, fields = nm_wireguard_peers(nm_by_dev[dev]["name"])
                entry["peers"] = peers
                entry["listenPort"] = entry["listenPort"] or fields.get("wireguard.listen-port", "")
        result[dev] = entry
    return result


def collect_openvpn(links, active_conns):
    result = {}
    rc, out, _ = run(["pgrep", "-a", "-x", "openvpn"])
    procs = []
    if rc == 0:
        for line in out.splitlines():
            pid, _, cmd = line.partition(" ")
            m_cfg = re.search(r"--config\s+(\S+)", cmd)
            m_dev = re.search(r"--dev\s+(\S+)", cmd)
            m_remote = re.search(r"--remote\s+(\S+)(?:\s+(\d+))?", cmd)
            procs.append({"pid": int(pid), "config": os.path.basename(m_cfg.group(1)) if m_cfg else "", "dev": m_dev.group(1) if m_dev else "", "remote": (m_remote.group(1) + (":" + m_remote.group(2) if m_remote.group(2) else "")) if m_remote else ""})
    nm_vpn = {c["device"]: c for c in active_conns if c["type"] == "vpn" and c["device"]}
    for link in links:
        name = link["name"]
        if link.get("infoKind") != "tun":
            continue
        entry = None
        for p in procs:
            if p["dev"] == name or (not p["dev"] and len(procs) == 1):
                entry = {"dev": name, "kind": "openvpn", "name": p["config"] or "openvpn", "remote": p["remote"], "pid": p["pid"]}
        if name in nm_vpn:
            fields = nm_connection_fields(nm_vpn[name]["name"])
            data = fields.get("vpn.data", "")
            m = re.search(r"remote\s*=\s*([^,]+)", data)
            service = fields.get("vpn.service-type", "").rsplit(".", 1)[-1]
            entry = entry or {"dev": name, "kind": "openvpn" if "openvpn" in service else "vpn", "name": nm_vpn[name]["name"], "remote": "", "pid": 0}
            entry["name"] = nm_vpn[name]["name"]
            entry["remote"] = entry["remote"] or (m.group(1).strip() if m else "")
            entry["service"] = service
        if entry:
            result[name] = entry
    return result


# --------------------------------------------------------------------------- sockets

def parse_ss(text, listening=False):
    rows = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 6:
            continue
        proto, state = parts[0], parts[1]
        local, peer = parts[4], parts[5]
        users = " ".join(parts[6:])
        lip, lport, lscope = split_hostport(local)
        rip, rport, _ = split_hostport(peer) if peer != "*:*" else ("", 0, "")
        proc, pid = "", 0
        m = re.search(r'users:\(\("([^"]+)",pid=(\d+)', users)
        if m:
            proc, pid = m.group(1), int(m.group(2))
        rows.append({"proto": proto, "state": state, "lip": lip, "lport": lport, "lscope": lscope, "rip": rip, "rport": rport, "proc": proc, "pid": pid})
    return rows


def collect_sockets():
    cmd = ["ss", "-tunpHO"]
    rc, out, err = run(cmd)
    privileged = False
    if OPTS["sudo"]:
        rc2, out2, _ = sudo_run(cmd, "ss", 2.5)
        if rc2 == 0:
            out, privileged = out2, True
    conns = parse_ss(out) if out else []
    rc, lout, _ = run(["ss", "-tulnpHO"])
    if privileged:
        rc2, lout2, _ = sudo_run(["ss", "-tulnpHO"], "ss-listen", 2.5)
        if rc2 == 0:
            lout = lout2
    listeners = parse_ss(lout, listening=True) if lout else []
    return conns, listeners, privileged


# --------------------------------------------------------------------------- reverse DNS

def resolve_names(ips):
    if not OPTS["rdns"] or not ips:
        return {}
    cache = load_json_file(RDNS_CACHE, {})
    now = time.time()
    result = {}
    todo = []
    for ip in ips:
        entry = cache.get(ip)
        if entry:
            ttl = 86400 if entry.get("name") else (120 if entry.get("timeout") else 1800)
            if now - entry.get("ts", 0) < ttl:
                if entry.get("name"):
                    result[ip] = entry["name"]
                continue
        todo.append(ip)
    todo = todo[: OPTS["max_rdns"]]
    if not todo:
        return result
    answers = {}

    def worker(ip):
        try:
            answers[ip] = socket.gethostbyaddr(ip)[0]
        except (socket.herror, socket.gaierror, OSError):
            answers[ip] = ""

    threads = []
    for ip in todo:
        t = threading.Thread(target=worker, args=(ip,), daemon=True)
        t.start()
        threads.append(t)
    deadline = now + OPTS["rdns_wait"]
    for t in threads:
        remaining = deadline - time.time()
        if remaining > 0:
            t.join(remaining)
    for ip in todo:
        if ip in answers:
            cache[ip] = {"name": answers[ip], "ts": now}
            if answers[ip]:
                result[ip] = answers[ip]
        else:
            cache[ip] = {"name": "", "ts": now, "timeout": True}
    if len(cache) > 3000:
        for key in sorted(cache, key=lambda k: cache[k].get("ts", 0))[:1000]:
            cache.pop(key, None)
    save_json_file(RDNS_CACHE, cache)
    return result


# --------------------------------------------------------------------------- history

def record_history(counters, now):
    """Append one sample per HISTORY_STEP to a 24h ring file; return the ring when asked.

    Each line: [ts, {"dev": [rx, tx], ...}] with cumulative byte counters, so the
    widget can derive rates for any window and survive counter resets (negative
    deltas are dropped on the reading side).
    """
    lines = []
    try:
        with open(HISTORY_FILE) as f:
            lines = [ln for ln in f.read().splitlines() if ln.strip()]
    except OSError:
        pass
    last_ts = 0.0
    if lines:
        try:
            last_ts = float(json.loads(lines[-1])[0])
        except (ValueError, IndexError, TypeError):
            last_ts = 0.0
    sample = {name: [c.get("rx", 0), c.get("tx", 0)] for name, c in counters.items() if name != "lo"}
    changed = False
    if now - last_ts >= HISTORY_STEP - 1:
        lines.append(json.dumps([round(now, 1), sample], separators=(",", ":")))
        changed = True
    # trim to the retention window
    cutoff = now - HISTORY_KEEP
    kept = []
    for ln in lines:
        try:
            if float(json.loads(ln)[0]) >= cutoff:
                kept.append(ln)
            else:
                changed = True
        except (ValueError, IndexError, TypeError):
            changed = True
    if changed:
        try:
            os.makedirs(CACHE_DIR, exist_ok=True)
            tmp = HISTORY_FILE + ".tmp"
            with open(tmp, "w") as f:
                f.write("\n".join(kept) + ("\n" if kept else ""))
            os.replace(tmp, HISTORY_FILE)
        except OSError:
            pass
    if not OPTS["history"]:
        return None
    out = []
    for ln in kept:
        try:
            out.append(json.loads(ln))
        except ValueError:
            pass
    return out


# --------------------------------------------------------------------------- demo

def demo_output(now):
    """Synthetic but realistic data for screenshots and for trying the widget
    on a machine without tunnels. Nothing here comes from the real system."""
    import math
    import random
    rnd = random.Random(42)

    def rate_profile(t, base, burst):
        hour = (t / 3600.0) % 24
        day = 0.35 + 0.65 * (0.5 + 0.5 * math.sin((hour - 9) / 24 * 2 * math.pi))
        return base * day + (burst * rnd.random() if rnd.random() < 0.06 else 0) + base * 0.15 * rnd.random()

    ifaces_spec = [
        ("wlp2s0", 180000, 2500000, 30000, 900000),
        ("tailscale0", 9000, 400000, 6000, 250000),
        ("ztabc123de", 3000, 120000, 2500, 90000),
        ("wg0", 20000, 800000, 15000, 600000),
    ]
    history = []
    counters = {name: [0, 0] for name, *_ in ifaces_spec}
    t = now - 24 * 3600
    while t <= now:
        for name, rb, rburst, tb, tburst in ifaces_spec:
            counters[name][0] += int(rate_profile(t, rb, rburst) * 30)
            counters[name][1] += int(rate_profile(t, tb, tburst) * 30)
        history.append([round(t, 1), {k: list(v) for k, v in counters.items()}])
        t += 30
    if OPTS["history"] and OPTS["demo"]:
        pass
    total = {k: v for k, v in counters.items()}

    def iface(name, kind, label, ip, addrs, addrs6, gw, mtu, mac, routes, dns, dns_default, conns, tunnel, is_default=False, wifi=None, nm=""):
        return {
            "name": name, "kind": kind, "label": label, "up": True, "active": True, "operstate": "up", "carrier": True,
            "mtu": mtu, "mac": mac, "addrs": addrs, "addrs6": addrs6, "ip": ip, "gateway": gw, "isDefault": is_default,
            "rx": total[name][0], "tx": total[name][1], "rxPackets": total[name][0] // 900, "txPackets": total[name][1] // 700, "rxDrop": 0, "txDrop": 0,
            "routes": routes, "moreRoutes": 0, "dns": dns, "dnsDomains": [], "dnsRoutingDomains": 0, "dnsDefaultRoute": dns_default,
            "nmConnection": nm, "nmState": "connected", "wifi": wifi,
            "connCount": sum(c for _, c in conns), "connByProc": [{"proc": p, "count": c} for p, c in conns], "tunnel": tunnel,
        }

    r = lambda dst, dev, gw="", table="main", proto="kernel", metric=None: {"family": "v4", "dst": dst, "gateway": gw, "dev": dev, "table": table, "metric": metric, "protocol": proto, "scope": "", "type": "unicast"}
    ts_peers = [
        {"name": "homelab", "dns": "homelab.tail1234.ts.net", "os": "linux", "ips": ["100.101.1.10"], "ip": "100.101.1.10", "online": True, "active": True, "exitNode": False, "exitNodeOption": True, "relay": "fra", "curAddr": "203.0.113.7:41641", "rx": 48_000_000, "tx": 12_000_000, "lastHandshake": "", "primaryRoutes": ["192.168.10.0/24"], "allowedIps": []},
        {"name": "macbook", "dns": "macbook.tail1234.ts.net", "os": "macOS", "ips": ["100.101.1.22"], "ip": "100.101.1.22", "online": True, "active": False, "exitNode": False, "exitNodeOption": False, "relay": "fra", "curAddr": "", "rx": 0, "tx": 0, "lastHandshake": "", "primaryRoutes": [], "allowedIps": []},
        {"name": "phone", "dns": "phone.tail1234.ts.net", "os": "android", "ips": ["100.101.1.31"], "ip": "100.101.1.31", "online": False, "active": False, "exitNode": False, "exitNodeOption": False, "relay": "", "curAddr": "", "rx": 0, "tx": 0, "lastHandshake": "", "primaryRoutes": [], "allowedIps": []},
    ]
    tailscale = {"installed": True, "state": "Running", "running": True, "self": {"name": "laptop", "dns": "laptop.tail1234.ts.net", "ips": ["100.101.1.5", "fd7a:115c:a1e0::1"], "relay": "fra", "online": True},
                 "tailnet": "alice@example.com", "magicDns": "tail1234.ts.net", "exitNode": None, "peers": ts_peers, "ipNames": {}, "health": []}
    zt_net = {"id": "8bd5124fd6a1c0e2", "name": "office", "status": "OK", "type": "PRIVATE", "dev": "ztabc123de", "addrs": ["10.147.20.15/24"], "mac": "", "mtu": 2800, "bridge": False,
              "routes": [{"target": "10.147.20.0/24", "via": ""}, {"target": "192.168.50.0/24", "via": "10.147.20.1"}], "dns": [], "allowDefault": False, "allowGlobal": False, "allowManaged": True}
    zt_peers = [{"address": "a1b2c3d4e5", "latency": 18, "role": "LEAF", "version": "1.14.0", "paths": [{"address": "198.51.100.4/9993", "preferred": True, "active": True}], "direct": True},
                {"address": "f6e7d8c9b0", "latency": 64, "role": "LEAF", "version": "1.12.2", "paths": [], "direct": False}]
    zerotier = {"network": zt_net, "peers": zt_peers, "rootCount": 4, "rootsDirect": 3, "available": True, "hint": ""}
    wg = {"dev": "wg0", "nmName": "MikroTik BTH", "listenPort": "51820", "publicKey": "kQ7c…demo…Xa4=", "peers": [
        {"publicKey": "hB2m…demo…9Lw=", "endpoint": "bth.example.net:13231", "allowedIps": ["192.168.88.0/24", "10.10.0.0/16"], "latestHandshake": int(now) - 47, "handshakeAge": 47, "rx": 96_000_000, "tx": 31_000_000, "keepalive": "25", "source": "wg"}]}
    interfaces = [
        iface("wlp2s0", "wifi", "Wi-Fi · HomeNet-5G", "192.168.1.42", ["192.168.1.42/24"], [], "192.168.1.1", 1500, "aa:bb:cc:dd:ee:01",
              [r("default", "wlp2s0", "192.168.1.1", proto="dhcp", metric=600), r("192.168.1.0/24", "wlp2s0", metric=600)],
              ["192.168.1.1"], True, [("firefox", 14), ("claude", 6), ("syncthing", 3), ("tailscaled", 2)], None, True, {"ssid": "HomeNet-5G", "signal": 82, "freq": "5180 MHz", "rate": "866 Mbit/s"}, "HomeNet-5G"),
        iface("tailscale0", "tailscale", "Tailscale · alice@example.com", "100.101.1.5", ["100.101.1.5/32"], ["fd7a:115c:a1e0::1/128"], "", 1280, "",
              [r("100.101.1.10", "tailscale0", table="52"), r("100.101.1.22", "tailscale0", table="52"), r("192.168.10.0/24", "tailscale0", table="52")],
              ["100.100.100.100"], False, [("ssh", 2), ("firefox", 1)], tailscale),
        iface("ztabc123de", "zerotier", "ZeroTier · office", "10.147.20.15", ["10.147.20.15/24"], [], "", 2800, "aa:bb:cc:dd:ee:02",
              [r("10.147.20.0/24", "ztabc123de"), r("192.168.50.0/24", "ztabc123de", "10.147.20.1", proto="static", metric=5000)],
              [], False, [("smbclient", 1)], zerotier),
        iface("wg0", "wireguard", "WireGuard · MikroTik BTH", "10.10.5.2", ["10.10.5.2/32"], [], "", 1420, "",
              [r("192.168.88.0/24", "wg0", proto="static"), r("10.10.0.0/16", "wg0", proto="static")],
              ["192.168.88.1"], False, [("winbox", 1), ("ssh", 1)], wg),
    ]
    conn = lambda proc, remote, name, dev, n=1, proto="tcp": [{"proto": proto, "state": "ESTAB", "local": "", "remote": remote, "rip": remote.rsplit(":", 1)[0], "rport": int(remote.rsplit(":", 1)[1]), "rname": name, "proc": proc, "pid": 4242, "dev": dev}] * n
    connections = (conn("firefox", "142.250.74.78:443", "fra24s05-in-f14.1e100.net", "wlp2s0", 6) + conn("firefox", "151.101.1.140:443", "", "wlp2s0", 4)
                   + conn("firefox", "104.16.132.229:443", "", "wlp2s0", 4, "udp") + conn("firefox", "100.101.1.10:8443", "homelab", "tailscale0")
                   + conn("claude", "160.79.104.10:443", "", "wlp2s0", 6) + conn("syncthing", "192.168.1.30:22000", "", "wlp2s0", 3)
                   + conn("tailscaled", "203.0.113.7:41641", "", "wlp2s0", 2, "udp") + conn("ssh", "100.101.1.10:22", "homelab", "tailscale0", 2)
                   + conn("smbclient", "10.147.20.1:445", "", "ztabc123de") + conn("winbox", "192.168.88.1:8291", "", "wg0") + conn("ssh", "192.168.88.10:22", "", "wg0"))
    processes = {}
    for c in connections:
        pr = processes.setdefault(c["proc"], {"name": c["proc"], "pids": [4242], "count": 0, "guessed": False, "byDev": {}, "remotes": {}, "moreRemotes": 0})
        pr["count"] += 1
        pr["byDev"][c["dev"]] = pr["byDev"].get(c["dev"], 0) + 1
        rm = pr["remotes"].setdefault(c["remote"], {"addr": c["remote"], "ip": c["rip"], "port": c["rport"], "name": c["rname"], "dev": c["dev"], "proto": c["proto"], "count": 0})
        rm["count"] += 1
    process_list = []
    for pr in processes.values():
        pr["byDev"] = [{"dev": d, "count": n} for d, n in sorted(pr["byDev"].items(), key=lambda kv: -kv[1])]
        pr["remotes"] = sorted(pr["remotes"].values(), key=lambda x: -x["count"])
        process_list.append(pr)
    process_list.sort(key=lambda p: -p["count"])
    listeners = [
        {"proto": "tcp", "port": 22, "addr": "0.0.0.0", "scope": "all", "proc": "sshd", "pid": 812, "guessed": False},
        {"proto": "tcp", "port": 8384, "addr": "127.0.0.1", "scope": "lo", "proc": "syncthing", "pid": 1043, "guessed": False},
        {"proto": "tcp", "port": 22000, "addr": "0.0.0.0", "scope": "all", "proc": "syncthing", "pid": 1043, "guessed": False},
        {"proto": "udp", "port": 41641, "addr": "0.0.0.0", "scope": "all", "proc": "tailscaled", "pid": 900, "guessed": False},
        {"proto": "udp", "port": 9993, "addr": "0.0.0.0", "scope": "all", "proc": "zerotier-one", "pid": 910, "guessed": False},
        {"proto": "tcp", "port": 5900, "addr": "100.101.1.5", "scope": "tailscale0", "proc": "wayvnc", "pid": 2210, "guessed": False},
    ]
    return {
        "ts": now, "tookMs": 41, "privilegedSockets": True, "demo": True,
        "egress": {"v4": {"dst": "1.1.1.1", "dev": "wlp2s0", "gateway": "192.168.1.1", "src": "192.168.1.42", "table": "main"}, "v6": None, "exitNode": None, "dnsDev": "wlp2s0", "dns": ["192.168.1.1"]},
        "interfaces": interfaces, "tunnelsActive": 3, "connections": connections, "otherStates": 2, "processes": process_list,
        "listeners": listeners, "rules": [], "tailscale": tailscale, "zerotier": {"installed": True, "available": True, "networks": [zt_net], "peers": zt_peers, "rootCount": 4, "rootsDirect": 3},
        "warnings": [], "setup": [], "history": history if OPTS["history"] else None, "historyStep": HISTORY_STEP,
    }


# --------------------------------------------------------------------------- main

def main():
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--no-rdns":
            OPTS["rdns"] = False
        elif a == "--no-sudo":
            OPTS["sudo"] = False
        elif a == "--loopback":
            OPTS["loopback"] = True
        elif a == "--history":
            OPTS["history"] = True
        elif a == "--demo":
            OPTS["demo"] = True
        elif a == "--max-rdns" and i + 1 < len(args):
            OPTS["max_rdns"] = int(args[i + 1]); i += 1
        elif a == "--labels" and i + 1 < len(args):
            try:
                OPTS["labels"] = json.loads(args[i + 1])
            except ValueError:
                pass
            i += 1
        i += 1

    started = time.time()
    if OPTS["demo"]:
        json.dump(demo_output(started), sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return
    links_raw = run_json(["ip", "-j", "-d", "link", "show"]) or []
    addrs_raw = run_json(["ip", "-j", "addr", "show"]) or []
    counters = read_proc_net_dev()
    history = record_history(counters, started)
    nm_devs = nm_devices()
    active_conns = nm_active_connections()
    wifi = nm_wifi_active()
    routes = collect_routes()
    rules = collect_rules()
    dns_servers, dns_domains, dns_default = collect_dns()
    egress4 = route_get("1.1.1.1")
    egress6 = route_get("2606:4700:4700::1111", v6=True)

    links = []
    for l in linkless_sorted(links_raw):
        info = l.get("linkinfo") or {}
        kind = info.get("info_kind", "")
        if kind == "tun":
            kind = (info.get("info_data") or {}).get("type", "tun")  # "tun" or "tap"
            kind = "tun" if kind in ("tun", "tap") else kind
        links.append({
            "name": l.get("ifname", ""),
            "index": l.get("ifindex"),
            "operstate": l.get("operstate", ""),
            "flags": l.get("flags") or [],
            "mtu": l.get("mtu"),
            "mac": l.get("address", ""),
            "linkType": l.get("link_type", ""),
            "infoKind": kind,
            "tunType": (info.get("info_data") or {}).get("type", "") if info.get("info_kind") == "tun" else "",
        })

    addr_by_dev, addr_to_dev = {}, {}
    for a in addrs_raw:
        name = a.get("ifname", "")
        v4, v6 = [], []
        for ai in a.get("addr_info") or []:
            local = ai.get("local", "")
            entry = "%s/%s" % (local, ai.get("prefixlen", ""))
            if ai.get("family") == "inet":
                v4.append(entry)
            else:
                v6.append(entry)
            addr_to_dev[local] = name
        addr_by_dev[name] = {"v4": v4, "v6": v6}

    tailscale = collect_tailscale()
    zerotier = collect_zerotier()
    wireguard = collect_wireguard(links, active_conns)
    openvpn = collect_openvpn(links, active_conns)
    zt_by_dev = {n["dev"]: n for n in (zerotier or {}).get("networks", [])}

    conns, listeners, privileged_ss = collect_sockets()

    # Egress device per connection: bound local address is authoritative; fall back to a route lookup.
    route_cache = {}
    for c in conns:
        dev = c["lscope"] or addr_to_dev.get(c["lip"], "")
        if not dev and c["rip"] and not is_loopback(c["rip"]):
            if c["rip"] not in route_cache:
                r = route_get(c["rip"], v6=":" in c["rip"])
                route_cache[c["rip"]] = (r or {}).get("dev", "")
            dev = route_cache[c["rip"]]
        if c["rip"] and is_loopback(c["rip"]):
            dev = "lo"
        c["dev"] = dev or "?"
        if not c["proc"]:
            guess = WELL_KNOWN_PORTS.get(c["rport"]) or WELL_KNOWN_PORTS.get(c["lport"])
            c["proc"] = guess or ""
            c["guessed"] = bool(guess)
            if not guess:
                c["proc"] = "(root/other user)"
    for l in listeners:
        if l["lip"] in ("0.0.0.0", "::", "*"):
            l["scope"] = "all"
        elif is_loopback(l["lip"]):
            l["scope"] = "lo"
        else:
            l["scope"] = addr_to_dev.get(l["lip"], l["lip"])
        if not l["proc"]:
            guess = WELL_KNOWN_PORTS.get(l["lport"])
            l["proc"] = guess or "(root/other user)"
            l["guessed"] = bool(guess)

    # Names for remote hosts: Tailscale peers are free, the rest goes through a cached reverse lookup.
    ip_names = dict((tailscale or {}).get("ipNames", {}))
    for n in (zerotier or {}).get("networks", []):
        for a in n.get("addrs", []):
            ip_names[a.split("/")[0]] = "me (%s)" % n.get("name", "zerotier")
    if egress4 and egress4.get("gateway"):
        ip_names.setdefault(egress4["gateway"], "gateway")
    remote_ips = sorted({c["rip"] for c in conns if c["rip"] and not is_loopback(c["rip"]) and c["rip"] not in ip_names})
    ip_names.update(resolve_names(remote_ips))
    for c in conns:
        c["rname"] = ip_names.get(c["rip"], "")
        # A root daemon we could not see in `ss -p` often gives itself away by where it talks to.
        if c.get("proc") == "(root/other user)" or (c.get("guessed") and c["proc"] in ("stun", "dns")):
            name = c["rname"].lower()
            if "tailscale.com" in name or c["rip"].startswith("100.") or c["rip"].startswith("fd7a:115c:a1e0:"):
                c["proc"], c["guessed"] = "tailscaled", True
            elif "zerotier.com" in name:
                c["proc"], c["guessed"] = "zerotier-one", True

    # Aggregate: per process and per interface.
    active_states = ("ESTAB", "SYN-SENT", "SYN-RECV")
    live = [c for c in conns if c["state"] in active_states and (OPTS["loopback"] or c["dev"] != "lo")]
    processes = {}
    for c in live:
        p = processes.setdefault(c["proc"], {"name": c["proc"], "pids": set(), "count": 0, "byDev": {}, "remotes": {}, "guessed": bool(c.get("guessed"))})
        p["count"] += 1
        if c["pid"]:
            p["pids"].add(c["pid"])
        p["byDev"][c["dev"]] = p["byDev"].get(c["dev"], 0) + 1
        key = "%s:%s" % (c["rip"], c["rport"])
        r = p["remotes"].setdefault(key, {"addr": key, "ip": c["rip"], "port": c["rport"], "name": c["rname"], "dev": c["dev"], "proto": c["proto"], "count": 0})
        r["count"] += 1
    process_list = []
    for p in processes.values():
        remotes = sorted(p["remotes"].values(), key=lambda r: (-r["count"], r["addr"]))
        process_list.append({
            "name": p["name"], "pids": sorted(p["pids"]), "count": p["count"], "guessed": p["guessed"],
            "byDev": [{"dev": d, "count": n} for d, n in sorted(p["byDev"].items(), key=lambda kv: -kv[1])],
            "remotes": remotes[:40], "moreRemotes": max(0, len(remotes) - 40),
        })
    process_list.sort(key=lambda p: (-p["count"], p["name"].lower()))

    interfaces = []
    egress_dev = (egress4 or {}).get("dev", "")
    for l in links:
        name = l["name"]
        if name == "lo":
            continue
        nm = nm_devs.get(name, {})
        nm_type = nm.get("type", "")
        kind = "other"
        label = name
        tunnel = None
        if l["infoKind"] == "wireguard":
            kind = "wireguard"
            wg = wireguard.get(name, {})
            label = "WireGuard" + (" · " + wg["nmName"] if wg.get("nmName") else "")
            tunnel = wg
        elif name == "tailscale0" or (tailscale and name in ("tailscale0",)):
            kind = "tailscale"
            label = "Tailscale" + (" · " + tailscale["tailnet"] if tailscale and tailscale.get("tailnet") else "")
            tunnel = tailscale
        elif name in zt_by_dev or (name.startswith("zt") and l["infoKind"] == "tun"):
            kind = "zerotier"
            net = zt_by_dev.get(name)
            label = "ZeroTier" + (" · " + (net.get("name") or net.get("id")) if net else "")
            tunnel = {"network": net, "peers": (zerotier or {}).get("peers", []), "rootCount": (zerotier or {}).get("rootCount", 0), "rootsDirect": (zerotier or {}).get("rootsDirect", 0), "available": bool(zerotier and zerotier.get("available")), "hint": (zerotier or {}).get("hint", "")}
        elif name in openvpn:
            kind = openvpn[name]["kind"]
            label = ("OpenVPN" if kind == "openvpn" else "VPN") + " · " + openvpn[name]["name"]
            tunnel = openvpn[name]
        elif l["infoKind"] == "tun":
            kind = "vpn"
            label = "Tunnel (%s)" % (l["tunType"] or "tun")
        elif nm_type == "wifi":
            kind = "wifi"
            label = "Wi-Fi" + (" · " + wifi["ssid"] if wifi and wifi.get("ssid") else (" · " + nm.get("connection") if nm.get("connection") else ""))
        elif nm_type == "ethernet" or l["linkType"] == "ether" and not l["infoKind"]:
            kind = "ethernet"
            label = "Ethernet" + (" · " + nm["connection"] if nm.get("connection") else "")
        elif l["infoKind"] in ("bridge", "veth", "dummy", "macvlan", "vlan", "bond", "team"):
            kind = "virtual"
            label = l["infoKind"]
        elif nm_type == "wifi-p2p":
            continue
        if name in OPTS["labels"]:
            label = str(OPTS["labels"][name])
        addrs = addr_by_dev.get(name, {"v4": [], "v6": []})
        flags = l["flags"]
        is_up = "UP" in flags and ("LOWER_UP" in flags or l["operstate"] in ("up", "unknown"))
        has_addr = bool(addrs["v4"]) or any(not a.startswith("fe80") for a in addrs["v6"])
        dev_routes = [r for r in routes if r["dev"] == name]
        gateway = next((r["gateway"] for r in dev_routes if r["dst"] == "default" and r["gateway"]), "")
        dev_conns = [c for c in live if c["dev"] == name]
        by_proc = {}
        for c in dev_conns:
            by_proc[c["proc"]] = by_proc.get(c["proc"], 0) + 1
        ctr = counters.get(name, {})
        interfaces.append({
            "name": name,
            "kind": kind,
            "label": label,
            "up": is_up,
            "active": is_up and has_addr,
            "operstate": l["operstate"],
            "carrier": "NO-CARRIER" not in flags,
            "mtu": l["mtu"],
            "mac": l["mac"],
            "addrs": addrs["v4"],
            "addrs6": [a for a in addrs["v6"] if not a.startswith("fe80")],
            "ip": addrs["v4"][0].split("/")[0] if addrs["v4"] else (addrs["v6"][0].split("/")[0] if addrs["v6"] else ""),
            "gateway": gateway,
            "isDefault": name == egress_dev,
            "rx": ctr.get("rx", 0), "tx": ctr.get("tx", 0),
            "rxPackets": ctr.get("rxPackets", 0), "txPackets": ctr.get("txPackets", 0),
            "rxDrop": ctr.get("rxDrop", 0), "txDrop": ctr.get("txDrop", 0),
            "routes": dev_routes[:24], "moreRoutes": max(0, len(dev_routes) - 24),
            "dns": dns_servers.get(name, []),
            "dnsDomains": [d for d in dns_domains.get(name, []) if not d.startswith("~")][:6],
            "dnsRoutingDomains": sum(1 for d in dns_domains.get(name, []) if d.startswith("~")),
            "dnsDefaultRoute": dns_default.get(name, False),
            "nmConnection": nm.get("connection", ""),
            "nmState": nm.get("state", ""),
            "wifi": wifi if kind == "wifi" else None,
            "connCount": len(dev_conns),
            "connByProc": [{"proc": k, "count": v} for k, v in sorted(by_proc.items(), key=lambda kv: -kv[1])],
            "tunnel": tunnel,
        })

    order = {"tailscale": 1, "zerotier": 1, "wireguard": 1, "openvpn": 1, "vpn": 1, "wifi": 2, "ethernet": 2, "virtual": 3, "other": 3}
    interfaces.sort(key=lambda i: (0 if i["isDefault"] else 1, order.get(i["kind"], 3), not i["active"], i["name"]))

    if not privileged_ss:
        SETUP.append({
            "id": "ss",
            "title": "Root process names are guessed",
            "detail": "`ss -p` without root cannot see tailscaled, sshd etc. Optional: click to allow passwordless `sudo ss` (asks for your password); right click copies the command.",
            "command": "echo \"$USER ALL=(root) NOPASSWD: /usr/bin/ss\" | sudo tee /etc/sudoers.d/omarchy-bananet-ss >/dev/null && echo OK",
            "iface": "",
            "minor": True,
        })
    default_dns_dev = next((d for d, on in dns_default.items() if on and d != "global"), "")
    output = {
        "ts": time.time(),
        "tookMs": int((time.time() - started) * 1000),
        "privilegedSockets": privileged_ss,
        "egress": {
            "v4": egress4,
            "v6": egress6,
            "exitNode": (tailscale or {}).get("exitNode"),
            "dnsDev": default_dns_dev,
            "dns": dns_servers.get(default_dns_dev, []) if default_dns_dev else dns_servers.get("global", []),
        },
        "interfaces": interfaces,
        "tunnelsActive": sum(1 for i in interfaces if i["active"] and i["kind"] in ("tailscale", "zerotier", "wireguard", "openvpn", "vpn")),
        "connections": [
            {"proto": c["proto"], "state": c["state"], "local": "%s:%s" % (c["lip"], c["lport"]), "remote": "%s:%s" % (c["rip"], c["rport"]), "rip": c["rip"], "rport": c["rport"], "rname": c["rname"], "proc": c["proc"], "pid": c["pid"], "dev": c["dev"]}
            for c in live
        ],
        "otherStates": len(conns) - len(live),
        "processes": process_list,
        "listeners": sorted(
            [{"proto": l["proto"], "port": l["lport"], "addr": l["lip"], "scope": l["scope"], "proc": l["proc"], "pid": l["pid"], "guessed": bool(l.get("guessed"))} for l in listeners],
            key=lambda l: (l["scope"] == "lo", l["port"], l["proto"]),
        ),
        "rules": rules,
        "tailscale": tailscale,
        "zerotier": zerotier,
        "warnings": WARNINGS,
        "setup": SETUP,
        "history": history,
        "historyStep": HISTORY_STEP,
    }
    json.dump(output, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    sys.stdout.flush()


def linkless_sorted(links):
    return sorted(links, key=lambda l: l.get("ifindex", 0))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never leave the widget without a document
        json.dump({"error": "%s: %s" % (type(e).__name__, e), "ts": time.time(), "interfaces": [], "processes": [], "listeners": [], "warnings": [], "setup": []}, sys.stdout)
        sys.stdout.write("\n")
    finally:
        sys.stdout.flush()
        os._exit(0)
