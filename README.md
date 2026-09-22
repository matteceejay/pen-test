# Pentest environment — staging, us-east-1

A reusable, teachable Terraform project for standing up a temporary,
isolated AWS pen-testing environment for a third-party vendor engagement.
This README walks through *what* each piece is, *why* it's built that way,
and *how* to actually run it end to end.

---

## 1. The mental model

The application you're testing (ALB, ASG/EC2, payment RDS) already exists
and keeps running the whole time. This project does **not** touch those
resources as resources — it only:

1. Builds a brand-new, isolated VPC with one private subnet and a NAT
   gateway for internet egress.
2. Drops a single EC2 box (the "pentest box") into that private subnet,
   reachable only through SSM — no SSH, no public IP, no inbound rules.
3. Peers that new VPC to the existing staging VPC so the box can reach the
   app over private IPs.
4. Adds a handful of narrow, additive ingress rules to the *existing*
   ALB/app/RDS security groups — scoped to the pentest subnet's CIDR only.
5. Watches the clock, and either alerts or automatically tears the whole
   thing down once the testing window closes.

If you remember nothing else: **everything this project creates is
disposable, and everything it touches on the app side is one line of
config it can cleanly remove.**

---

## 2. Project layout

pentest-environment/
├── modules/
│ ├── pentest-vpc/ isolated VPC, subnets, NAT, peering to staging
│ ├── pentest-instance/ the pentest EC2 box, IAM role, SG, SSM session logging
│ ├── target-access/ scoped ingress rules added to EXISTING target SGs
│ └── expiry-enforcer/ EventBridge + Lambda watchdog (alert or force-destroy)
├── environments/
│ └── staging-pentest-2026-09/ this engagement's wiring + tfvars
└── README.md


**Why modules + environments, instead of one flat set of files?** The
modules never change between pentest engagements — they're the reusable
part. Each new engagement just gets a new folder under `environments/`
with its own `terraform.tfvars` (different VPC, different testers, different
dates) and, critically, its own **state file**. That isolation means one
engagement's `terraform destroy` can never touch another engagement's
resources, even though they share the same module code.

---

## 3. What each module actually does

