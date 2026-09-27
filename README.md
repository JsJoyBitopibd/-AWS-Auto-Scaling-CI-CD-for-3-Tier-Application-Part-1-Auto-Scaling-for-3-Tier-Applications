# AWS Auto Scaling & CI/CD for a 3-Tier Application

| | |
|---|---|
| **Student** | Joyanta Sarker Joy |
| **Course** | Mastering DevOps — Batch 13 |
| **Module** | 9 — AWS Auto Scaling & CI/CD |
| **AWS Region** | Asia Pacific (Mumbai) — `ap-south-1` |

## What this project does

**Part 1** converts a backend that ran on a single EC2 instance into a **highly available, auto-scaling, self-healing** 3-tier architecture: an Application Load Balancer in front, a fleet of backend servers managed by an Auto Scaling Group across two Availability Zones, and a MySQL database tier behind a locked-down firewall.

**Part 2** adds an automated **CI/CD pipeline** (Source → Build → Test → Deploy) that ships new versions of the backend to the auto-scaling fleet, proves that freshly launched servers configure themselves automatically, and finishes with a **Blue/Green deployment** plus a tested **rollback**.

## How Part 2 was built without IAM roles

The account cannot create IAM roles, which CodePipeline, CodeBuild and CodeDeploy all require. The pipeline therefore uses **GitHub Actions** (Source → Build → Test → Package → Release) and a **pull-based deployer** on every server (`scripts/deploy.sh`, run by a `systemd` timer every 60 s and at first boot). A `git push` reaches the whole fleet in under two minutes with no AWS credentials anywhere; new Auto Scaling instances fetch the current release before their first health check. Blue/Green is a second target group + Auto Scaling Group pinned to a *candidate* release, switched by the ALB listener. Details and evidence: [Part 2](docs/part2-cicd.md).

## Architecture

![Part 1 — 3-tier auto scaling architecture](diagrams/part1_architecture.png)

Request flow: **① Browser → ALB (:80)** → **② ALB → healthy backend EC2 (:3000, health-checked on `/health`)** → **③ Backend → MySQL (:3306)**.

## Documentation

| Document | What it covers |
|---|---|
| [Part 1 — Auto Scaling for 3-Tier Applications](docs/part1-auto-scaling.md) | VPC, security groups, database tier, Launch Template, Target Group, ALB, Auto Scaling Group, health checks, self-healing test, scaling policy + load test — with screenshots |
| [Part 2 — CI/CD Pipeline](docs/part2-cicd.md) | Pipeline architecture, source/build/deploy stages, auto-deploy to new instances, Blue/Green deployment, rollback test — with screenshots |
| **[Assignment Book (PDF)](docs/Bitopi_AWS_AutoScaling_CICD_Assignment.pdf)** | Everything below in one document for submission — cover, both parts, the communication guide, all screenshots |
| [How the servers talk to each other](docs/how-servers-communicate.md) | Every network hop in the system explained in plain words, with the real commands used at each hop |
| [Terraform audit](terraform/README.md) | Read-only Terraform program that reports which of the hand-built resources still exist (PRESENT / MISSING) and prints the values needed to continue — how to run it on Windows, step by step |

## Repository structure

```
.
├── README.md                     ← you are here
├── docs/                         ← the full write-ups (assignment documentation)
│   ├── part1-auto-scaling.md
│   ├── part2-cicd.md
│   └── how-servers-communicate.md
├── diagrams/                     ← architecture diagrams (PNG + editable SVG)
├── SS/                           ← evidence screenshots  (P1-xx = Part 1, P2-xx = Part 2)
├── app/                          ← the Node.js backend application
│   ├── app.js                    ←   serves  /  /health  /version , reads from MySQL
│   ├── package.json              ←   version here = release tag
│   └── test/health.test.js       ←   tests run by the pipeline
└── scripts/                      ← EC2 user-data (first-boot) scripts
    ├── db-server-userdata.sh              ←   builds the MySQL database server
    ├── app-server-userdata.sh             ←   Launch Template v1 (Part 1: app embedded)
    ├── app-server-userdata-v2-blue.sh     ←   Launch Template v2 (Part 2: pull-based deployer, BLUE)
    ├── app-server-userdata-v3-green.sh    ←   Launch Template v3 (Blue/Green: GREEN, pinned candidate)
    ├── deploy.sh                          ←   the deployer that runs on every server
│   └── fix-ssh-key-permissions-windows.ps1 ←   makes a .pem key usable by Windows OpenSSH
├── terraform/                    ← read-only audit: is every resource still there? (main.tf, audit.tf, README.md)
└── .github/workflows/ci-cd.yml   ← the CI/CD pipeline (GitHub Actions)
```

## Account constraints and how the design adapts

This project was built in a **restricted course account**. The limits below are real, and the design works around every one of them:

| Restriction | Impact | How we adapted |
|---|---|---|
| Cannot create **IAM roles** | Native CodeDeploy/CodeBuild/CodePipeline need service roles + an EC2 instance profile | Part 1 needs no user-created roles at all. Part 2 uses existing roles if present, otherwise a role-free pipeline (see Part 2 doc) |
| No **SSM** permission | Can't use Session Manager or Parameter Store | SSH with a key pair for access; environment variables for app config |
| Cannot create **RDS** (`rds:CreateDBSubnetGroup` denied) | No managed database | MySQL (MariaDB) self-hosted on a small EC2, auto-configured by user-data, protected by `bitopi-db-sg` |
| No **CloudShell** | Can't run AWS CLI in the console | All configuration done through the console; permissions confirmed by building |

> **Note on secrets:** the database password in the scripts is a throw-away lab credential and every resource is destroyed at the end of the assignment. In production this would live in AWS Secrets Manager, never in plain config.

## Progress

- [x] Part 1 architecture diagram
- [x] VPC + subnets across 2 AZs
- [x] Security groups (ALB / Backend / DB)
- [x] Database tier (MySQL on EC2)
- [x] Launch Template
- [x] Target Group + Application Load Balancer
- [x] Auto Scaling Group
- [x] Health checks + self-healing test
- [x] Scaling policy + load test (scale-out / scale-in)
- [x] Part 2 CI/CD architecture diagram
- [x] CI/CD pipeline (Source → Build → Deploy)
- [x] Auto-deploy to new Auto Scaling instances
- [~] Blue/Green deployment + rollback — **designed and prepared** (LT v3 user-data, candidate release path, runbook in the Part 2 doc §7); live switch + rollback pending a rebuilt stack
