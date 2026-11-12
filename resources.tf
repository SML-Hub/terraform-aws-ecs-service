resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/${data.aws_ecs_cluster.ecs_cluster.cluster_name}/${var.ecs_service_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_alb_target_group" "target_group" {
  count                = var.application_load_balancer.enabled ? 1 : 0
  name                 = local.main_target_group_name
  port                 = var.application_load_balancer.container_port
  protocol             = var.application_load_balancer.protocol
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = var.application_load_balancer.deregister_deregistration_delay

  dynamic "stickiness" {
    for_each = var.application_load_balancer.stickiness ? [1] : []
    content {
      cookie_duration = var.application_load_balancer.stickiness_ttl
      cookie_name     = var.application_load_balancer.cookie_name
      type            = var.application_load_balancer.stickiness_type

    }

  }

  health_check {
    healthy_threshold   = var.application_load_balancer.health_check_threshold_healthy
    interval            = var.application_load_balancer.health_check_interval_sec
    protocol            = var.application_load_balancer.health_check_protocol
    matcher             = var.application_load_balancer.health_check_matcher
    timeout             = var.application_load_balancer.health_check_timeout_sec
    path                = var.application_load_balancer.health_check_path
    unhealthy_threshold = var.application_load_balancer.health_check_threshold_unhealthy
  }
  depends_on = [aws_alb_target_group.target_group_additional]
}

resource "aws_alb_target_group" "target_group_additional" {
  for_each = {
    for idx, alb in var.additional_load_balancers : idx => alb
    if alb.enabled && try(alb.action_type, "forward") == "forward"
  }

  name                 = local.additional_target_group_names[each.key]
  port                 = each.value.container_port
  protocol             = each.value.protocol
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = each.value.deregister_deregistration_delay
  dynamic "stickiness" {
    for_each = each.value.stickiness ? [1] : []
    content {
      cookie_duration = each.value.stickiness_ttl
      cookie_name     = each.value.cookie_name
      type            = each.value.stickiness_type
    }

  }

  health_check {
    healthy_threshold   = each.value.health_check_threshold_healthy
    interval            = each.value.health_check_interval_sec
    protocol            = each.value.health_check_protocol
    matcher             = each.value.health_check_matcher
    timeout             = each.value.health_check_timeout_sec
    path                = each.value.health_check_path
    unhealthy_threshold = each.value.health_check_threshold_unhealthy
  }
}

resource "aws_lb_listener_rule" "rule" {
  count = var.application_load_balancer.enabled ? 1 : 0

  listener_arn = var.application_load_balancer.listener_arn
  priority     = local.next_priority + length(var.additional_load_balancers)

  dynamic "action" {
    for_each = var.application_load_balancer.action_type == "forward" ? [1] : []
    content {
      type = "forward"

      forward {
        target_group {
          arn = aws_alb_target_group.target_group[0].arn
        }

        stickiness {
          enabled  = lookup(var.application_load_balancer, "stickiness", false)
          duration = lookup(var.application_load_balancer, "stickiness_ttl", 300)
        }
      }
    }
  }

  dynamic "action" {
    for_each = var.application_load_balancer.action_type == "fixed-response" ? [1] : []
    content {
      type = "fixed-response"
      fixed_response {
        content_type = "text/plain"
        message_body = "Unauthorized"
        status_code  = "401"
      }
    }
  }

  dynamic "condition" {
    for_each = length(var.application_load_balancer.host) > 0 ? [1] : []
    content {
      host_header {
        values = [var.application_load_balancer.host]
      }
    }
  }

  dynamic "condition" {
    for_each = length(var.application_load_balancer.path) > 0 ? [1] : []
    content {
      path_pattern {
        values = [var.application_load_balancer.path]
      }
    }
  }

  lifecycle {
    ignore_changes = [priority]
  }

  depends_on = [aws_alb_target_group.target_group, aws_lb_listener_rule.rule_additional, aws_alb_target_group.target_group_additional]
}


