# How the Servers Talk to Each Other

This guide follows one request through the whole system and shows, at every hop, **who** talks to **whom**, on **which port**, **which firewall rule** allows it, and **which command** you can run to see it happen. Every command below was run on this project's real servers.

Two ideas make all of it work:

- **Security groups reference each other, not IP addresses.** `bitopi-backend-sg` allows port 3000 *from `bitopi-alb-sg`* — meaning "from anything wearing the ALB's security group". That rule never has to change when instances come and go.
- **Security groups are stateful.** If a connection is allowed *in*, its reply is automatically allowed *out*. So we only write inbound rules, and every "vice versa" below is the reply traffic of an allowed inbound connection — no extra rule needed.

## The map

```
 You (browser / curl)                                   Admin (PowerShell)
        │  HTTP :80                                             │  SSH :22
        ▼                                                       ▼
 ┌─────────────────┐  HTTP :3000 (+ GET /health every 15s)  ┌────────────────────┐   MySQL :3306   ┌────────────────────┐
 │  bitopi-alb     │ ─────────────────────────────────────▶ │  Backend EC2 (x2-4)│ ──────────────▶ │  bitopi-db-server  │
 │  (ALB, 2 AZs)   │ ◀───────────────────────────────────── │  Node.js :3000     │ ◀────────────── │  MariaDB :3306     │
 └─────────────────┘        reply (stateful)                └────────────────────┘  reply (stateful)└────────────────────┘
                                                                   │  ▲
                                                 HTTP :80 (IMDSv2) │  │ metadata: instance-id, AZ
                                                                   ▼  │
                                                          169.254.169.254 (inside AWS)

 CloudWatch alarm ──▶ Auto Scaling Group ──▶ launches / terminates backend EC2  (control plane, no ports)
```

The backend servers **never talk to each other**. They are stateless twins; the only thing they share is the database. That is deliberate — it is what lets the Auto Scaling Group add or remove them freely.

---

## Hop 1 — Browser → Load Balancer (port 80)

| | |
|---|---|
| From → to | your laptop → `bitopi-alb` |
| Port / protocol | 80 / HTTP |
| Address | `bitopi-alb-1957667478.ap-south-1.elb.amazonaws.com` (a DNS name; AWS maps it to one ALB node per AZ) |
| Allowed by | `bitopi-alb-sg` inbound: HTTP 80 from `0.0.0.0/0` |

The ALB is the **only** component with a rule that says "from anywhere". Everything behind it is invisible to the internet.

**See it (from your laptop, PowerShell):**

```powershell
# Which IPs does the ALB name resolve to? (one per AZ — that's the multi-AZ front door)
nslookup bitopi-alb-1957667478.ap-south-1.elb.amazonaws.com

# Send a request and see only the response headers
curl.exe -I http://bitopi-alb-1957667478.ap-south-1.elb.amazonaws.com/

# Hit it 6 times; the instance ID in the page changes as the ALB rotates between servers
1..6 | ForEach-Object { (curl.exe -s http://bitopi-alb-1957667478.ap-south-1.elb.amazonaws.com/ | Select-String 'i-0[0-9a-f]+').Matches.Value }

# Prove the backend is NOT reachable directly on port 3000 from the internet (times out - the firewall works)
curl.exe -m 5 http://<any-backend-public-ip>:3000/
```

---

## Hop 2 — Load Balancer → Backend EC2 (port 3000) — and back

| | |
|---|---|
| From → to | ALB node → a backend instance |
| Port / protocol | 3000 / HTTP |
| Address | the instance's **private** IP (e.g. `10.0.23.139`), registered in target group `bitopi-app-tg` |
| Allowed by | `bitopi-backend-sg` inbound: TCP 3000 **from `bitopi-alb-sg`** |
| Vice versa | the reply is the same TCP connection → allowed by statefulness |

This hop carries two kinds of traffic:

1. **User requests** — forwarded to a healthy instance chosen round-robin.
2. **Health checks** — every 15 s the ALB itself calls `GET /health` on *every* registered instance. Two failures in a row → the instance is marked *unhealthy* and stops receiving user traffic. Two passes → healthy again.

**See it (SSH into any backend instance):**

```bash
# 1) Is the app listening on 3000?
sudo ss -tlnp | grep 3000
#   LISTEN 0 511 *:3000 *:* users:(("node",pid=...))

# 2) Call the two routes exactly as the ALB does
curl -s http://localhost:3000/health          # → {"status":"healthy","instance":"i-...","az":"ap-south-1b"}
curl -s http://localhost:3000/ | head -20      # the HTML page

# 3) Watch the ALB's health checks arriving in real time (the source IPs are the ALB's private IPs)
sudo journalctl -u bitopi-app -f
#   or, at the network level:
sudo tcpdump -ni any port 3000 -c 10

# 4) Which security group is on this instance, and what does it allow?
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/security-groups
#   bitopi-backend-sg
```

**Why the health check is shallow.** `/health` only proves the Node process is alive; it does not query the database. If it did, a 10-second database hiccup would make *every* instance fail at once, the ALB would have nowhere to send traffic, and the ASG would start replacing perfectly good servers. Keep liveness checks cheap; show deeper status on a separate page (which is what `/` does).

---

## Hop 3 — Backend EC2 → Database (port 3306) — and back

| | |
|---|---|
| From → to | any backend instance → `bitopi-db-server` |
| Port / protocol | 3306 / MySQL protocol |
| Address | **private IP `10.0.13.216`** — never the public one; traffic stays inside the VPC |
| Allowed by | `bitopi-db-sg` inbound: MySQL 3306 **from `bitopi-backend-sg`** |
| Vice versa | query results come back on the same connection → statefulness. The database **never initiates** a connection to anything. |

In the app this hop is one line of configuration (`DB_HOST=10.0.13.216` in `/opt/app/.env`) and a few lines of code using the `mysql2` driver:

```js
const conn = await mysql.createConnection({ host: process.env.DB_HOST, user: 'appuser', ... });
await conn.execute('INSERT INTO visits (hostname) VALUES (?)', [os.hostname()]);
const [rows] = await conn.query('SELECT info FROM app_info WHERE id=1');
```

**See it (SSH into a backend instance):**

```bash
# 1) Can I even reach the database port? (network + firewall test, no credentials needed)
nc -zv 10.0.13.216 3306
#   Connection to 10.0.13.216 3306 port [tcp/mysql] succeeded!

# 2) Install the MySQL client and run a real query as the app user
sudo dnf install -y mariadb105
mysql -h 10.0.13.216 -u appuser -p'Bitopi#Db2026' appdb -e "SELECT * FROM app_info; SELECT COUNT(*) AS visits FROM visits;"

# 3) See the app's own connection config
cat /opt/app/.env

# 4) Watch the live connections from this server to the DB
sudo ss -tn | grep 10.0.13.216:3306
```

**See it from the other side (SSH into `bitopi-db-server`):**

```bash
# The database listens on all interfaces (we set bind-address=0.0.0.0)
sudo ss -tlnp | grep 3306

# Who is connected right now? (the Host column shows backend private IPs)
sudo mysql -e "SELECT user, host, db, command FROM information_schema.processlist;"

# Every row the backends have written
sudo mysql -e "SELECT * FROM appdb.visits ORDER BY id DESC LIMIT 10;"
```

**Proof the firewall is doing its job:** run `nc -zv 10.0.13.216 3306` from the **ALB's** point of view is impossible (ALBs can't run commands), but from your **laptop** it times out — port 3306 is not open to the internet, only to `bitopi-backend-sg`.

---

## Hop 4 — Backend EC2 → Instance Metadata Service (IMDSv2)

| | |
|---|---|
| From → to | an instance → `169.254.169.254` (a link-local address that exists inside every EC2) |
| Port / protocol | 80 / HTTP, **IMDSv2** = token first, then queries |
| Allowed by | nothing to allow — it never leaves the host; security groups don't apply |

