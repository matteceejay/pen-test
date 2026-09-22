import json
import os
from datetime import datetime, timezone

import boto3  # pyright: ignore[reportMissingImports]

ec2 = boto3.client("ec2")
sns = boto3.client("sns")

PROJECT = os.environ["PROJECT"]
INSTANCE_ID = os.environ["INSTANCE_ID"]
PEERING_CONNECTION_ID = os.environ["PEERING_CONNECTION_ID"]
EXPIRATION = os.environ["EXPIRATION"]
TARGET_SG_RULES = json.loads(os.environ.get("TARGET_SG_RULES", "[]"))
FORCE_DESTROY = os.environ.get("FORCE_DESTROY", "false").lower() == "true"
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]


def handler(event, context):
    now = datetime.now(timezone.utc)
    expiration = datetime.fromisoformat(EXPIRATION.replace("Z", "+00:00"))

    if now < expiration:
        print(f"[{PROJECT}] not yet expired (expires {EXPIRATION}), nothing to do")
        return {"expired": False}

    print(f"[{PROJECT}] EXPIRED as of {EXPIRATION} - current time {now.isoformat()}")

    if not FORCE_DESTROY:
        _notify(
            subject=f"[pentest] {PROJECT} environment is past its expiration window",
            message=(
                f"The pentest environment for '{PROJECT}' expired at {EXPIRATION} and is "
                f"still running (instance {INSTANCE_ID}). force_destroy is not enabled, so "
                f"nothing was torn down automatically. Run `terraform destroy` for this "
                f"engagement, or set force_destroy = true to let this watchdog do it."
            ),
        )
        return {"expired": True, "force_destroyed": False}

    errors = []

    try:
        ec2.terminate_instances(InstanceIds=[INSTANCE_ID])
        print(f"terminated instance {INSTANCE_ID}")
    except Exception as e:
        errors.append(f"terminate_instances: {e}")

    for rule in TARGET_SG_RULES:
        try:
            ec2.revoke_security_group_ingress(
                GroupId=rule["security_group_id"],
                IpPermissions=[
                    {
                        "IpProtocol": "tcp",
                        "FromPort": rule["port"],
                        "ToPort": rule["port"],
                        "IpRanges": [{"CidrIp": rule.get("pentest_subnet_cidr", "0.0.0.0/32")}],
                    }
                ],
            )
            print(f"revoked ingress on {rule['security_group_id']} port {rule['port']}")
        except Exception as e:
            errors.append(f"revoke_security_group_ingress {rule}: {e}")

    try:
        ec2.delete_vpc_peering_connection(VpcPeeringConnectionId=PEERING_CONNECTION_ID)
        print(f"deleted peering connection {PEERING_CONNECTION_ID}")
    except Exception as e:
        errors.append(f"delete_vpc_peering_connection: {e}")

    subject = f"[pentest] {PROJECT} environment FORCE-DESTROYED past expiration"
    message = (
        f"The pentest environment for '{PROJECT}' expired at {EXPIRATION}. This watchdog "
        f"terminated the instance, revoked the target security group rules, and deleted "
        f"the peering connection.\n\n"
        f"IMPORTANT: this bypassed Terraform, so state is now out of sync. Run "
        f"`terraform apply -refresh-only` (or `terraform destroy`) for this engagement's "
        f"environment to reconcile state before reusing this module.\n\n"
        f"Errors during cleanup: {errors if errors else 'none'}"
    )
    _notify(subject, message)

    return {"expired": True, "force_destroyed": True, "errors": errors}


def _notify(subject, message):
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=message)