resource "aws_lb_listener_rule" "rule_additional" {
  for_each = {
    for idx, alb in var.additional_load_balancers : idx => alb
    if alb.enabled
  }

  listener_arn = each.value.listener_arn
  priority     = local.next_priority + tonumber(each.key)

  dynamic "action" {
    for_each = each.value.action_type == "forward" ? [1] : []
    content {
      type = "forward"

      forward {
        target_group {
          arn = aws_alb_target_group.target_group_additional[each.key].arn
        }

        stickiness {
          enabled  = lookup(each.value, "stickiness", false)
          duration = lookup(each.value, "stickiness_ttl", 300)
        }
      }
    }
  }

  dynamic "action" {
    for_each = each.value.action_type == "fixed-response" ? [1] : []
    content {
      type = "fixed-response"
      fixed_response {
        content_type = "text/plain"
        message_body = "Unauthorized"
        status_code  = "401"
      }
    }
  }

  dynamic "condition" {
    for_each = length(each.value.host) > 0 ? [1] : []
    content {
      host_header {
        values = [each.value.host]
      }
    }
  }

  dynamic "condition" {
    for_each = length(each.value.path) > 0 ? [1] : []
    content {
      path_pattern {
        values = [each.value.path]
      }
    }
  }

  lifecycle {
    ignore_changes = [priority]
  }

  depends_on = [aws_alb_target_group.target_group_additional]
}


