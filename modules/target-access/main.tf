# Every rule here is additive and scoped to a single /32-narrow-as-possible
# source (the pentest subnet only) and a single port. `terraform destroy` on
# this module removes exactly these rules and nothing else on the target SGs -
# it never touches the SG resource itself, so it's safe to run against
# security groups this project doesn't own.

resource "aws_security_group_rule" "scoped_ingress" {
  for_each = var.target_rules

  type              = "ingress"
  security_group_id = each.value.security_group_id
  from_port         = each.value.port
  to_port           = each.value.port
  protocol          = "tcp"
  cidr_blocks       = [var.pentest_subnet_cidr]
  description       = "${var.project}: ${each.value.description}"
}