### `pentest-vpc`
Creates the VPC (`10.99.0.0/16` by default), a public subnet that exists
*only* to hold the NAT gateway, and a private subnet that holds the
pentest box. Also creates the VPC peering connection to staging and the
routes on both sides — the pentest subnet's route table gets a route to
the staging CIDR, and (this is the one place the module edits a resource
it doesn't fully own) the staging route table(s) you pass in get a single
route back to the pentest subnet.

### `pentest-instance`
The box itself: looks up the latest Ubuntu 22.04 AMI, creates a security
group with **no inbound rules at all** (SSM doesn't need any), and egress
only to HTTPS (for SSM/package repos via NAT) and the specific scan ports
into the staging CIDR. Also creates:
- The instance's own IAM role (SSM core policy + read-only Describe
  access to EC2/RDS/ELB/ASG for situational awareness).
- The CloudWatch log group and the account-level SSM session-logging
  document, so every session transcript is captured.
- Per-tester IAM policies that grant `ssm:StartSession` on **this instance
  ARN only** — nothing else.

### `target-access`
The smallest module. Takes a security group ID + port for each target and
adds one ingress rule scoped to the pentest subnet's CIDR. `terraform
destroy` on this module removes exactly those rules and nothing else —
it's safe to point at security groups this project doesn't otherwise own.

### `expiry-enforcer`
An EventBridge rule fires an hourly Lambda that compares the `Expiration`
timestamp to the current time. If it's past expiration:
- `force_destroy = false` (default): publishes an SNS email alert. Nothing
  is torn down.
- `force_destroy = true`: also terminates the pentest instance, revokes
  the target SG rules, and deletes the peering connection — directly via
  the AWS API, bypassing Terraform.

---

## 4. Prerequisites

Before you touch `terraform init`:

- [ ] An S3 bucket + DynamoDB table for remote state locking (or adjust
      `providers.tf` to use a backend you already have).
- [ ] The staging VPC's ID, CIDR, and the route table ID(s) used by the
      ALB/app/RDS subnets.
- [ ] The security group IDs for the ALB, the app tier (EC2/ASG), and the
      payment RDS instance.
- [ ] Dave (or whoever the tester is) already exists as an IAM user in
      this account — this project grants access to an existing user, it
      doesn't create one.
- [ ] An email address to receive expiry alerts (you'll need to confirm
      the SNS subscription after the first `apply`).
- [ ] Terraform >= 1.6 and AWS credentials with permission to create
      VPCs, EC2, IAM, Lambda, EventBridge, SNS, and CloudWatch resources.

---

## 5. Step-by-step execution

```bash
cd environments/staging-pentest-2026-09

# 1. Fill in your real values
cp terraform.tfvars.example terraform.tfvars
#    edit terraform.tfvars: replace every REPLACE_ME with your actual
#    vpc-..., rtb-..., and sg-... IDs, your alert email, and the
#    engagement's expiration timestamp

# 2. Point the backend at your real state bucket
#    edit providers.tf: set the S3 bucket + DynamoDB table names

# 3. Initialize - this downloads the aws and archive providers
terraform init

# 4. Review the plan carefully before applying
terraform plan

# 5. Apply
terraform apply
```

**What to check in the plan output before you type `yes`:**
- The peering connection and its two routes are both present (one route
  in the pentest subnet, and one route per staging route table you
  listed).
- Exactly 5 `aws_security_group_rule` resources are being *added* on the
  target side (2 for ALB, 2 for the app tier, 1 for RDS) — nothing on
  those security groups should show as changed or destroyed.
- `force_destroy` is `false` unless you've deliberately decided otherwise.

**After `apply` succeeds:**
1. Check your inbox for the SNS subscription confirmation email and
   click confirm — until you do, expiry alerts won't reach you.
2. Confirm Dave can connect:
```bash
   aws ssm start-session --target <pentest_instance_id>
```
   (get the instance ID from `terraform output pentest_instance_id`)
3. Confirm the session shows up in CloudWatch Logs under the log group
   from `terraform output ssm_session_log_group`.

---

## 6. During the engagement

- Sessions log automatically — no action needed. Check the log group any
  time you want to see what's been run.
- If the vendor needs a port or target added mid-engagement, add an entry
  to the `target_rules` map in `main.tf` (or a new tester to `testers` in
  `terraform.tfvars`) and run `terraform apply` again — it only adds the
  new rule, it won't touch anything already running.
- The expiry watchdog runs hourly regardless of what else happens. You
  can check its last run in CloudWatch Logs under
  `/aws/lambda/<project>-pentest-expiry-watchdog`.

---

## 7. Ending the engagement

Once remediation and retesting are signed off:

```bash
cd environments/staging-pentest-2026-09
terraform destroy
```

This removes the pentest box, VPC, peering connection, IAM roles, the
target SG rules, and the watchdog infrastructure — in that order,
following the dependency graph Terraform already knows. Nothing about
the ALB, app tier, or RDS themselves is touched.

**If the watchdog already force-destroyed things** (because `force_destroy`
was `true` and the window lapsed before you ran `destroy` manually), state
will be out of sync with reality. Reconcile first:

```bash
terraform apply -refresh-only
terraform destroy
```

---

## 8. Two gotchas worth remembering

**SSM session logging is account-wide, not per-instance.** The
`SSM-SessionManagerRunShell` document this project creates sets the
Session Manager logging *preference for the whole account/region* — every
SSM session anyone runs will log to this CloudWatch group, not just
Dave's. That's usually a feature, but check with other teams before
applying to a shared account.

**`force_destroy = true` bypasses Terraform state entirely.** The Lambda
calls the AWS API directly. Terraform won't know the resources are gone
until you run `terraform apply -refresh-only`. Start every new engagement
with `force_destroy = false`, watch the alert-only behavior for a cycle,
and only flip it once you trust it.

---

## 9. Reusing this for the next engagement

```bash
cp -r environments/staging-pentest-2026-09 environments/<new-engagement-name>
```

Then in the new folder:
1. Change the `key` in `providers.tf` to a new, unique state path.
2. Update `terraform.tfvars` with the new engagement's scope, testers,
   and dates.
3. `terraform init && terraform plan && terraform apply`

The modules don't change — this is the whole point of separating them
from the environment wiring.