resource "aws_ecs_task_definition" "task_definition" {
  family                   = "${data.aws_ecs_cluster.ecs_cluster.cluster_name}_${var.ecs_service_name}"
  network_mode             = "awsvpc"
  requires_compatibilities = [var.ecs_launch_type]
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  task_role_arn            = var.initial_role != "" ? var.initial_role : null
  execution_role_arn       = var.initial_role != "" ? var.initial_role : null
  container_definitions = jsonencode([
    {
      name      = var.container_name
      image     = var.container_image
      essential = true

      portMappings = flatten([
        # Primary port mapping - ALB takes priority, otherwise Service Connect
        var.application_load_balancer.enabled && var.application_load_balancer.action_type == "forward" ? [
          {
            name          = "default"
            containerPort = var.application_load_balancer.container_port
            hostPort      = var.application_load_balancer.container_port
            protocol      = "tcp"
            appProtocol   = "http"
          }
          ] : var.service_connect.enabled && !(var.application_load_balancer.enabled && var.application_load_balancer.action_type == "forward") ? [
          {
            name          = "default"
            containerPort = var.service_connect.port
            hostPort      = var.service_connect.port
            protocol      = "tcp"
            appProtocol   = "http"
          }
        ] : [],
        # Additional Service Connect ports
        [
          for name, port_config in var.service_connect.additional_ports : {
            name          = port_config.name
            containerPort = port_config.port
            hostPort      = port_config.port
            protocol      = "tcp"
            appProtocol   = "http"
          }
        ]
      ])
    }
  ])

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_ecs_service" "ecs_service" {
  name                               = var.ecs_service_name
  cluster                            = data.aws_ecs_cluster.ecs_cluster.id
  task_definition                    = aws_ecs_task_definition.task_definition.arn
  desired_count                      = var.desired_count
  deployment_minimum_healthy_percent = var.deployment.min_healthy_percent
  deployment_maximum_percent         = var.deployment.max_healthy_percent

  enable_execute_command = var.enable_execute_command
  launch_type            = var.capacity_provider_strategy == "" ? "FARGATE" : null
  scheduling_strategy    = "REPLICA"
  propagate_tags         = "SERVICE"
  platform_version       = var.ecs_launch_type == "FARGATE" ? "LATEST" : ""
  deployment_controller {
    type = "ECS"
  }

  deployment_circuit_breaker {
    enable   = var.deployment.circuit_breaker_enabled
    rollback = var.deployment.rollback_enabled
  }

  network_configuration {
    security_groups  = var.security_group_ids
    subnets          = var.subnet_ids
    assign_public_ip = var.assign_public_ip
  }
  dynamic "alarms" {
    for_each = var.deployment.cloudwatch_alarm_enabled ? [1] : []
    content {
      alarm_names = var.deployment.cloudwatch_alarm_names
      enable      = true
      rollback    = var.deployment.cloudwatch_alarm_rollback
    }
  }
  dynamic "load_balancer" {
    for_each = var.application_load_balancer.enabled && var.application_load_balancer.action_type == "forward" ? [1] : []
    content {
      target_group_arn = aws_alb_target_group.target_group[0].arn
      container_name   = var.container_name
      container_port   = var.application_load_balancer.container_port
    }
  }
  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy != "" ? [1] : []
    content {
      capacity_provider = var.capacity_provider_strategy
      weight            = 1
      base              = 0
    }

  }

  dynamic "load_balancer" {
    for_each = {
      for idx, alb in var.additional_load_balancers : idx => alb
      if alb.enabled && alb.action_type == "forward"
    }
    content {
      target_group_arn = aws_alb_target_group.target_group_additional[load_balancer.key].arn
      container_name   = var.container_name
      container_port   = load_balancer.value.container_port
    }
  }

  dynamic "service_connect_configuration" {
    for_each = var.service_connect.enabled ? [1] : []
    content {
      enabled   = true
      namespace = var.ecs_cluster_name

      dynamic "service" {
        for_each = contains(["client-server"], var.service_connect.type) ? [1] : []
        content {
          port_name      = "default"
          discovery_name = var.service_connect.name
          client_alias {
            port     = var.service_connect.port
            dns_name = var.service_connect.name
          }
          timeout {
            idle_timeout_seconds        = var.service_connect.idle_timeout
            per_request_timeout_seconds = var.service_connect.timeout
          }
        }
      }

      dynamic "service" {
        for_each = var.service_connect.type == "client-server" && length(var.service_connect.additional_ports) > 0 ? var.service_connect.additional_ports : []
        content {
          port_name      = service.value.name
          discovery_name = "${var.service_connect.name}-${service.value.name}"
          client_alias {
            port     = service.value.port
            dns_name = var.service_connect.name
          }
          timeout {
            idle_timeout_seconds        = var.service_connect.idle_timeout
            per_request_timeout_seconds = var.service_connect.timeout
          }
        }
      }
    }
  }
  tags = merge(
    { Application = "${var.ecs_service_name}" },
    var.tags
  )


  lifecycle {
    ignore_changes = [task_definition, platform_version, desired_count]
  }
  depends_on = [aws_lb_listener_rule.rule,
    aws_lb_listener_rule.rule_additional,
    aws_alb_target_group.target_group,
    aws_alb_target_group.target_group_additional,
    aws_ecs_task_definition.task_definition
  ]
}

