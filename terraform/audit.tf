# =====================================================================
#  audit.tf  -  look up every hand-built resource and report on it
#
#  Two kinds of lookups are used on purpose:
#
#   1. "plural" data sources (aws_vpcs, aws_subnets, aws_security_groups,
#      aws_instances, aws_lbs, aws_autoscaling_groups).  These NEVER fail:
#      when nothing matches they simply return an empty list.  That lets
#      us print PRESENT / MISSING in the final report and also print
#      useful values (DB private IP, ALB DNS name, ASG sizes ...).
#
#   2. `check` blocks with a "scoped" data source inside them.  Some
#      resources only have a singular data source (key pair, launch
#      template, target group) which would normally ABORT the whole run
#      when the thing does not exist.  Inside a check block Terraform
#      turns that abort into a *warning* instead, so the run continues
#      and the warning itself is the MISSING report.
# =====================================================================

# ---------------------------------------------------------------------
# 1. Network - VPC, subnets, security groups
# ---------------------------------------------------------------------
data "aws_vpcs" "vpc" {
  filter {
    name   = "tag:Name"
    values = [local.vpc_name]
  }
}

data "aws_subnets" "subnets" {
  filter {
    name   = "tag:Name"
    values = [local.subnet_glob]
  }
}

data "aws_subnet" "each" {
  for_each = toset(data.aws_subnets.subnets.ids)
  id       = each.value
}

data "aws_security_groups" "sgs" {
  filter {
    name   = "group-name"
    values = local.sg_names
  }
}

data "aws_security_group" "each" {
  for_each = toset(data.aws_security_groups.sgs.ids)
  id       = each.value
}

# ---------------------------------------------------------------------
# 2. Database tier - the MySQL (MariaDB) EC2 server
# ---------------------------------------------------------------------
data "aws_instances" "db" {
  filter {
    name   = "tag:Name"
    values = [local.db_server_name]
  }
  instance_state_names = ["pending", "running", "stopping", "stopped"]
}

# ---------------------------------------------------------------------
# 3. Load balancer + listener  (list all ELBv2 LBs, then pick ours)
# ---------------------------------------------------------------------
data "aws_lbs" "all" {}

data "aws_lb" "each" {
  for_each = data.aws_lbs.all.arns
  arn      = each.value
}

locals {
  alb = one([for lb in data.aws_lb.each : lb if lb.name == local.alb_name])
}

data "aws_lb_listener" "http80" {
  count             = local.alb == null ? 0 : 1
  load_balancer_arn = local.alb.arn
  port              = 80
}

# ---------------------------------------------------------------------
# 4. Auto Scaling Groups (blue = Part 1/2, green = Blue/Green step)
# ---------------------------------------------------------------------
data "aws_autoscaling_groups" "bitopi" {
  names = [local.asg_blue, local.asg_green]
}

data "aws_autoscaling_group" "each" {
  for_each = toset(data.aws_autoscaling_groups.bitopi.names)
  name     = each.value
}

# ---------------------------------------------------------------------
# 5. Things that only have a singular lookup -> check blocks
#    (a failure here prints a WARNING, never an error)
# ---------------------------------------------------------------------
check "key_pair" {
  data "aws_key_pair" "this" {
    key_name = local.key_pair_name
  }
  assert {
    condition     = data.aws_key_pair.this.key_name == local.key_pair_name
    error_message = "MISSING: key pair ${local.key_pair_name} (Part 1 - Step 2)"
  }
}

check "launch_template" {
  data "aws_launch_template" "this" {
    name = local.launch_template
  }
  assert {
    condition     = data.aws_launch_template.this.latest_version >= 2
    error_message = "Launch template ${local.launch_template} exists but only has version ${data.aws_launch_template.this.latest_version}. Part 2 needs v2 (pull-based deployer) - see docs/part2-cicd.md Step 2."
  }
}

check "target_group_blue" {
  data "aws_lb_target_group" "this" {
    name = local.tg_blue
  }
  assert {
    condition     = data.aws_lb_target_group.this.port == 3000 && data.aws_lb_target_group.this.health_check[0].path == "/health"
    error_message = "Target group ${local.tg_blue} exists but is not HTTP:3000 with health check /health."
  }
}

check "target_group_green_optional" {
  data "aws_lb_target_group" "green" {
    name = local.tg_green
  }
  assert {
    condition     = data.aws_lb_target_group.green.port == 3000
    error_message = "Green target group ${local.tg_green} exists but is not on port 3000."
  }
}

# ---------------------------------------------------------------------
# 6. Assertions on the plural lookups (so they also show as warnings)
# ---------------------------------------------------------------------
check "vpc" {
  assert {
    condition     = length(data.aws_vpcs.vpc.ids) == 1
    error_message = "MISSING: VPC ${local.vpc_name} (Part 1 - Step 1). Found ${length(data.aws_vpcs.vpc.ids)}."
  }
}

check "subnets" {
  assert {
    condition     = length(data.aws_subnets.subnets.ids) == 4
    error_message = "Expected 4 subnets named ${local.subnet_glob}, found ${length(data.aws_subnets.subnets.ids)} (Part 1 - Step 1)."
  }
}

check "security_groups" {
  assert {
    condition     = length(data.aws_security_groups.sgs.ids) == 3
    error_message = "Expected 3 security groups (${join(", ", local.sg_names)}), found ${length(data.aws_security_groups.sgs.ids)} (Part 1 - Step 2)."
  }
}

