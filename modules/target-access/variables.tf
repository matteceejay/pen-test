variable "project" {
  type = string
}

variable "pentest_subnet_cidr" {
  description = "CIDR of the pentest private subnet - the only source these rules allow"
  type        = string
}

variable "target_rules" {
  description = "Ingress rules to add to existing target security groups, keyed by a short label"
  type = map(object({
    security_group_id = string
    port               = number
    description        = string
  }))
  # example:
  # {
  #   alb_https = { security_group_id = "sg-0123", port = 443, description = "ALB - HTTPS scan" }
  #   rds_mysql = { security_group_id = "sg-0456", port = 3306, description = "RDS - MySQL scan" }
  # }
}