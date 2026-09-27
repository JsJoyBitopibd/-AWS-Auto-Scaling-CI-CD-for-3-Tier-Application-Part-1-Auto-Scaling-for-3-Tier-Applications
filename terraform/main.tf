# =====================================================================
#  Bitopi 3-Tier assignment  -  Terraform "is it still there?" audit
#
#  This configuration is READ-ONLY.  It contains ZERO `resource` blocks,
#  so `terraform apply` can never create, change or delete anything in
#  AWS.  It only *looks up* the resources that were built by hand in
#  Part 1 / Part 2 and reports, for each one, PRESENT or MISSING.
#
#  Files:
#    main.tf      - provider / version settings + the names we look for
#    audit.tf     - the lookups, the PRESENT/MISSING checks, the report
#    README.md    - how to run it on Windows, step by step
# =====================================================================

terraform {
  required_version = ">= 1.5.0" # `check` blocks need Terraform 1.5+

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

provider "aws" {
  region = var.region
  # Credentials are NOT written here.  Terraform reads them from
  # environment variables (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
  # AWS_SESSION_TOKEN) or from `aws configure` - see README.md.
}

# ---- names used when the stack was built (change only if you renamed) ----
variable "region" {
  description = "Region the stack was built in"
  type        = string
  default     = "ap-south-1"
}

variable "prefix" {
  description = "Name prefix used for every resource of the assignment"
  type        = string
  default     = "bitopi"
}

locals {
  vpc_name        = "${var.prefix}-vpc"
  subnet_glob     = "${var.prefix}-subnet-*" # bitopi-subnet-public1-ap-south-1a, ...
  sg_names        = ["${var.prefix}-alb-sg", "${var.prefix}-backend-sg", "${var.prefix}-db-sg"]
  key_pair_name   = "${var.prefix}-key"
  db_server_name  = "${var.prefix}-db-server"
  launch_template = "${var.prefix}-app-lt"
  tg_blue         = "${var.prefix}-app-tg"
  tg_green        = "${var.prefix}-app-tg-green"
  alb_name        = "${var.prefix}-alb"
  asg_blue        = "${var.prefix}-app-asg"
  asg_green       = "${var.prefix}-app-asg-green"
}
