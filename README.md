# claude-tools

Small tools that give an AI coding agent (Claude Code) **scoped, audited,
approval-gated access to secrets in [OpenBao](https://openbao.org)**, instead
of plaintext `.env` files.

- **`windows/claude-secret`**: the agent's OpenBao client (stdlib Python 3).
  It logs in with an AppRole, reads `kv/claude/*` freely, and for
  `kv/claude-gated/*` files a **Control Group** request. It pushes the request
  to an ntfy topic and waits for a human to approve it.
- **`openbao-host/bao-*`**: admin commands for the Docker host running OpenBao:
  `bao-login`, `bao`, `bao-logout`, and **`bao-approve <accessor>`**.
  `bao-approve` shows what OpenBao stored for a request and asks before
  approving it.
- **`windows/tandoor-*.sh`**: example consumers, read-only lookups against a
  Tandoor recipe server using a credential from OpenBao.

## How a gated read works

```
agent: claude-secret get gated/tandoor-rw token --reason "import 3 recipes"
       -> OpenBao stores the request, returns a wrapping token + accessor
       -> ntfy push: "Claude wants kv/claude-gated/tandoor-rw ... bao-approve <accessor>"
human: bao-approve <accessor>        (or the OpenBao web UI console)
agent: claude-secret get gated/tandoor-rw token     -> value
```

- Once approved, the wrapping token can be unwrapped again until it expires,
  and each unwrap is a fresh read. The helper therefore stores only the
  approval and never the value. It drops the approval after the secret's
  `cache_ttl` metadata (default 30m, `0` = one use).
- OpenBao enforces the hard limits: the policy's control-group `ttl`, and the
  lifetime of the token that made the request. `claude-secret forget` revokes
  that token, which kills the approval server-side.
- **OpenBao 2.7.2 gotcha:** a control-group factor *must* set
  `controlled_capabilities`, although the docs say it is optional.

Example policy for the gated path:

```hcl
path "kv/data/claude-gated/*" {
  capabilities = ["read"]
  control_group = {
    ttl = "4h"
    factor "approver" {
      controlled_capabilities = ["read"]
      identity {
        group_names = ["claude-approvers"]
        approvals   = 1
      }
    }
  }
}
path "kv/metadata/claude-gated/*" { capabilities = ["read", "list"] }
```

## Install and upgrade

Both installers refuse uncommitted changes, show the commits since the last
install and ask before installing, and record the deployed commit. Upgrading
means pulling or committing in the repo, then running the installer again and
reading what it shows you.

The installers assume the agent may have write access to the repo, so they
trust only what is already installed or owned by root/Administrators (details
below). Review what they show before saying yes.

**Windows** (agent side). This needs `C:\Program Files\Python312`; adjust the
two wrappers if yours differs.

1. Copy `windows/claude-tools.env.example` to `windows/claude-tools.env` and
   fill it in (gitignored).
2. Put the AppRole `bao-claude.role-id` / `bao-claude.secret-id` and the
   OpenBao CA `bao-ca.pem` in `%USERPROFILE%\.claude\secrets\`. Restrict that
   folder to the user and SYSTEM.
3. From an **elevated** PowerShell, run `windows\deploy.ps1` (first install).
4. For upgrades, run the **installed** copy, `C:\Program Files\claude-tools\deploy.ps1`.
   It can't be edited without elevation, finds the repo through the
   admin-owned `REPO` file, and installs the committed tree (`git archive HEAD`).
   It runs git with fsmonitor, hooks, the pager and external diff disabled, so
   repo config can't run code elevated.

It installs to `C:\Program Files\claude-tools\{bin,scripts}`. The files
inherit Program Files' ACL (Users: read and execute), so the unelevated user
can run the tools, and so can an agent running as that user, but neither can
change them. Changes only reach the installed copy through a reviewed commit
and an elevated deploy.

This is tamper resistance, not a sandbox: the agent can still read its own
AppRole credentials. The real boundary is OpenBao's policy and the human
approval.

**OpenBao host** (as root):

```bash
git clone <repo-url> /root/src/claude-tools                # must be root-owned
cd /root/src/claude-tools
cp openbao-host/bao-tools.example openbao-host/bao-tools   # fill in (or keep an existing /etc/default/bao-tools)
openbao-host/install.sh                                    # -> /root/bin, /etc/default/bao-tools
# upgrade: git pull && openbao-host/install.sh
```

`install.sh` refuses a checkout with any file not owned by root, because a
non-root user who could write there could change what root installs or plant
git config that runs as root.

## Changing the tools

- Change the repo, never the installed copies. They're write-protected on
  purpose, so don't loosen their ACLs or ownership to "fix" something. Commit,
  have a human review, then rerun the installer as above.
- The repo is mirrored publicly, so **site details never get committed**:
  hostnames, IPs, usernames and paths go in the gitignored per-site config
  (see the `*.example` files). Before every push, scan what's leaving for your
  own domains and private address ranges:

  ```bash
  git diff @{u}..HEAD | grep -inE '<your-domain>|<your-other-domain>|192\.168\.|10\.[0-9]+\.'
  ```

  No output means it's clean.

## License

MIT
