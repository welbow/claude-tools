#!/usr/bin/env python3
"""claude-secret - Claude's client for OpenBao.

  claude-secret list [prefix]          names under kv/claude/<prefix>  (`list gated` for gated ones)
  claude-secret meta <name>            custom_metadata + versions (no values)
  claude-secret fields <name>          field names of the current version (no values)
  claude-secret get <name> <field>     print ONE value (no trailing newline)
  claude-secret status                 gated approvals held / pending
  claude-secret forget [gated/<name>]  drop approval(s) now (revokes them server-side)

<name> is relative to kv/claude/, e.g. `opnsense-ro`. Names starting with
`gated/` live in kv/claude-gated/ and need a human's approval (Control Group):

  get/fields gated/<name> [--reason "why"] [--wait SECS]
    1st call: files a request, sends an ntfy push with the accessor; the approver
              runs `bao-approve <accessor>` on the OpenBao host; exits 3 "pending"
    later:    once approved, works for the secret's `cache_ttl` metadata (default 30m,
              `0` = one use), counted from first use. Max 4h (policy). Each use is a
              fresh read; no value is ever written to disk - only the approval.

Use `get` inline so the value goes to the consumer, not the terminal:
  curl -H "Authorization: Bearer $(claude-secret get opnsense-ro key)" ...

Auth: AppRole `claude` (role-id + secret-id in ~/.claude/secrets/). The token is
cached in ~/.claude/secrets/bao-claude.token (same ACL: the user + SYSTEM only) and
re-issued when near expiry or rejected. Each gated request gets its OWN token
(stored with the approval in ~/.claude/secrets/gated/); forgetting the approval
revokes that token, which kills the approval in OpenBao too. Stdlib only.

Config: claude-tools.env next to this script (KEY=VALUE; see the example in the
repo). Environment variables of the same name override it (for testing).
"""
import json, os, re, ssl, sys, time, urllib.error, urllib.request


def load_config():
    cfg = {}
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude-tools.env")
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    for k in ("BAO_ADDR", "CLAUDE_SECRET_NTFY", "CLAUDE_SECRET_APPROVE_ON"):
        if os.environ.get(k):
            cfg[k] = os.environ[k]
    if not cfg.get("BAO_ADDR"):
        sys.exit(f"claude-secret: BAO_ADDR not set - create {path}")
    return cfg


CFG = load_config()
ADDR = CFG["BAO_ADDR"].rstrip("/")
NTFY = CFG.get("CLAUDE_SECRET_NTFY", "")          # full topic URL; empty = no push
APPROVE_ON = CFG.get("CLAUDE_SECRET_APPROVE_ON", "the OpenBao host")
SECRETS = os.path.join(os.path.expanduser("~"), ".claude", "secrets")
CA = os.path.join(SECRETS, "bao-ca.pem")
CACHE = os.path.join(SECRETS, "bao-claude.token")
GATED_DIR = os.path.join(SECRETS, "gated")
MOUNT, BASE, GBASE = "kv", "claude", "claude-gated"
DEFAULT_CACHE_TTL = 30 * 60
PENDING = 3                      # exit code: request filed, waiting for approval
CTX = ssl.create_default_context(cafile=CA)