resource "aws_appautoscaling_target" "ecs_target" {
  count = (var.cpu_auto_scaling.enabled || var.memory_auto_scaling.enabled || var.sqs_auto_scaling.enabled || var.schedule_auto_scaling.enabled) ? 1 : 0
  min_capacity = max(
    try(var.cpu_auto_scaling.min_replicas, 0),
    try(var.memory_auto_scaling.min_replicas, 0),
    try(var.sqs_auto_scaling.min_replicas, 0),
    try(var.schedule_auto_scaling.min_replicas, 0)
  )
  max_capacity = max(
    try(var.cpu_auto_scaling.max_replicas, 0),
    try(var.memory_auto_scaling.max_replicas, 0),
    try(var.sqs_auto_scaling.max_replicas, 0),
    try(var.schedule_auto_scaling.max_replicas, 0)
  )
  resource_id        = "service/${var.ecs_cluster_name}/${var.ecs_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
  depends_on         = [aws_ecs_service.ecs_service]
  lifecycle {
    ignore_changes = [min_capacity, max_capacity]
  }
}
resource "aws_appautoscaling_scheduled_action" "ecs_scheduled_scaling" {
  count = var.schedule_auto_scaling.enabled ? length(var.schedule_auto_scaling.schedules) : 0

  name               = "${var.ecs_cluster_name}-${var.ecs_service_name}-${var.schedule_auto_scaling.schedules[count.index].schedule_name}"
  service_namespace  = "ecs"
  resource_id        = "service/${var.ecs_cluster_name}/${var.ecs_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  schedule           = var.schedule_auto_scaling.schedules[count.index].schedule_expression
  timezone           = var.schedule_auto_scaling.schedules[count.index].time_zone
  start_time         = timeadd(timestamp(), "100s")
  scalable_target_action {
    min_capacity = try(var.schedule_auto_scaling.schedules[count.index].min_replicas, 0)
    max_capacity = try(var.schedule_auto_scaling.schedules[count.index].max_replicas, 0)
  }

  depends_on = [aws_ecs_service.ecs_service, aws_appautoscaling_target.ecs_target]
  lifecycle {
    ignore_changes = [start_time]
  }
}
resource "aws_appautoscaling_policy" "scale_by_cpu_policy" {
  count              = var.cpu_auto_scaling.enabled ? 1 : 0
  name               = "${var.ecs_cluster_name}/${var.ecs_service_name}/scale-by-cpu-policy"
  service_namespace  = "ecs"
  resource_id        = "service/${var.ecs_cluster_name}/${var.ecs_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  policy_type        = "TargetTrackingScaling"
  target_tracking_scaling_policy_configuration {
    disable_scale_in   = false
    scale_in_cooldown  = var.cpu_auto_scaling.scale_in_cooldown
    scale_out_cooldown = var.cpu_auto_scaling.scale_out_cooldown
    target_value       = var.cpu_auto_scaling.target_value

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
  depends_on = [aws_ecs_service.ecs_service, aws_appautoscaling_target.ecs_target]
}

resource "aws_appautoscaling_policy" "scale_by_memory_policy" {
  count              = var.memory_auto_scaling.enabled ? 1 : 0
  name               = "${var.ecs_cluster_name}/${var.ecs_service_name}/scale-by-memory-policy"
  service_namespace  = "ecs"
  resource_id        = "service/${var.ecs_cluster_name}/${var.ecs_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  policy_type        = "TargetTrackingScaling"
  target_tracking_scaling_policy_configuration {
    disable_scale_in   = false
    scale_in_cooldown  = var.memory_auto_scaling.scale_in_cooldown
    scale_out_cooldown = var.memory_auto_scaling.scale_out_cooldown
    target_value       = var.memory_auto_scaling.target_value

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
  depends_on = [aws_ecs_service.ecs_service, aws_appautoscaling_target.ecs_target]
}

resource "aws_appautoscaling_policy" "scale_out_by_sqs_policy" {
  count              = var.sqs_auto_scaling.enabled ? 1 : 0
  name               = "${var.ecs_cluster_name}/${var.ecs_service_name}/scale-out-by-sqs-policy"
  service_namespace  = "ecs"
  resource_id        = "service/${var.ecs_cluster_name}/${var.ecs_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  policy_type        = "StepScaling"
  step_scaling_policy_configuration {
    adjustment_type          = "ChangeInCapacity"
    cooldown                 = var.sqs_auto_scaling.scale_out_cooldown
    metric_aggregation_type  = "Maximum"
    min_adjustment_magnitude = 0

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = var.sqs_auto_scaling.scale_out_step
    }
  }
  depends_on = [aws_ecs_service.ecs_service, aws_appautoscaling_target.ecs_target]
}

resource "aws_appautoscaling_policy" "scale_in_by_sqs_policy" {
  count              = var.sqs_auto_scaling.enabled ? 1 : 0
  name               = "${var.ecs_cluster_name}/${var.ecs_service_name}/scale-in-by-sqs-policy"
  service_namespace  = "ecs"
  resource_id        = "service/${var.ecs_cluster_name}/${var.ecs_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  policy_type        = "StepScaling"

  step_scaling_policy_configuration {
    adjustment_type          = "ChangeInCapacity"
    cooldown                 = var.sqs_auto_scaling.scale_in_cooldown
    metric_aggregation_type  = "Maximum"
    min_adjustment_magnitude = 0

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1 * var.sqs_auto_scaling.scale_in_step
    }
  }
  depends_on = [aws_ecs_service.ecs_service, aws_appautoscaling_target.ecs_target]
}

