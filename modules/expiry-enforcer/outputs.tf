output "lambda_function_name" {
  value = aws_lambda_function.expiry_watchdog.function_name
}

output "sns_topic_arn" {
  value = aws_sns_topic.expiry_alerts.arn
}