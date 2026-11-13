#!/usr/bin/env bash
# DNS stays in its own state. Registrar delegation is done manually once.
set -euo pipefail
terraform -chdir=dns output -json > .deploy/dns-outputs.json
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo '## DNS delegation'
    echo "Domain: $CUSTOM_DOMAIN"
    echo 'Configure these NS at the parent DNS provider if not already delegated:'
    jq -r '.name_servers.value[] | "- " + .' .deploy/dns-outputs.json
  } >> "$GITHUB_STEP_SUMMARY"
fi
printf 'Domain: %s\nNS to configure at the parent DNS provider:\n' "$CUSTOM_DOMAIN"
jq -r '.name_servers.value[]' .deploy/dns-outputs.json
certificate=$(jq -er '.certificate_arn.value' .deploy/dns-outputs.json)
for _ in $(seq 1 30); do
  status=$(aws acm describe-certificate --region us-east-1 --certificate-arn "$certificate" --query Certificate.Status --output text)
  case "$status" in
    ISSUED) echo 'Certificate issued: custom domain can be attached to CloudFront.'; exit 0 ;;
    PENDING_VALIDATION) sleep 10 ;;
    *) echo "Certificate cannot be used: $status" >&2; exit 1 ;;
  esac
done
echo 'Certificate still pending. Configure/verify NS delegation at the parent DNS provider, wait for propagation, then rerun the infrastructure workflow. EKS provisioning has not started in this run.' >&2
exit 1