###############################################################################
# SCALE OUT SQS AUTO SCALING ALARM
###############################################################################
resource "aws_cloudwatch_metric_alarm" "out_sqs_auto_scaling" {
  count               = var.sqs_auto_scaling.enabled ? 1 : 0
  alarm_name          = "${var.ecs_cluster_name}/${var.ecs_service_name}/sqs-out-auto-scaling"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.sqs_auto_scaling.scale_out_datapoints_to_alarm
  threshold           = var.sqs_auto_scaling.scale_out_threshold # e.g., 100
  alarm_description   = "Scale OUT if SQS message count are too high"
  datapoints_to_alarm = var.sqs_auto_scaling.scale_out_datapoints_to_alarm
  alarm_actions       = [aws_appautoscaling_policy.scale_out_by_sqs_policy[0].arn]
  treat_missing_data  = "ignore"

  namespace   = "AWS/SQS"
  metric_name = var.sqs_auto_scaling.scale_out_metric_name
  period      = var.sqs_auto_scaling.scale_out_interval
  statistic   = "Maximum"
  dimensions = {
    QueueName = local.scale_out_queue_name
  }

  depends_on = [aws_ecs_service.ecs_service]
}

###############################################################################
# SCALE IN SQS AUTO SCALING ALARM
###############################################################################
resource "aws_cloudwatch_metric_alarm" "in_sqs_auto_scaling" {
  count               = var.sqs_auto_scaling.enabled ? 1 : 0
  alarm_name          = "${var.ecs_cluster_name}/${var.ecs_service_name}/sqs-in-auto-scaling"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = var.sqs_auto_scaling.scale_in_datapoints_to_alarm
  threshold           = var.sqs_auto_scaling.scale_in_threshold # e.g., 10
  alarm_description   = "Scale IN if SQS message count are too low"
  datapoints_to_alarm = var.sqs_auto_scaling.scale_in_datapoints_to_alarm
  alarm_actions       = [aws_appautoscaling_policy.scale_in_by_sqs_policy[0].arn]
  treat_missing_data  = "ignore"

  namespace   = "AWS/SQS"
  metric_name = var.sqs_auto_scaling.scale_in_metric_name
  period      = var.sqs_auto_scaling.scale_in_interval
  statistic   = "Maximum"
  dimensions = {
    QueueName = local.scale_in_queue_name
  }

  depends_on = [aws_ecs_service.ecs_service]
}


###############################################################################
# ECR REPOSITORY
###############################################################################
module "ecr" {
  count   = var.ecr.create_repo ? 1 : 0
  source  = "terraform-aws-modules/ecr/aws"
  version = "2.3.0"