check "db_server" {
  assert {
    condition     = length(data.aws_instances.db.ids) >= 1
    error_message = "MISSING: EC2 instance ${local.db_server_name} (Part 1 - Step 3). The app's DB_HOST must be rebuilt."
  }
}

check "alb" {
  assert {
    condition     = local.alb != null
    error_message = "MISSING: Application Load Balancer ${local.alb_name} (Part 1 - Step 5)."
  }
}

check "asg_blue" {
  assert {
    condition     = contains(data.aws_autoscaling_groups.bitopi.names, local.asg_blue)
    error_message = "MISSING: Auto Scaling Group ${local.asg_blue} (Part 1 - Step 6)."
  }
}

# ---------------------------------------------------------------------
# 7. The report
# ---------------------------------------------------------------------
locals {
  ok = {
    vpc       = length(data.aws_vpcs.vpc.ids) == 1
    subnets   = length(data.aws_subnets.subnets.ids) == 4
    sgs       = length(data.aws_security_groups.sgs.ids) == 3
    db        = length(data.aws_instances.db.ids) >= 1
    alb       = local.alb != null
    asg_blue  = contains(data.aws_autoscaling_groups.bitopi.names, local.asg_blue)
    asg_green = contains(data.aws_autoscaling_groups.bitopi.names, local.asg_green)
  }
  mark = { for k, v in local.ok : k => (v ? "PRESENT" : "MISSING") }

  blue_asg  = try(data.aws_autoscaling_group.each[local.asg_blue], null)
  green_asg = try(data.aws_autoscaling_group.each[local.asg_green], null)
  listener  = try(data.aws_lb_listener.http80[0], null)
  # arn:aws:elasticloadbalancing:...:targetgroup/<NAME>/<hash>  ->  <NAME>
  live_tg = local.listener == null ? "-" : try(regex("targetgroup/([^/]+)/", local.listener.default_action[0].target_group_arn)[0], "?")

  db_ip   = length(data.aws_instances.db.private_ips) > 0 ? data.aws_instances.db.private_ips[0] : null
  alb_dns = local.alb == null ? null : local.alb.dns_name

  report = <<-EOT

    ================  BITOPI 3-TIER AUDIT  (${var.region})  ================
      VPC ${local.vpc_name} ........................ ${local.mark.vpc}
      4 subnets ${local.subnet_glob} ........ ${local.mark.subnets}   (found ${length(data.aws_subnets.subnets.ids)})
      3 security groups ........................ ${local.mark.sgs}   (found ${length(data.aws_security_groups.sgs.ids)}: ${join(", ", [for sg in data.aws_security_group.each : sg.name])})
      DB server ${local.db_server_name} ............ ${local.mark.db}   ${local.db_ip == null ? "" : "private IP ${local.db_ip}"}
      ALB ${local.alb_name} ............................ ${local.mark.alb}   ${local.alb_dns == null ? "" : local.alb_dns}
      listener :80 currently forwards to ......... ${local.live_tg}
      ASG ${local.asg_blue} (blue) ................ ${local.mark.asg_blue}   ${local.blue_asg == null ? "" : "min ${local.blue_asg.min_size} / desired ${local.blue_asg.desired_capacity} / max ${local.blue_asg.max_size}, LT ${try(local.blue_asg.launch_template[0].name, "?")} v${try(local.blue_asg.launch_template[0].version, "?")}"}
      ASG ${local.asg_green} (green) .......... ${local.mark.asg_green}   (only needed for the Blue/Green step)
      key pair / launch template / target groups : see the WARNINGS above
                                                   (no warning = PRESENT)
    ========================================================================

    Everything marked MISSING (or named in a warning) must be rebuilt by
    hand in the console - follow docs/part1-auto-scaling.md for Part 1 and
    docs/part2-cicd.md section 7 for the Blue/Green steps.
  EOT
}

output "audit_summary" {
  description = "Human-readable PRESENT/MISSING report"
  value       = local.report
}

output "db_private_ip" {
  description = "Use this as DB_HOST in the launch-template user-data (null = DB server missing)"
  value       = local.db_ip
}

output "alb_url" {
  description = "Open this in the browser (null = ALB missing)"
  value       = local.alb_dns == null ? null : "http://${local.alb_dns}/"
}

output "public_subnet_ids" {
  description = "Subnets to pick for the ALB and the Auto Scaling Groups"
  value       = { for s in data.aws_subnet.each : s.tags["Name"] => s.id if can(regex("public", s.tags["Name"])) }
}

output "security_group_ids" {
  value = { for sg in data.aws_security_group.each : sg.name => sg.id }
}

output "blue_asg" {
  value = local.blue_asg == null ? null : {
    min                     = local.blue_asg.min_size
    desired                 = local.blue_asg.desired_capacity
    max                     = local.blue_asg.max_size
    launch_template_version = try(local.blue_asg.launch_template[0].version, null)
    health_check_type       = local.blue_asg.health_check_type
    target_groups           = local.blue_asg.target_group_arns
  }
}

output "green_asg" {
  value = local.green_asg == null ? null : {
    min                     = local.green_asg.min_size
    desired                 = local.green_asg.desired_capacity
    max                     = local.green_asg.max_size
    launch_template_version = try(local.green_asg.launch_template[0].version, null)
  }
}

output "listener_forwards_to" {
  description = "Which target group gets production traffic right now (blue = bitopi-app-tg, green = bitopi-app-tg-green)"
  value       = local.live_tg
}
