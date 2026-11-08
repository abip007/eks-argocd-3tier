#!/usr/bin/env bash
# Step 0 - fill the double-underscore placeholders in gitops/ and platform/ with your real
# values (account ID, region, hosts, certificate, Git URL), so Argo CD reads
# real values from Git. Requests + DNS-validates the ACM certificate if needed.
# Run once, then commit and push. Safe to re-run (only replaces placeholders).
source "$(dirname "$0")/lib.sh"
need aws sed grep

say "Account and certificate"
ACCOUNT_ID=$(account_id)
echo "  account $ACCOUNT_ID, region $AWS_REGION, cluster $CLUSTER"

[ -n "$CERT_ARN" ] || CERT_ARN=$(find_cert)
if [ -z "$CERT_ARN" ]; then
  echo "  no ISSUED certificate for $DOMAIN - requesting one (DNS validation in Route 53)"
  CERT_ARN=$(aws acm request-certificate --region "$AWS_REGION" --domain-name "$DOMAIN" \
    --subject-alternative-names "*.$DOMAIN" --validation-method DNS \
    --query CertificateArn --output text)
  ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query 'HostedZones[0].Id' --output text)
  # The validation record shows up a few seconds after the request.
  for _ in $(seq 1 12); do
    REC=$(aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$CERT_ARN" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]' --output text)
    [ "$REC" != "None" ] && [ -n "$REC" ] && break; sleep 5
  done
  read -r RNAME RVALUE <<<"$REC"
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch \
    "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$RNAME\",\"Type\":\"CNAME\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$RVALUE\"}]}}]}" >/dev/null
  echo "  waiting for ACM validation (usually 1-5 min)..."
  aws acm wait certificate-validated --region "$AWS_REGION" --certificate-arn "$CERT_ARN"
fi
echo "  certificate $CERT_ARN"

say "Filling placeholders"
FILES=$(grep -rl '__[A-Z0-9_]*__' gitops platform eksctl 2>/dev/null || true)
[ -n "$FILES" ] || { echo "  nothing to do - already configured"; exit 0; }
for f in $FILES; do
  sed -i \
    -e "s|__ACCOUNT_ID__|$ACCOUNT_ID|g" -e "s|__REGION__|$AWS_REGION|g" \
    -e "s|__CLUSTER__|$CLUSTER|g"       -e "s|__K8S_VERSION__|$K8S_VERSION|g" \
    -e "s|__NODE_TYPE__|$NODE_TYPE|g"   -e "s|__NODE_MIN__|$NODE_MIN|g" -e "s|__NODE_MAX__|$NODE_MAX|g" \
    -e "s|__VPC_CIDR__|$VPC_CIDR|g"     -e "s|__DOMAIN__|$DOMAIN|g" \
    -e "s|__APP_HOST__|$APP_HOST|g"     -e "s|__ARGOCD_HOST__|$ARGOCD_HOST|g" \
    -e "s|__CERT_ARN__|$CERT_ARN|g"     -e "s|__GIT_REPO_URL__|$GIT_REPO_URL|g" "$f"
  echo "  $f"
done
LEFT=$(grep -rn '__[A-Z0-9_]*__' gitops platform eksctl || true)
[ -z "$LEFT" ] || die "unreplaced placeholders:\n$LEFT"

cat <<EOF

Done. Argo CD reads these values from Git, so commit and push them now:
  git add -A && git commit -m "Configure for $CLUSTER" && git push
EOF