  repository_name                 = var.ecr.repo_name != "" ? var.ecr.repo_name : var.ecs_service_name
  repository_image_tag_mutability = var.ecr.mutability
  attach_repository_policy        = false
  repository_lifecycle_policy = jsonencode({
    rules = concat(
      [
        {
          rulePriority = 1,
          description  = "Protect ${join(", ", var.ecr.protected_prefixes)} branches tags",
          selection = {
            tagStatus     = "tagged",
            tagPrefixList = var.ecr.protected_prefixes,
            countType     = "imageCountMoreThan",
            countNumber   = var.ecr.protected_retention
          },
          action = {
            type = "expire"
          }
        }
      ],
      [
        for idx, prefix in var.ecr.versioned_prefixes : {
          rulePriority = idx + 2, # Dynamic priority starting from 2
          description  = "Keep number of latest releases images for ${prefix}",
          selection = {
            tagStatus     = "tagged",
            tagPrefixList = [prefix],
            countType     = "imageCountMoreThan",
            countNumber   = var.ecr.versioned_retention
          },
          action = {
            type = "expire"
          }
        }
      ],
      [
        {
          rulePriority = length(var.ecr.versioned_prefixes) + 2,
          description  = "Expire all tagged images older than ${var.ecr.tagged_ttl_days} days",
          selection = {
            tagStatus      = "tagged",
            tagPatternList = ["*"],
            countType      = "sinceImagePushed",
            countUnit      = "days",
            countNumber    = var.ecr.tagged_ttl_days
          },
          action = {
            type = "expire"
          }
        },
        {
          rulePriority = length(var.ecr.versioned_prefixes) + 3,
          description  = "Remove untagged images older than ${var.ecr.untagged_ttl_days} days",
          selection = {
            tagStatus   = "untagged",
            countType   = "sinceImagePushed",
            countUnit   = "days",
            countNumber = var.ecr.untagged_ttl_days
          },
          action = {
            type = "expire"
          }
        }
      ]
    )
  })
  tags = {
    Application = "${var.ecs_service_name}"
    Environment = "None"
  }
}

###############################################################################
# ROUTE 53 RECORDS
###############################################################################

# Route 53 record for main ALB
resource "aws_route53_record" "main_alb_record" {
  count   = var.application_load_balancer.enabled && var.application_load_balancer.route_53_host_zone_id != "" && var.application_load_balancer.host != "" ? 1 : 0
  zone_id = var.application_load_balancer.route_53_host_zone_id
  name    = var.application_load_balancer.host
  type    = "A"

  alias {
    name                   = data.aws_lb.main_alb[0].dns_name
    zone_id                = data.aws_lb.main_alb[0].zone_id
    evaluate_target_health = true
  }
}

# Route 53 records for additional ALBs
resource "aws_route53_record" "additional_alb_records" {
  for_each = {
    for idx, alb in var.additional_load_balancers : idx => alb
    if alb.enabled && alb.route_53_host_zone_id != "" && alb.host != ""
  }

  zone_id = each.value.route_53_host_zone_id
  name    = each.value.host
  type    = "A"

  alias {
    name                   = data.aws_lb.additional_albs[each.key].dns_name
    zone_id                = data.aws_lb.additional_albs[each.key].zone_id
    evaluate_target_health = true
  }
}

###############################################################################
# CLOUDFLARE DNS RECORDS
###############################################################################

# Cloudflare record for main ALB
resource "cloudflare_record" "main_alb_record" {
  count   = var.application_load_balancer.enabled && var.application_load_balancer.cloudflare_zone_id != "" && var.application_load_balancer.host != "" ? 1 : 0
  zone_id = var.application_load_balancer.cloudflare_zone_id
  name    = var.application_load_balancer.host
  value = data.aws_lb.main_alb_cloudflare[0].dns_name
  type    = "CNAME"
  ttl     = var.application_load_balancer.cloudflare_proxied ? 1 : var.application_load_balancer.cloudflare_ttl
  proxied = var.application_load_balancer.cloudflare_proxied
}

# Cloudflare records for additional ALBs
resource "cloudflare_record" "additional_alb_records" {
  for_each = {
    for idx, alb in var.additional_load_balancers : idx => alb
    if alb.enabled && alb.cloudflare_zone_id != "" && alb.host != ""
  }

  zone_id = each.value.cloudflare_zone_id
  name    = each.value.host
  value   = data.aws_lb.additional_albs_cloudflare[each.key].dns_name
  type    = "CNAME"
  ttl     = each.value.cloudflare_proxied ? 1 : each.value.cloudflare_ttl
  proxied = each.value.cloudflare_proxied
}
