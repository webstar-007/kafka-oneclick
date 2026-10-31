#!/usr/bin/env bash
# SCRIPT 1 of 2: is my laptop ready for the one click?
# It only READS things. It never creates or changes anything.
# Run it from the project folder:   ./scripts/check-ready.sh
# It may ask for your sudo password once (to look inside Jenkins' folder).

REGION="${REGION:-us-east-1}"
JOB="${JOB:-kafka-oneclick}"
FAIL=0; WARN=0
ok()   { echo "  [ OK ]  $1"; }
bad()  { echo "  [FAIL]  $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN]  $1"; WARN=$((WARN+1)); }
has()  { command -v "$1" >/dev/null 2>&1; }

echo "1. Tools on this laptop"
for t in terraform ansible aws git ssh curl; do
  if has "$t"; then ok "$t installed"; else bad "$t is NOT installed"; fi
done
has terraform && ok "$(terraform version 2>/dev/null | head -1)"
has ansible   && ok "$(ansible --version 2>/dev/null | head -1)"
has aws       && ok "$(aws --version 2>&1 | cut -d' ' -f1)"

echo "2. AWS account (the one Terraform will use)"
if ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null); then
  ok "AWS login works: $ARN"
else
  bad "AWS login does not work (run: aws configure)"
fi
# A "dry run" asks AWS: would this be allowed? It creates nothing.
if aws ec2 create-vpc --cidr-block 10.99.0.0/16 --dry-run --region "$REGION" 2>&1 | grep -q "DryRunOperation"; then
  ok "your AWS user is allowed to create a VPC (permissions look fine)"
else
  bad "your AWS user is NOT allowed to create resources (give the IAM user AdministratorAccess)"
fi
N=$(aws ec2 describe-instance-type-offerings --region "$REGION" --location-type availability-zone \
    --filters Name=instance-type,Values=t3.small --query 'length(InstanceTypeOfferings)' --output text 2>/dev/null || echo 0)
if [ "$N" -ge 3 ] 2>/dev/null; then ok "t3.small is available in $N zones of $REGION"; else bad "t3.small is offered in fewer than 3 zones of $REGION"; fi

echo "3. Leftovers from an earlier run (must be empty)"
if aws ec2 describe-key-pairs --region "$REGION" --key-names kafka-demo-key >/dev/null 2>&1; then
  bad "key pair kafka-demo-key already exists (run Jenkins ACTION=destroy, or delete it in EC2 > Key Pairs)"
else
  ok "no old key pair"
fi
C=$(aws ec2 describe-instances --region "$REGION" --filters Name=tag:Project,Values=kafka-demo Name=instance-state-name,Values=pending,running,stopping,stopped --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo "?")
if [ "$C" = "0" ]; then ok "no old kafka-demo servers"; else bad "found $C old kafka-demo servers (destroy them first)"; fi

echo "4. Jenkins"
if systemctl is-active --quiet jenkins 2>/dev/null; then ok "Jenkins service is running"; else bad "Jenkins service is not running (sudo systemctl start jenkins)"; fi
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/login 2>/dev/null)
if [ "$CODE" = "200" ] || [ "$CODE" = "403" ]; then ok "Jenkins answers on http://localhost:8080"; else bad "Jenkins does not answer on port 8080 (got '$CODE')"; fi
echo "     (the next checks use sudo to look at the Jenkins user)"
if sudo -u jenkins bash -c 'command -v terraform && command -v ansible-playbook && command -v aws && command -v ssh && command -v curl' >/dev/null 2>&1; then
  ok "the jenkins user can run terraform, ansible, aws, ssh and curl"
else
  bad "the jenkins user cannot find one of terraform, ansible-playbook, aws, ssh, curl"
fi
if sudo grep -q "<id>aws-creds</id>" /var/lib/jenkins/credentials.xml 2>/dev/null; then
  ok "Jenkins credential with ID aws-creds exists"
else
  bad "Jenkins credential aws-creds NOT found (Manage Jenkins > Credentials > add 'Username with password', ID aws-creds)"
fi
for p in workflow-aggregator git credentials-binding; do
  if sudo test -d /var/lib/jenkins/plugins/$p 2>/dev/null; then ok "Jenkins plugin $p installed"; else warn "Jenkins plugin $p not found (Manage Jenkins > Plugins)"; fi
done

echo "5. Ports on this laptop"
if ss -ltn "sport = :18080" 2>/dev/null | grep -q LISTEN; then
  warn "port 18080 is busy. If it is an old Kafka UI tunnel, the pipeline replaces it. Otherwise free the port."
else
  ok "port 18080 is free (Kafka UI will use it)"
fi
if ss -ltn "sport = :8080" 2>/dev/null | grep -q LISTEN; then ok "port 8080 is Jenkins (expected, no clash)"; fi

echo "6. Git and GitHub"
if [ -n "$(git config --global user.name)" ] && [ -n "$(git config --global user.email)" ]; then ok "git user name and email are set"; else bad "set them: git config --global user.name \"Your Name\"; git config --global user.email \"you@example.com\""; fi
if curl -s -o /dev/null -m 8 -I https://github.com; then ok "github.com is reachable"; else bad "github.com is not reachable"; fi
if git remote get-url origin >/dev/null 2>&1; then ok "this folder has a GitHub remote: $(git remote get-url origin)"; else warn "no GitHub remote yet (you create it in the setup guide, step 2)"; fi

echo
echo "Remember to check by hand: the GitHub repository exists, and (if it is private) Jenkins has a github-token credential."
echo
if [ $FAIL -eq 0 ]; then
  echo "RESULT: READY. ($WARN warnings) You can follow docs/02-SETUP-GUIDE.md"
else
  echo "RESULT: NOT READY. $FAIL problem(s). Fix every [FAIL] line and run this script again."
fi
exit $FAIL
