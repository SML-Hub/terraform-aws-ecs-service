locals {
  efs_enabled = try(var.efs.enabled, false)
  efs_name    = "${data.aws_ecs_cluster.ecs_cluster.cluster_name}-${var.ecs_service_name}"
}

resource "aws_efs_file_system" "this" {
  count = local.efs_enabled ? 1 : 0

  creation_token   = local.efs_name
  encrypted        = var.efs.encrypted
  performance_mode = var.efs.performance_mode
  throughput_mode  = var.efs.throughput_mode

  dynamic "lifecycle_policy" {
    for_each = var.efs.transition_to_ia == null ? [] : [1]
    content {
      transition_to_ia = var.efs.transition_to_ia
    }
  }

  tags = merge(
    {
      Name        = local.efs_name
      Application = var.ecs_service_name
    },
    var.tags
  )
}

resource "aws_security_group" "efs" {
  count = local.efs_enabled ? 1 : 0

  name        = "${local.efs_name}-efs"
  description = "Allow NFS from ${var.ecs_service_name} ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from ECS tasks"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = var.security_group_ids
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    {
      Name        = "${local.efs_name}-efs"
      Application = var.ecs_service_name
    },
    var.tags
  )
}

resource "aws_efs_mount_target" "this" {
  count = local.efs_enabled ? length(var.subnet_ids) : 0

  file_system_id  = aws_efs_file_system.this[0].id
  subnet_id       = var.subnet_ids[count.index]
  security_groups = [aws_security_group.efs[0].id]
}

resource "aws_efs_access_point" "this" {
  count = local.efs_enabled ? 1 : 0

  file_system_id = aws_efs_file_system.this[0].id

  posix_user {
    uid = var.efs.posix_uid
    gid = var.efs.posix_gid
  }

  root_directory {
    path = var.efs.root_directory

    # creation_info is only valid for a non-root path ("/" always exists)
    dynamic "creation_info" {
      for_each = var.efs.root_directory == "/" ? [] : [1]
      content {
        owner_uid   = var.efs.posix_uid
        owner_gid   = var.efs.posix_gid
        permissions = var.efs.permissions
      }
    }
  }

  tags = merge(
    {
      Name        = "${local.efs_name}-ap"
      Application = var.ecs_service_name
    },
    var.tags
  )
}
