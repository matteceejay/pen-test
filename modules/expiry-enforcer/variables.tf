variable "project" {
  type = string
}

variable "instance_id" {
  description = "Pentest EC2 instance ID to watch"
  type        = string
}

variable "peering_connection_id" {
  description = "VPC peering connection ID to tear down on force-destroy"
  type        = string
}

variable "expiration" {
  description = "RFC3339 timestamp after which the environment is considered expired, e.g. 2026-09-26T00:00:00Z"
  type        = string
}

variable "target_sg_rules" {
  description = "The same rules granted by the target-access module, so the watchdog can revoke them on force-destroy"
  type = list(object({
    security_group_id = string
    port               = number
  }))
  default = []
}

variable "force_destroy" {
  description = "false (default) = alert only via SNS. true = also terminate the instance, delete the peering connection, and revoke the target SG rules."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email address subscribed to the expiration SNS topic"
  type        = string
}

variable "check_schedule" {
  description = "EventBridge schedule expression for how often to check"
  type        = string
  default     = "rate(1 hour)"
}

variable "tags" {
  type = map(string)
}