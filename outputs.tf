output "ecs_service_name" {
  value = aws_ecs_service.ecs_service.name
}
output "ecs_task_definition_arn" {
  value = aws_ecs_task_definition.task_definition.arn
}

output "cloudwatch_log_group_name" {
  value = aws_cloudwatch_log_group.ecs_log_group.name
}

output "route53_records" {
  description = "Route53 DNS records created"
  value = {
    main_record = var.application_load_balancer.enabled && var.application_load_balancer.route_53_host_zone_id != "" && var.application_load_balancer.host != "" ? {
      name    = aws_route53_record.main_alb_record[0].name
      fqdn    = aws_route53_record.main_alb_record[0].fqdn
      zone_id = aws_route53_record.main_alb_record[0].zone_id
    } : null
    additional_records = {
      for idx, record in aws_route53_record.additional_alb_records : idx => {
        name    = record.name
        fqdn    = record.fqdn
        zone_id = record.zone_id
      }
    }
  }
}

output "cloudflare_records" {
  description = "Cloudflare DNS records created"
  value = {
    main_record = var.application_load_balancer.enabled && var.application_load_balancer.cloudflare_zone_id != "" && var.application_load_balancer.host != "" ? {
      name    = cloudflare_record.main_alb_record[0].name
      value   = cloudflare_record.main_alb_record[0].value
      zone_id = cloudflare_record.main_alb_record[0].zone_id
      proxied = cloudflare_record.main_alb_record[0].proxied
      type    = cloudflare_record.main_alb_record[0].type
    } : null
    additional_records = {
      for idx, record in cloudflare_record.additional_alb_records : idx => {
        name    = record.name
        value   = record.value
        zone_id = record.zone_id
        proxied = record.proxied
        type    = record.type
      }
    }
  }
}

output "efs_file_system_id" {
  description = "ID of the EFS filesystem (null when efs is disabled)"
  value       = local.efs_enabled ? aws_efs_file_system.this[0].id : null
}

output "efs_access_point_id" {
  description = "ID of the EFS access point (null when efs is disabled)"
  value       = local.efs_enabled ? aws_efs_access_point.this[0].id : null
}

output "efs_security_group_id" {
  description = "ID of the security group attached to the EFS mount targets (null when efs is disabled)"
  value       = local.efs_enabled ? aws_security_group.efs[0].id : null
}
