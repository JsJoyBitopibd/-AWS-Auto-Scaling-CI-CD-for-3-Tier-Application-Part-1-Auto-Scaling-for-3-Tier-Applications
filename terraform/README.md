# Terraform audit — "is everything we built still there?"

The course account reclaims servers after a while. Before continuing the assignment
we need to know **exactly which pieces of the Part 1 / Part 2 stack still exist** and
which have to be rebuilt by hand. This folder is a small Terraform program that does
that check.

**It is read-only.** There is not a single `resource` block in it, so `terraform apply`
cannot create, change or delete anything in AWS — it can only *describe* what is there.
It needs nothing more than the `Describe*` permissions the console already uses.

| File | What it is |
|---|---|
| `main.tf` | Terraform + AWS-provider versions, region (`ap-south-1`) and the resource names (`bitopi-…`) to look for |
| `audit.tf` | The lookups, the PRESENT / MISSING checks and the printed report |

## What it checks

| # | Resource | How it is found | Built in |
|---|---|---|---|
| 1 | VPC `bitopi-vpc` | tag `Name` | Part 1 – Step 1 |
| 2 | 4 subnets `bitopi-subnet-*` (2 public, 2 private) | tag `Name` | Part 1 – Step 1 |
| 3 | Security groups `bitopi-alb-sg`, `bitopi-backend-sg`, `bitopi-db-sg` | group name | Part 1 – Step 2 |
| 4 | Key pair `bitopi-key` | key name | Part 1 – Step 2 |
| 5 | DB server `bitopi-db-server` (+ its **private IP** = `DB_HOST`) | tag `Name` | Part 1 – Step 3 |
| 6 | Launch template `bitopi-app-lt` — and that it has **version 2** (the pull-based deployer) | name | Part 1 – Step 4 / Part 2 – Step 2 |
| 7 | Target group `bitopi-app-tg` — HTTP 3000, health check `/health` | name | Part 1 – Step 5 |
| 8 | ALB `bitopi-alb` (+ its DNS name) and **which target group the :80 listener sends traffic to** | name | Part 1 – Step 5 |
| 9 | Auto Scaling Group `bitopi-app-asg` (min / desired / max, LT version) | name | Part 1 – Step 6 |
| 10 | *(Blue/Green only)* `bitopi-app-tg-green`, `bitopi-app-asg-green` | name | Part 2 – Step 6 |

## How to run it on Windows — step by step

### Step 1 — Install Terraform (once)

Open **PowerShell** (not cmd) and run:

```powershell
winget install --id HashiCorp.Terraform -e
```

Close PowerShell, open a **new** one, and confirm:

```powershell
terraform -version
```

You need **1.5 or newer** (winget installs the latest). If `winget` is not available: download the
Windows AMD64 zip from https://developer.hashicorp.com/terraform/install, unzip `terraform.exe`
into `C:\terraform\`, and add `C:\terraform` to your PATH (*Settings → System → About →
Advanced system settings → Environment Variables → Path → New*). Open a new PowerShell and
check `terraform -version` again.

### Step 2 — Give Terraform a way to log in to AWS

There is no CloudShell in this account, so Terraform must run from your PC with an **access key**.
Do **one** of these:

**Option A — you log in to the console with an IAM user name and password.**
Console → search **IAM** → *Users* → click **your own user** → tab **Security credentials** →
*Access keys* → **Create access key** → choose *Command Line Interface (CLI)* → tick the
confirmation → **Create access key** → copy the *Access key* and *Secret access key* (or
*Download .csv*). If this is refused (`iam:CreateAccessKey` denied), ask the course admin for an
access key — there is no other way to run Terraform (or the AWS CLI) from your PC.

**Option B — you log in through an AWS access-portal page (IAM Identity Center / SSO).**
On the portal, next to the account, click **Access keys** → tab *PowerShell* → it shows three
`$env:…` lines already filled in (they expire after a few hours; just repeat this step when they do).

Then, in the PowerShell window you will use for Terraform, paste (with your real values):

```powershell
$env:AWS_ACCESS_KEY_ID     = "AKIA................"
$env:AWS_SECRET_ACCESS_KEY = "...................................."
$env:AWS_DEFAULT_REGION    = "ap-south-1"
# only for Option B (temporary credentials) - also paste the third line the portal gives you:
# $env:AWS_SESSION_TOKEN   = "...."
```

These live only in that window and disappear when you close it. **Never** put the keys in a file
inside the repository — `.gitignore` already blocks `*.tfstate` and `.terraform/`, but the keys
must never be typed into any file at all.

### Step 3 — Run the audit

```powershell
cd E:\DevSecOps\Assignments\9_Module_Assignment\terraform
terraform init          # downloads the AWS provider (once, ~100 MB)
terraform apply -auto-approve
```

`apply` is safe here: with zero resources it only *reads* AWS and stores what it found. It ends with
`Apply complete! Resources: 0 added, 0 changed, 0 destroyed.` followed by the outputs.
To see just the report again at any time:

```powershell
terraform output audit_summary
terraform output            # all values: db_private_ip, alb_url, subnet ids, sg ids, ASG sizes ...
```

(`terraform plan` also works and prints the same warnings, but does not save the outputs.)

### Step 4 — Read the result

Two things appear in the output:

1. **Warnings** at the top (yellow). Each warning names a `check "…"` block:
   * `Check block data source read failed` → that resource is **MISSING** (key pair, launch
     template or a target group could not be found).
   * `Check block assertion failed` + a message → the resource is missing, or exists with the wrong
     settings; the message says what and which Part/Step rebuilds it.
   * The warning for `target_group_green_optional` is **expected** until the Blue/Green step is done.
   * **No warning** for a check = that resource is present and correct.
2. The **`audit_summary`** box — one line per resource with `PRESENT` / `MISSING`, plus the values
   you need next: the DB server's private IP (this is `DB_HOST` in the launch-template user-data),
   the ALB URL, the ASG sizes and launch-template version, and which target group the listener is
   sending traffic to (blue or green).

Example of a stack where the servers were reclaimed but the network survived:

```
      VPC bitopi-vpc ........................ PRESENT
      4 subnets bitopi-subnet-* ........ PRESENT   (found 4)
      3 security groups ........................ PRESENT   (found 3: bitopi-alb-sg, bitopi-backend-sg, bitopi-db-sg)
      DB server bitopi-db-server ............ MISSING
      ALB bitopi-alb ............................ MISSING
      listener :80 currently forwards to ......... -
      ASG bitopi-app-asg (blue) ................ MISSING
      ASG bitopi-app-asg-green (green) .......... MISSING   (only needed for the Blue/Green step)
