#!/usr/bin/env python3
"""
network-info.py - Network and IP address collector for Omarchy shell plugin
Supports --local, --public, and --all output modes.
"""

import sys
import os
import json
import subprocess
import urllib.request
import time

CACHE_DIR = os.path.expanduser("~/.cache/omarchy")
PUBLIC_CACHE_FILE = os.path.join(CACHE_DIR, "ip-info-public.json")

def prefix_to_netmask(prefix):
    try:
        prefix = int(prefix)
        mask = (0xffffffff >> (32 - prefix)) << (32 - prefix)
        return f"{(mask >> 24) & 0xff}.{(mask >> 16) & 0xff}.{(mask >> 8) & 0xff}.{mask & 0xff}"
    except Exception:
        return ""

def get_local_info():
    info = {
        "connected": False,
        "primary": {},
        "interfaces": [],
        "dns": []
    }

    # 1. Primary route via probe destination (1.1.1.1)
    primary_dev = ""
    primary_src = ""
    primary_gw = ""

    try:
        r = subprocess.run(["ip", "-j", "route", "get", "1.1.1.1"], capture_output=True, text=True, timeout=2)
        if r.returncode == 0:
            routes = json.loads(r.stdout)
            if routes and isinstance(routes, list):
                rt = routes[0]
                primary_dev = rt.get("dev", "")
                primary_src = rt.get("prefsrc", "")
                primary_gw = rt.get("gateway", "")
    except Exception:
        pass

    # Fallback to default route if probe did not answer
    if not primary_dev:
        try:
            r = subprocess.run(["ip", "-j", "route", "show", "default"], capture_output=True, text=True, timeout=2)
            if r.returncode == 0:
                routes = json.loads(r.stdout)
                if routes and isinstance(routes, list):
                    rt = routes[0]
                    primary_dev = rt.get("dev", "")
                    primary_src = rt.get("prefsrc", "")
                    primary_gw = rt.get("gateway", "")
        except Exception:
            pass

    if primary_dev:
        info["connected"] = True
        info["primary"] = {
            "iface": primary_dev,
            "ip": primary_src,
            "gateway": primary_gw,
            "mac": "",
            "type": "other",
            "operstate": "DOWN",
            "prefix": "",
            "netmask": "",
            "ipv6": "",
            "speed": "",
            "duplex": "",
            "ssid": "",
            "signal": "",
            "gatewayPingMs": ""
        }

    # 2. Inspect all network interfaces
    try:
        r = subprocess.run(["ip", "-j", "addr", "show"], capture_output=True, text=True, timeout=2)
        if r.returncode == 0:
            links = json.loads(r.stdout)
            for link in links:
                ifname = link.get("ifname", "")
                if ifname == "lo":
                    continue
                mac = link.get("address", "")
                operstate = link.get("operstate", "")
                flags = link.get("flags", [])

                # Determine UP status (tun/point-to-point often reports operstate UNKNOWN with UP flag)
                is_up = "UP" in flags or operstate == "UP"
                normalized_state = "UP" if is_up else (operstate if operstate else "DOWN")

                # Determine interface category
                itype = "other"
                if os.path.isdir(f"/sys/class/net/{ifname}/wireless") or ifname.startswith("wl"):
                    itype = "wifi"
                elif ifname.startswith("en") or ifname.startswith("eth"):
                    itype = "ethernet"
                elif "tailscale" in ifname:
                    itype = "tailscale"
                elif ifname.startswith("tun") or ifname.startswith("wg") or "POINTOPOINT" in flags:
                    itype = "vpn"

                v4_list = []
                v6_list = []
                for a in link.get("addr_info", []):
                    fam = a.get("family")
                    local = a.get("local")
                    prefix = a.get("prefixlen")
                    if fam == "inet" and local:
                        v4_list.append({"ip": local, "prefix": prefix})
                    elif fam == "inet6" and local:
                        v6_list.append({"ip": local, "prefix": prefix, "scope": a.get("scope")})

                if ifname == primary_dev:
                    info["primary"]["mac"] = mac
                    info["primary"]["type"] = itype
                    info["primary"]["operstate"] = normalized_state
                    if v4_list:
                        info["primary"]["prefix"] = str(v4_list[0]["prefix"])
                        info["primary"]["netmask"] = prefix_to_netmask(v4_list[0]["prefix"])
                        if not info["primary"]["ip"]:
                            info["primary"]["ip"] = v4_list[0]["ip"]

                    # Prefer global ipv6 address
                    for a6 in v6_list:
                        if a6.get("scope") == "global":
                            info["primary"]["ipv6"] = a6["ip"]
                            break
                    if not info["primary"]["ipv6"] and v6_list:
                        info["primary"]["ipv6"] = v6_list[0]["ip"]

                    # Extra link attributes
                    if itype == "ethernet":
                        try:
                            if os.path.isfile(f"/sys/class/net/{ifname}/speed"):
                                with open(f"/sys/class/net/{ifname}/speed") as sf:
                                    s = sf.read().strip()
                                    if s and int(s) > 0:
                                        info["primary"]["speed"] = s
                            if os.path.isfile(f"/sys/class/net/{ifname}/duplex"):
                                with open(f"/sys/class/net/{ifname}/duplex") as df:
                                    info["primary"]["duplex"] = df.read().strip()
                        except Exception:
                            pass
                    elif itype == "wifi":
                        try:
                            nm_out = subprocess.run(
                                ["nmcli", "-t", "-f", "GENERAL.CONNECTION", "dev", "show", ifname],
                                capture_output=True, text=True, timeout=1
                            )
                            if nm_out.returncode == 0:
                                for line in nm_out.stdout.splitlines():
                                    if line.startswith("GENERAL.CONNECTION:"):
                                        info["primary"]["ssid"] = line.split(":", 1)[1].strip()
                                        break
                        except Exception:
                            pass

                for v4 in v4_list:
                    info["interfaces"].append({
                        "iface": ifname,
                        "type": itype,
                        "ip": v4["ip"],
                        "prefix": str(v4["prefix"]),
                        "netmask": prefix_to_netmask(v4["prefix"]),
                        "mac": mac,
                        "state": normalized_state,
                        "isP2P": "POINTOPOINT" in flags,
                        "isPrimary": (ifname == primary_dev and v4["ip"] == info["primary"].get("ip"))
                    })
    except Exception:
        pass

    # 3. Gateway Ping Latency
    gw = info.get("primary", {}).get("gateway")
    if gw:
        try:
            r = subprocess.run(["ping", "-c", "1", "-W", "1", gw], capture_output=True, text=True, timeout=1.5)
            if r.returncode == 0:
                for line in r.stdout.splitlines():
                    if "time=" in line or "time<" in line:
                        part = line.split("time=")[-1] if "time=" in line else line.split("time<")[-1]
                        info["primary"]["gatewayPingMs"] = part.split()[0].strip()
                        break
        except Exception:
            pass

    # 4. DNS Servers via resolvectl
    try:
        r = subprocess.run(["resolvectl", "dns"], capture_output=True, text=True, timeout=1.5)
        if r.returncode == 0:
            dns_set = set()
            for line in r.stdout.splitlines():
                parts = line.split(":")
                if len(parts) > 1:
                    for s in parts[1].strip().split():
                        if s and not s.startswith("fd") and not s.startswith("fe80"):
                            dns_set.add(s)
            info["dns"] = sorted(list(dns_set))
    except Exception:
        pass

    return info