class BaoError(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


def call(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{ADDR}/v1/{path}", data=data, method=method)
    if token:
        req.add_header("X-Vault-Token", token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=15) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        try:
            errs = json.loads(e.read()).get("errors") or []
        except Exception:
            errs = []
        raise BaoError(e.code, f"HTTP {e.code} on {path}: {'; '.join(errs) or e.reason}") from None


def read_file(name):
    with open(os.path.join(SECRETS, name), encoding="utf-8") as f:
        return f.read().strip()


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def fresh_login():
    auth = call("POST", "auth/approle/login",
                body={"role_id": read_file("bao-claude.role-id"),
                      "secret_id": read_file("bao-claude.secret-id")})["auth"]
    return auth["client_token"], int(time.time()) + int(auth["lease_duration"])


def token(force=False):
    if not force:
        try:
            with open(CACHE, encoding="utf-8") as f:
                tok = json.load(f)
            if tok["expires"] - time.time() > 120:
                return tok["token"]
        except (OSError, ValueError, KeyError):
            pass
    tok, exp = fresh_login()
    write_json(CACHE, {"token": tok, "expires": exp})
    return tok


def api(method, path):
    try:
        return call(method, path, token())
    except BaoError as e:
        if e.code != 403:
            raise
        return call(method, path, token(force=True))   # cached token revoked/expired early


def clean(name):
    name = (name or "").strip("/")
    if ".." in name.split("/"):
        sys.exit("bad name")
    return name


def split(name):
    """'gated/x' -> ('claude-gated', 'x'); 'x' -> ('claude', 'x')"""
    name = clean(name)
    if name == "gated" or name.startswith("gated/"):
        return GBASE, name[len("gated"):].strip("/")
    return BASE, name


# ---------- gated (Control Group) ----------

def parse_ttl(s):
    s = str(s).strip().lower()
    m = re.fullmatch(r"(\d+)\s*([smhd]?)", s)
    if not m:
        return DEFAULT_CACHE_TTL
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]


def state_path(name):
    return os.path.join(GATED_DIR, name.replace("/", "__") + ".json")


def load_state(name):
    try:
        with open(state_path(name), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def forget(name, st=None, quiet=False):
    st = st or load_state(name)
    if st:
        try:
            call("POST", "auth/token/revoke-self", st["req_token"])
        except (BaoError, urllib.error.URLError):
            pass                                   # already expired - fine
    try:
        os.remove(state_path(name))
        if not quiet:
            print(f"forgot approval for gated/{name}", file=sys.stderr)
    except OSError:
        pass


def notify(name, acc, reason, expires):
    msg = (f"Claude wants kv/claude-gated/{name}\n"
           f"Reason: {reason or '(none given)'}\n\n"
           f"CLI ({APPROVE_ON}, root):\nbao-approve {acc}\n\n"
           f"Web UI console (>_), review then approve:\n"
           f"write sys/control-group/request accessor={acc}\n"
           f"write sys/control-group/authorize accessor={acc}\n\n"
           f"Request expires {time.strftime('%H:%M', time.localtime(expires))}.")
    if not NTFY:
        print("claude-secret: no CLAUDE_SECRET_NTFY configured - tell the approver the accessor yourself",
              file=sys.stderr)
        return False
    req = urllib.request.Request(NTFY, data=msg.encode(), method="POST")
    req.add_header("Title", f"OpenBao approval: {name}")
    req.add_header("Tags", "key,robot")
    req.add_header("Priority", "high")
    req.add_header("Actions", f"view, Open OpenBao, {ADDR}/ui/")
    try:
        urllib.request.urlopen(req, timeout=10).read()
        return True
    except Exception as e:
        print(f"claude-secret: ntfy push failed ({e}) - tell the approver the accessor yourself", file=sys.stderr)
        return False


def new_request(name, reason):
    meta = api("GET", f"{MOUNT}/metadata/{GBASE}/{name}")["data"]   # 404 if no such secret
    cache_ttl = parse_ttl((meta.get("custom_metadata") or {}).get("cache_ttl", DEFAULT_CACHE_TTL))
    req_tok, tok_exp = fresh_login()
    w = call("GET", f"{MOUNT}/data/{GBASE}/{name}", req_tok).get("wrap_info")
    if not w:
        raise BaoError(0, "expected a Control Group request but got none - is the claude-gated policy attached?")
    now = int(time.time())
    st = {"name": name, "req_token": req_tok, "req_token_expires": tok_exp,
          "wrap_token": w["token"], "accessor": w["accessor"], "created": now,
          "server_expires": now + int(w["ttl"]), "cache_ttl": cache_ttl,
          "first_use": None, "reason": reason}
    os.makedirs(GATED_DIR, exist_ok=True)
    write_json(state_path(name), st)
    notify(name, w["accessor"], reason, st["server_expires"])
    return st


def renew_req_token(st):
    try:
        a = call("POST", "auth/token/renew-self", st["req_token"], {"increment": "1h"})["auth"]
        st["req_token_expires"] = int(time.time()) + int(a["lease_duration"])
    except (BaoError, KeyError):
        pass


def try_unwrap(st):
    try:
        return call("POST", "sys/wrapping/unwrap", st["wrap_token"])
    except BaoError as e:
        if e.code == 400 and "not valid" in str(e):
            return None
        raise


def gated_read(name, reason="", wait=0):
    st = load_state(name)
    now = time.time()
    if st:
        used_out = st["first_use"] is not None and now > st["first_use"] + st["cache_ttl"]
        dead = now > st["server_expires"] or now > st["req_token_expires"]
        if used_out or dead:
            forget(name, st, quiet=True)
            st = None
    if not st:
        st = new_request(name, reason)
        print(f"claude-secret: requested approval for gated/{name} - "
              f"approver runs `bao-approve {st['accessor']}` on {APPROVE_ON}", file=sys.stderr)
    deadline = time.time() + wait
    while True:
        res = try_unwrap(st)
        if res is not None:
            break
        if st["first_use"] is not None:            # worked before, now dead server-side
            forget(name, st, quiet=True)
            sys.exit(f"claude-secret: approval for gated/{name} has expired - run again to re-request")
        renew_req_token(st)                        # keep the pending request alive
        write_json(state_path(name), st)
        if time.time() >= deadline:
            print(f"claude-secret: gated/{name} pending approval (accessor {st['accessor']})", file=sys.stderr)
            sys.exit(PENDING)
        time.sleep(5)
    if st["first_use"] is None:
        st["first_use"] = int(time.time())
    renew_req_token(st)
    if st["cache_ttl"] == 0:
        forget(name, st, quiet=True)               # one use only
    else:
        write_json(state_path(name), st)
    return res["data"]["data"]


def status():
    if not os.path.isdir(GATED_DIR):
        return
    now = time.time()
    for f in sorted(os.listdir(GATED_DIR)):
        if not f.endswith(".json"):
            continue
        with open(os.path.join(GATED_DIR, f), encoding="utf-8") as fh:
            st = json.load(fh)
        if st["first_use"] is None:
            print(f"gated/{st['name']}: PENDING  accessor {st['accessor']}  "
                  f"(request dies in {int((st['server_expires'] - now) / 60)}m)")
        else:
            left = min(st["first_use"] + st["cache_ttl"], st["server_expires"], st["req_token_expires"]) - now
            print(f"gated/{st['name']}: approved, {max(0, int(left / 60))}m left")


# ---------- main ----------

def take_opt(args, opt, default):
    if opt in args:
        i = args.index(opt)
        if i + 1 >= len(args):
            sys.exit(f"{opt} needs a value")
        v = args[i + 1]
        del args[i:i + 2]
        return v
    return default


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip()); return 0
    cmd, args = argv[0], list(argv[1:])
    reason = take_opt(args, "--reason", "")
    wait = int(take_opt(args, "--wait", "0"))
    if cmd == "list":
        base, prefix = split(args[0] if args else "")
        p = f"{MOUNT}/metadata/{base}/{prefix}".rstrip("/")
        try:
            keys = api("LIST", p)["data"]["keys"]
        except BaoError as e:
            if e.code == 404:
                return 0            # nothing there yet
            raise
        print("\n".join(keys)); return 0
    if cmd == "status":
        status(); return 0
    if cmd == "forget":
        if args:
            base, name = split(args[0])
            forget(name)
        elif os.path.isdir(GATED_DIR):
            for f in os.listdir(GATED_DIR):
                if f.endswith(".json"):
                    forget(f[:-5].replace("__", "/"))
        return 0
    if cmd in ("meta", "fields", "get") and args:
        base, name = split(args[0])
        if cmd == "meta":
            d = api("GET", f"{MOUNT}/metadata/{base}/{name}")["data"]
            print(json.dumps({"custom_metadata": d.get("custom_metadata"),
                              "current_version": d.get("current_version"),
                              "updated_time": d.get("updated_time")}, indent=2)); return 0
        if base == GBASE:
            data = gated_read(name, reason, wait)
        else:
            data = api("GET", f"{MOUNT}/data/{base}/{name}")["data"]["data"]
        if cmd == "fields":
            print("\n".join(sorted(data))); return 0
        if len(args) != 2:
            sys.exit("usage: claude-secret get <name> <field>")
        if args[1] not in data:
            sys.exit(f"no field '{args[1]}' in {args[0]} (fields: {', '.join(sorted(data))})")
        sys.stdout.write(str(data[args[1]])); return 0
    sys.exit(__doc__.strip())


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BaoError as e:
        sys.exit(f"claude-secret: {e}")
    except urllib.error.URLError as e:
        sys.exit(f"claude-secret: cannot reach {ADDR}: {e.reason}")
