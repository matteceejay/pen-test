data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_sns_topic" "expiry_alerts" {
  name              = "${var.project}-pentest-expiry-alerts"
  kms_master_key_id = aws_kms_key.expiry_alerts.arn
  tags              = var.tags
}

resource "aws_kms_key" "expiry_alerts" {
  description         = "Encrypts SNS notifications for ${var.project}"
  enable_key_rotation = true
  tags                = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.expiry_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_iam_role" "lambda" {
  name = "${var.project}-pentest-expiry-watchdog"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_actions" {
  name = "${var.project}-expiry-watchdog-actions"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeVpcPeeringConnections"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "ec2:TerminateInstances"
        Resource = "arn:aws:ec2:*:*:instance/${var.instance_id}"
      },
      {
        Effect   = "Allow"
        Action   = "ec2:RevokeSecurityGroupIngress"
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Project" = var.project
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DeleteVpcPeeringConnection"
        Resource = "arn:aws:ec2:*:*:vpc-peering-connection/${var.peering_connection_id}"
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.expiry_alerts.arn
      }
    ]
  })
}

resource "aws_lambda_function" "expiry_watchdog" {
  function_name    = "${var.project}-pentest-expiry-watchdog"
  role              = aws_iam_role.lambda.arn
  handler           = "index.handler"
  runtime           = "python3.12"
  timeout           = 30
  filename          = data.archive_file.lambda.output_path
  source_code_hash  = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      PROJECT                = var.project
      INSTANCE_ID             = var.instance_id
      PEERING_CONNECTION_ID   = var.peering_connection_id
      EXPIRATION              = var.expiration
      FORCE_DESTROY            = tostring(var.force_destroy)
      SNS_TOPIC_ARN            = aws_sns_topic.expiry_alerts.arn
      TARGET_SG_RULES          = jsonencode(var.target_sg_rules)
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "${var.project}-pentest-expiry-check"
  schedule_expression = var.check_schedule
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.schedule.name
  arn  = aws_lambda_function.expiry_watchdog.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.expiry_watchdog.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}