This is how a freshly launched server learns *who it is* without anyone telling it. The user-data script uses it to stamp the instance-ID and AZ into the app's config — which is why the web page can show "Served by instance `i-…` in `ap-south-1b`".

```bash
# Step 1: get a short-lived token (IMDSv2 requires this; the instance was launched with "IMDSv2: Required")
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")

# Step 2: ask questions with the token
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/user-data | head -20   # the script that built this server
```

---

## Hop 5 — Backend EC2 → the Internet (package downloads)

| | |
|---|---|
| From → to | an instance → `dnf` mirrors, `registry.npmjs.org` |
| Path | instance's public IP → public route table → `bitopi-igw` → internet |
| Allowed by | outbound rule "all traffic" (default) + the subnet has a route `0.0.0.0/0 → igw` |

This is the one reason the backend sits in a *public* subnet in this lab: with no NAT Gateway, a private subnet has no path out, and `dnf install nodejs` / `npm install` would hang. The inbound firewall still blocks everything except the ALB and SSH.

```bash
# Route table as seen from the instance: the default route goes via the subnet gateway → IGW
ip route
# Prove outbound works
curl -sI https://registry.npmjs.org/ | head -1
# The first-boot log shows the downloads that happened
sudo tail -40 /var/log/user-data.log
```

---

## Hop 6 — Admin → any EC2 (SSH, port 22)

| | |
|---|---|
| From → to | your laptop → an instance's **public** IP |
| Port / protocol | 22 / SSH, key-based auth only |
| Allowed by | `bitopi-backend-sg` / `bitopi-db-sg` inbound: SSH 22 |

```powershell
# Windows: fix the key's permissions once (see scripts/fix-ssh-key-permissions-windows.ps1), then:
ssh -i bitopi-key.pem ec2-user@<public-ip>

# Copy a file to a server / back
scp -i bitopi-key.pem myfile.txt ec2-user@<public-ip>:/tmp/
scp -i bitopi-key.pem ec2-user@<public-ip>:/var/log/user-data.log .
```

Backend servers **can** SSH to each other too (same key, same security group would need a rule for 22 from `bitopi-backend-sg`) — but nothing in this design needs it, and adding it would only widen the attack surface.

---

## Hop 7 — The control plane: CloudWatch → Auto Scaling Group → EC2

This hop has **no ports and no security groups** — it is AWS services talking to AWS services on your behalf.

1. Every instance's hypervisor reports **CPUUtilization** to CloudWatch (no agent needed for this metric).
2. The target-tracking policy created two alarms: `TargetTracking-bitopi-app-asg-AlarmHigh-…` and `…-AlarmLow-…`.
3. When the group average crosses 30 %, the alarm enters `ALARM` and **calls the Auto Scaling Group**.
4. The ASG computes the new desired capacity and calls **EC2 RunInstances** with the Launch Template (or terminates the instance it selects).
5. The ASG **registers / deregisters** the instance with the Target Group, so the ALB starts / stops sending it traffic. On termination it waits for **connection draining** first.

You can watch all of this in the ASG **Activity** tab — every line quotes the alarm name and the reason.

---

## Quick reference: who can talk to whom

| From \ To | ALB :80 | Backend :3000 | Backend :22 | DB :3306 | DB :22 |
|---|---|---|---|---|---|
| Internet | ✅ | ❌ | ✅ (key required) | ❌ | ✅ (key required) |
| ALB | — | ✅ | ❌ | ❌ | ❌ |
| Backend EC2 | ✅ (via public DNS) | ❌ (not needed) | ❌ (no rule) | ✅ | ❌ |
| Database EC2 | ✅ (via public DNS) | ❌ | ❌ | — | — |

Every ✅ is one inbound rule in one of the three security groups. Every reply travels back through statefulness. That table *is* the architecture.
