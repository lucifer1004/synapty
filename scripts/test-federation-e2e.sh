#!/usr/bin/env bash
# Two hubs, one real relay link ([[RFC-0009]] C-DIRECTORY, C-DELIVERY).
#
# THIS IS A SHELL TEST BECAUSE THE PRODUCTION PATH IS THE THING UNDER TEST.
# Every unit test in this area builds a directory by calling
# `directoryAdvertise` directly — which is precisely the function the
# identity-upgrade path does NOT call, so no unit test could see that peers
# never learnt a durable id. The tenth review found it by reading the call
# graph; this catches it by walking it.
#
# What it drives, in the order a real agent does: register under a pane id,
# upgrade with a resume_ref, and check the OTHER hub's view — the stale pane
# entry gone, the durable id present, and a cross-hub send to that durable
# name answered `forwarded`, which C-DELIVERY defines as the peer having
# acknowledged it.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=./zig-out/bin/synapty
[ -x "$BIN" ] || { echo "build first: zig build"; exit 1; }

ROOT=$(mktemp -d)
# Free ports, not fixed ones: two of these running at once — or one
# beside a developer's hub — must not collide ([[WI-2026-09-02-036]]).
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PA=$(free_port); PB=$(free_port)
while [ "$PB" = "$PA" ]; do PB=$(free_port); done
# The two hubs are ours and killing them is the ordinary end of this
# test, so the shell's job-control notice is silenced rather than left to
# read as a failure in `just verify`'s output.
cleanup() { kill %1 %2 2>/dev/null || true; wait %1 %2 2>/dev/null || true; rm -rf "$ROOT"; }
trap cleanup EXIT

mkdir -p "$ROOT/a" "$ROOT/b"
SYNAPTY_CONFIG_ROOT="$ROOT/a" SYNAPTY_HUB_PORT=$PA "$BIN" hub >"$ROOT/a.log" 2>&1 &
SYNAPTY_CONFIG_ROOT="$ROOT/b" SYNAPTY_HUB_PORT=$PB "$BIN" hub >"$ROOT/b.log" 2>&1 &
# A HUB THAT NEVER CAME UP MUST SAY SO. This loop used to fall through on
# timeout and let the driver connect to nothing, so a slow start surfaced
# as a ConnectionRefusedError traceback out of python — indistinguishable
# from federation being broken, and with both hub logs already deleted by
# the trap. It happened once in `just verify` and cost the time it took to
# prove the feature was fine.
up=""
for _ in $(seq 1 80); do
  if nc -z 127.0.0.1 $PA 2>/dev/null && nc -z 127.0.0.1 $PB 2>/dev/null; then
    up=yes; break
  fi
  sleep 0.25
done
if [ -z "$up" ]; then
  echo "the two hubs did not listen on $PA/$PB within 20s -- this is the harness, not federation" >&2
  echo "--- hub a ---" >&2; cat "$ROOT/a.log" >&2
  echo "--- hub b ---" >&2; cat "$ROOT/b.log" >&2
  exit 1
fi

python3 - "$PA" "$PB" <<'PY'
import socket, json, sys, time
PA, PB = int(sys.argv[1]), int(sys.argv[2])

def one(port, env, wait=0.5):
    s = socket.create_connection(('127.0.0.1', port))
    s.sendall((json.dumps(env)+"\n").encode())
    time.sleep(wait); s.settimeout(1.5)
    out = b""
    try:
        while True:
            b = s.recv(65536)
            if not b: break
            out += b
    except Exception: pass
    s.close(); return out.decode()

def agents(port):
    r = one(port, {"type":"list_agents","id":"la","source":"probe","target":"hub"})
    return json.loads(r.strip().split("\n")[0])["payload"]["agents"]

def fail(m): print("FAIL:", m); sys.exit(1)

one(PA, {"type":"peer_connect","id":"pc","source":"wb","target":"hub","payload":{"port":PB}})
time.sleep(1.5)
# The identity lives with its connection, so it is held open throughout.
a = socket.create_connection(('127.0.0.1', PA))
a.sendall((json.dumps({"type":"register","id":"r","source":"local-1a2b","target":"hub","payload":{}})+"\n").encode())
time.sleep(0.8)
before = [x["id"] for x in agents(PB)]
if "local-1a2b@" not in "".join(before):
    fail(f"the peer never learnt the pane id: {before}")

a.sendall((json.dumps({"type":"agent_update","id":"u","source":"local-1a2b","target":"hub",
    "payload":{"tool":"claude","project":"/p","session":"s",
               "resume_ref":"abc12345-dead-beef-cafe"}})+"\n").encode())
time.sleep(1.5)

if [x["id"] for x in agents(PA)] != ["claude-abc12345"]:
    fail(f"the upgrade did not take on the hosting hub: {agents(PA)}")

after = {x["id"]: x for x in agents(PB)}
if "claude-abc12345" not in after:
    fail(f"the peer never learnt the durable id -- the add half is missing: {list(after)}")
if any(k.startswith("local-1a2b") for k in after):
    fail(f"the peer kept a pane id this hub no longer hosts -- the remove half is missing: {list(after)}")
row = after["claude-abc12345"]
if not row.get("remote") or not row.get("hosting_peer"):
    fail(f"the relayed row does not say where it lives: {row}")

# THE CONSEQUENCE, which a directory listing does not prove.
peer = socket.create_connection(('127.0.0.1', PB))
peer.sendall((json.dumps({"type":"register","id":"rb","source":"probe-b","target":"hub","payload":{}})+"\n").encode())
time.sleep(0.4)
peer.sendall((json.dumps({"type":"dm","id":"m","source":"probe-b","target":"claude-abc12345",
                          "payload":{"text":"hi"}})+"\n").encode())
time.sleep(2.5); peer.settimeout(2)
out = b""
try:
    while True:
        chunk = peer.recv(65536)
        if not chunk: break
        out += chunk
except Exception: pass
out = out.decode()
if '"status":"forwarded"' not in out:
    fail(f"a send to the durable name was not forwarded: {out.strip()[:200]}")

a.close(); peer.close()
print("ok: the upgrade reaches the peer, both halves, and a send to it is forwarded")
PY