```

Take a screenshot of the whole PowerShell output → `SS/TF-01-terraform-audit-before.png`.

### Step 5 — Rebuild what is missing, by hand, in this order

Everything is rebuilt in the console exactly as documented; the order matters because each piece
references the previous one.

| If this is MISSING | Do this | Instructions |
|---|---|---|
| VPC / subnets | *VPC and more* wizard, name `bitopi`, 2 AZs, 2 public + 2 private subnets | `docs/part1-auto-scaling.md` §4 Step 1 |
| Security groups | `bitopi-alb-sg` → `bitopi-backend-sg` → `bitopi-db-sg` (in that order, each rule points at the previous group) | Part 1 §4 Step 2 |
| Key pair | `bitopi-key`, .pem, then run `scripts/fix-ssh-key-permissions-windows.ps1` | Part 1 §4 Step 2 |
| DB server | EC2 `bitopi-db-server`, t3.micro, AL2023, public subnet 1, `bitopi-db-sg`, user-data = `scripts/db-server-userdata.sh`. **Note the new private IP.** | Part 1 §4 Step 3 |
| Launch template | If the DB IP changed: edit `DB_HOST=` in `scripts/app-server-userdata-v2-blue.sh` **and** `-v3-green.sh`, commit. Create `bitopi-app-lt` with the v2-blue script as user-data (make it the default version) | Part 1 §4 Step 4 + Part 2 Step 2 |
| Target group | `bitopi-app-tg`, HTTP 3000, health `/health` | Part 1 §4 Step 5 |
| ALB | `bitopi-alb`, internet-facing, both public subnets, `bitopi-alb-sg`, listener 80 → `bitopi-app-tg` | Part 1 §4 Step 5 |
| ASG | `bitopi-app-asg`, LT **Default** version, both public subnets, attach `bitopi-app-tg`, ELB health checks, min 2 / desired 2 / max 4, target-tracking CPU 30 % | Part 1 §4 Step 6 + §5 |

If the DB IP changed **and** the launch template still exists, do not edit v2 — create a **new
version** of the LT with the corrected user-data and set it as default, then *Instance refresh* the ASG.

### Step 6 — Run the audit again

```powershell
terraform apply -auto-approve
terraform output audit_summary
```

Every line must read `PRESENT` and the only warning left must be `target_group_green_optional`.
Screenshot → `SS/TF-02-terraform-audit-after.png`. Then continue with the Blue/Green runbook in
`docs/part2-cicd.md` §7 — after the switch, `terraform output listener_forwards_to` shows
`bitopi-app-tg-green`, and after the rollback it shows `bitopi-app-tg` again (nice evidence for the
rollback test).

### Cleaning up

`terraform destroy` has nothing to destroy (no resources) — it only clears the local state file. The
AWS resources are deleted by hand using the checklist in `docs/part2-cicd.md` §8. When you are
done, delete the access key you created in Step 2 (IAM → your user → Security credentials).

## Troubleshooting (seen in real use)

| Symptom | Cause | Fix |
|---|---|---|
| `lookup sts.ap-south-1.amazonaws.com: no such host` | the PC's DNS server did not answer (office DNS hiccup) | `ipconfig /flushdns`, check with `nslookup sts.ap-south-1.amazonaws.com`, retry `apply` |
| `terraform output` shows an old value | `output` never contacts AWS — it prints what the last **successful** `apply` saved in `terraform.tfstate` | only trust outputs after an `apply` that ended with `Apply complete!` |
| `No valid credential sources found` | the `$env:AWS_...` lines live only in the PowerShell window they were typed in | paste them again in the new window |
| green target shows *Unused* in the console | a target group is only health-checked when a listener forwards to it | add the `:8080` test listener (docs/part2-cicd.md §5 Step 6.2) |

## Why Terraform can report "missing" instead of crashing

Normally a Terraform data source **aborts the whole run** when the thing it looks for does not
exist. Two techniques avoid that here:

* **Plural data sources** (`aws_vpcs`, `aws_subnets`, `aws_security_groups`, `aws_instances`,
  `aws_lbs`, `aws_autoscaling_groups`) return an *empty list* instead of an error, so the report
  can say `MISSING` and still print everything else.
* **`check` blocks** (Terraform ≥ 1.5) may contain one *scoped* data source. If that lookup fails,
  Terraform prints a **warning** and carries on instead of stopping. This is how the key pair,
  launch template and target groups are checked, because they only have singular data sources.