def get_public_info(use_cache_fallback=True):
    # Try reading cache if fresh (< 5 minutes)
    now = time.time()
    if use_cache_fallback and os.path.isfile(PUBLIC_CACHE_FILE):
        try:
            with open(PUBLIC_CACHE_FILE, "r") as cf:
                cached = json.load(cf)
                cached_time = cached.get("_timestamp", 0)
                if now - cached_time < 300 and cached.get("ip"):
                    cached["fromCache"] = True
                    return cached
        except Exception:
            pass

    res = {
        "ip": "",
        "hostname": "",
        "city": "",
        "region": "",
        "country": "",
        "org": "",
        "loc": "",
        "status": "offline",
        "_timestamp": now,
        "fromCache": False
    }

    # 1. Primary: ipinfo.io/json
    try:
        req = urllib.request.Request("https://ipinfo.io/json", headers={"User-Agent": "curl/8.0.0"})
        with urllib.request.urlopen(req, timeout=3.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("ip"):
                res["ip"] = data.get("ip", "").strip()
                res["hostname"] = data.get("hostname", "")
                res["city"] = data.get("city", "")
                res["region"] = data.get("region", "")
                res["country"] = data.get("country", "")
                res["org"] = data.get("org", "")
                res["loc"] = data.get("loc", "")
                res["status"] = "online"
    except Exception:
        pass

    # 2. Fallback: api.ipify.org
    if not res["ip"]:
        try:
            req = urllib.request.Request("https://api.ipify.org?format=json", headers={"User-Agent": "curl/8.0.0"})
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if data.get("ip"):
                    res["ip"] = data.get("ip", "").strip()
                    res["status"] = "online"
        except Exception:
            pass

    # 3. Fallback: icanhazip.com
    if not res["ip"]:
        try:
            req = urllib.request.Request("https://icanhazip.com", headers={"User-Agent": "curl/8.0.0"})
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                ip = resp.read().decode("utf-8").strip()
                if ip:
                    res["ip"] = ip
                    res["status"] = "online"
        except Exception:
            pass

    # Save cache if successful
    if res["ip"]:
        try:
            os.makedirs(CACHE_DIR, exist_ok=True)
            with open(PUBLIC_CACHE_FILE, "w") as cf:
                json.dump(res, cf)
        except Exception:
            pass
    elif use_cache_fallback and os.path.isfile(PUBLIC_CACHE_FILE):
        # Stale cache fallback if available
        try:
            with open(PUBLIC_CACHE_FILE, "r") as cf:
                cached = json.load(cf)
                if cached.get("ip"):
                    cached["fromCache"] = True
                    cached["status"] = "stale"
                    return cached
        except Exception:
            pass

    return res

def main():
    mode = "--local"
    if len(sys.argv) > 1:
        mode = sys.argv[1]

    if mode == "--local":
        print(json.dumps(get_local_info()))
    elif mode == "--public":
        print(json.dumps(get_public_info(use_cache_fallback=False)))
    elif mode == "--public-cached":
        print(json.dumps(get_public_info(use_cache_fallback=True)))
    elif mode == "--all":
        out = {
            "local": get_local_info(),
            "public": get_public_info(use_cache_fallback=True)
        }
        print(json.dumps(out))
    else:
        print(json.dumps(get_local_info()))

if __name__ == "__main__":
    main()
