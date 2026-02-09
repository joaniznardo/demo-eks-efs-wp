###############################################################################
# WordPress on EKS amb EFS - AWS Academy
# Desplegament sobre la VPC per defecte a us-east-1 (2 AZs)
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["${var.region}a", "${var.region}b"]
  }
}

locals {
  lab_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"
}

# ---------------------------------------------------------------------------
# Security Group - EFS (permet NFS des de la VPC)
# ---------------------------------------------------------------------------

resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs-sg"
  description = "Allow NFS from VPC"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "NFS from VPC"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-efs-sg" }
}

# ---------------------------------------------------------------------------
# EKS Cluster
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = local.lab_role_arn
  version  = var.eks_version

  vpc_config {
    subnet_ids = data.aws_subnets.default.ids
  }
}

# ---------------------------------------------------------------------------
# EKS Node Group
# ---------------------------------------------------------------------------

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = local.lab_role_arn
  subnet_ids      = data.aws_subnets.default.ids

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"]

  depends_on = [aws_eks_cluster.main]
}

# ---------------------------------------------------------------------------
# EFS File System
# ---------------------------------------------------------------------------

resource "aws_efs_file_system" "main" {
  creation_token = "${var.cluster_name}-efs"

  tags = { Name = "${var.cluster_name}-efs" }
}

resource "aws_efs_mount_target" "main" {
  for_each        = toset(data.aws_subnets.default.ids)
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# ---------------------------------------------------------------------------
# EKS Addon - EFS CSI Driver
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "efs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-efs-csi-driver"
  service_account_role_arn = local.lab_role_arn

  depends_on = [aws_eks_node_group.main]
}
