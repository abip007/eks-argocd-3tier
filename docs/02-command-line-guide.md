# Build everything from the command line (step by step)

This guide does exactly what `scripts/00-…` to `scripts/99-…` do, but **one command at a
time**, and explains what each command does and how to check it worked. Use it to learn
what the scripts automate, or to debug a step that failed inside a script.

> **Use one path only.** The console guide, the scripts, this guide and Terraform all create
> resources with the same names (`argo-eks-*`). Following this guide *is* the shell path, done by
> hand. You can switch between this guide and the scripts at any step, because every command
> here is safe to run again.

Run everything in **Git Bash** from the repo root (`C:/DevOps/eks-argocd-3tier`).
PowerShell won't work: the commands use bash syntax (`$VAR`, `$(...)`, `\` line breaks).

---

## Contents

- [Step 0: Tools and a terminal session](#step-0-tools-and-a-terminal-session) (includes the IAM user, and how IAM is used)
- [Step 1: Load the settings](#step-1-load-the-settings)
- [Step 2: Check your AWS identity and clock](#step-2-check-your-aws-identity-and-clock) (includes the Route 53 hosted zone and delegation)
- [Step 3: ACM certificate](#step-3-acm-certificate-script-00-configuresh)
- [Step 4: Fill the placeholders and push to Git](#step-4-fill-the-placeholders-and-push-to-git-script-00-configuresh)
- [Step 5: IAM policies for the controllers](#step-5-iam-policies-for-the-controllers-script-01-create-clustersh)
- [Step 6: ECR repositories](#step-6-ecr-repositories-script-01-create-clustersh)
- [Step 7: Create the EKS cluster with eksctl](#step-7-create-the-eks-cluster-with-eksctl-script-01-create-clustersh)
- [Step 8: Connect kubectl](#step-8-connect-kubectl)
- [Step 9: Default StorageClass gp3](#step-9-default-storageclass-gp3-script-02-install-platformsh)
- [Step 10: Gateway API CRDs](#step-10-gateway-api-crds-script-02-install-platformsh)
- [Step 11: AWS Load Balancer Controller](#step-11-aws-load-balancer-controller-script-02-install-platformsh)
- [Step 12: ExternalDNS](#step-12-externaldns-script-02-install-platformsh)
- [Step 13: Argo CD](#step-13-argo-cd-script-02-install-platformsh)
- [Step 14: App namespace and secrets](#step-14-app-namespace-and-secrets-script-02-install-platformsh)
- [Step 15: Build and push the images](#step-15-build-and-push-the-images-script-03-releasesh)
- [Step 16: Point Git at the new tag](#step-16-point-git-at-the-new-tag-script-03-releasesh)
- [Step 17: Create the Argo CD root app](#step-17-create-the-argo-cd-root-app-script-02-install-platformsh)
- [Step 18: Verify end to end](#step-18-verify-end-to-end)
- [Day 2: Release a new version](#day-2-release-a-new-version)
- [Useful commands for exploring](#useful-commands-for-exploring)
- [Troubleshooting](#troubleshooting)
- [Clean up](#clean-up-script-99-destroysh)
- [Appendix: build the cluster without eksctl (plain AWS CLI)](#appendix-build-the-cluster-without-eksctl-plain-aws-cli): VPC, subnets, NAT, IAM roles, EKS, node group, add-ons, Pod Identity

---

## Step 0: Tools and a terminal session

Install these once (PowerShell, `winget`):

```powershell
winget install Amazon.AWSCLI Kubernetes.kubectl Helm.Helm eksctl Docker.DockerDesktop Git.Git
```

Then open **Git Bash** and check that every tool is on your PATH:

```bash
aws --version          # aws-cli/2.x
kubectl version --client
helm version           # v3.x
eksctl version
docker version         # the "Server" part must show; start Docker Desktop if it doesn't
git --version
openssl version
```

The scripts check for these tools with `need aws kubectl helm …` in [scripts/lib.sh](../scripts/lib.sh).

### 0.1 IAM user for the CLI (once per account)

Don't use root access keys for this project. Create an IAM user once, while signed in as an
admin (in CloudShell, or with a profile that already has admin rights):

```bash
aws iam create-user --user-name abip007
# Learning account: full admin. For a shared account, use a narrower policy.
aws iam attach-user-policy --user-name abip007 --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam create-access-key --user-name abip007     # shows AccessKeyId + SecretAccessKey ONCE - copy them now
```

Store the keys in a named profile on your PC:

```bash
aws configure --profile abip007home   # access key, secret key, region ap-south-1, output json
aws sts get-caller-identity --profile abip007home
```

Why it matters: **the IAM identity that creates the cluster becomes its first Kubernetes admin**
(`bootstrapClusterCreatorAdminPermissions`). If you create the cluster with one profile and run
kubectl with another, you get `Unauthorized`. See [Step 8.1](#81-who-can-use-the-cluster-iam--kubernetes)
to give access to more users or roles.

### 0.2 How IAM is used in this project

Four kinds of IAM identities get involved. Knowing which is which helps you debug permission errors:

| Who | IAM identity | Created by | Used for |
| --- | --- | --- | --- |
| You | IAM user `abip007` (profile `abip007home`) | you, Step 0.1 | every `aws`, `eksctl`, `kubectl` and `helm` command |
| EKS control plane | role `eksctl-argo-eks-cluster-ServiceRole-…` | eksctl | lets EKS manage ENIs and load balancers for the control plane |
| Worker nodes (EC2) | role `eksctl-argo-eks-nodegroup-general-NodeInstanceRole-…` | eksctl | lets the kubelet join the cluster, pull images from ECR and run the VPC CNI |
| Pods (controllers) | Pod Identity roles for `aws-load-balancer-controller`, `external-dns`, `ebs-csi-controller-sa` | eksctl, from `iam.podIdentityAssociations` | lets those pods call ELB, Route 53 and EC2 (EBS) |

Pod Identity works like this: the `eks-pod-identity-agent` DaemonSet hands temporary
credentials for the linked role to any pod that runs as that **namespace + service account**.
No access keys are stored in the cluster.

---

## Step 1: Load the settings

Every script starts by sourcing [scripts/config.env](../scripts/config.env). Do the same in your shell
so that `$CLUSTER`, `$AWS_REGION` and the other settings exist for every command below.

```bash
cd /c/DevOps/eks-argocd-3tier
source scripts/config.env

# Same private Helm cache the scripts use (avoids "no cached repo found" on Windows)
export HELM_REPOSITORY_CONFIG="$PWD/.helm/repositories.yaml"
export HELM_REPOSITORY_CACHE="$PWD/.helm/cache"
mkdir -p .helm/cache
```

Print the settings to confirm them:

```bash
for v in AWS_PROFILE AWS_REGION CLUSTER K8S_VERSION NODE_TYPE DOMAIN APP_HOST ARGOCD_HOST GIT_REPO_URL GIT_BRANCH; do
  printf '%-14s %s\n' "$v" "${!v}"
done
```

**How it works:** `config.env` uses `: "${VAR:=default}"`. That sets a value only if the
variable is still empty, so a value you export first wins:

```bash
CLUSTER=test-eks source scripts/config.env && echo $CLUSTER   # -> test-eks
```

> If you open a new Git Bash window later, run Step 1 again. Variables don't carry over
> between windows.

---

## Step 2: Check your AWS identity and clock

```bash
aws sts get-caller-identity
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "$ACCOUNT_ID"
```

`Arn` should be your IAM user (`…:user/abip007`), not `…:root`. **The identity that creates the
cluster becomes its first admin**, so use the same profile in every step.

Then check your PC's clock against AWS. This is `check_clock` in `lib.sh`:

```bash
AWS_DATE=$(curl -sI "https://sts.$AWS_REGION.amazonaws.com" | tr -d '\r' | awk -F': ' 'tolower($1)=="date"{print $2}')
echo "skew: $(( $(date -u +%s) - $(date -u -d "$AWS_DATE" +%s) )) s"
```

Anything above about 5 seconds will break Step 11. Helm signs the LB Controller's webhook
certificate with *your* clock, and a certificate from the future is "not yet valid". To fix it,
run this in **admin PowerShell**: `Start-Service w32time; w32tm /resync /force`.

### 2.1 Route 53 hosted zone (and delegation)

Two things need a **public hosted zone** for `bestclick.click` in this account: ACM validation
(Step 3) and ExternalDNS (Step 12). Check whether you have one:

```bash
aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
  --query "HostedZones[?Name=='$DOMAIN.'].[Id,Name,Config.PrivateZone,ResourceRecordSetCount]" --output table
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query "HostedZones[?Name=='$DOMAIN.'].Id | [0]" --output text)
echo "$ZONE_ID"            # /hostedzone/Z0123... ; PrivateZone must be False
```

**No zone?** Create one. If you registered the domain with **Route 53 Domains**, AWS created the
zone for you when you registered.

```bash
ZONE_ID=$(aws route53 create-hosted-zone --name "$DOMAIN" --caller-reference "$(date +%s)" \
  --hosted-zone-config Comment="public zone for $DOMAIN" --query HostedZone.Id --output text)
```

**Delegation.** The registrar must point the domain at the zone's four name servers. If it
doesn't, nothing in the zone is visible on the internet: ACM validation hangs and the app URL never resolves.

```bash
# The name servers the zone uses
aws route53 get-hosted-zone --id "$ZONE_ID" --query DelegationSet.NameServers --output text
# The name servers the internet actually uses for the domain
nslookup -type=NS "$DOMAIN" 8.8.8.8
# If the domain is in Route 53 Domains (this API only exists in us-east-1):
aws route53domains get-domain-detail --region us-east-1 --domain-name "$DOMAIN" --query Nameservers[].Name
```

The two lists must be the same set of `ns-…awsdns-…` names. If they differ, update the name
servers at your registrar. For Route 53 Domains:

```bash
NS=$(aws route53 get-hosted-zone --id "$ZONE_ID" --query 'DelegationSet.NameServers' --output text)
aws route53domains update-domain-nameservers --region us-east-1 --domain-name "$DOMAIN" \
  --nameservers $(for n in $NS; do printf 'Name=%s ' "$n"; done)
```

Look at what's in the zone (later steps add records here):

```bash
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query 'ResourceRecordSets[].[Name,Type,TTL]' --output table
```

Expect `NS` and `SOA` now, then the ACM `_xxxx` CNAME after Step 3, and then `argocd`, `argo-bmi` (A)
plus their ExternalDNS ownership TXT records after Steps 13 and 17.

---

## Step 3: ACM certificate (script: 00-configure.sh)

The ALB needs a certificate that covers both `bestclick.click` and `*.bestclick.click`, which
includes `argo-bmi.` and `argocd.`.

**3.1 Look for an existing certificate** (this is `find_cert` in `lib.sh`):

```bash
CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" --certificate-statuses ISSUED \
  --query "CertificateSummaryList[?DomainName=='$DOMAIN' || DomainName=='*.$DOMAIN'].CertificateArn | [0]" \
  --output text | grep -v '^None$')
echo "${CERT_ARN:-none found}"
```

If you got an ARN, skip to Step 4.

**3.2 Otherwise, request one** with DNS validation:

```bash
CERT_ARN=$(aws acm request-certificate --region "$AWS_REGION" \
  --domain-name "$DOMAIN" --subject-alternative-names "*.$DOMAIN" \
  --validation-method DNS --query CertificateArn --output text)
echo "$CERT_ARN"
```

**3.3 Prove you own the domain.** ACM gives you one CNAME record to create in Route 53. It
appears a few seconds after the request, so run the `describe` again if it prints `None`:

```bash
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query 'HostedZones[0].Id' --output text)
read -r RNAME RVALUE <<<"$(aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]' --output text)"
echo "zone=$ZONE_ID  name=$RNAME  value=$RVALUE"

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch \
  "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$RNAME\",\"Type\":\"CNAME\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$RVALUE\"}]}}]}"
```

`bestclick.click` and `*.bestclick.click` share the same validation record, so one CNAME is enough.

**3.4 Wait** (usually 1–5 minutes):

```bash
aws acm wait certificate-validated --region "$AWS_REGION" --certificate-arn "$CERT_ARN"
aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$CERT_ARN" --query Certificate.Status   # "ISSUED"
```

---

## Step 4: Fill the placeholders and push to Git (script: 00-configure.sh)

The YAML in `gitops/`, `platform/` and `eksctl/` is shipped with placeholders like
`__ACCOUNT_ID__`. **Argo CD reads the files from GitHub, not from your PC**, so the real values
must be committed.

**4.1 Find what still needs a value:**

```bash
grep -rn '__[A-Z0-9_]*__' gitops platform eksctl
```

No output means the files are already configured (true in this repo since commit `c73f06b`),
so skip to Step 5.

**4.2 Replace the placeholders** in every file that has them:

```bash
for f in $(grep -rl '__[A-Z0-9_]*__' gitops platform eksctl); do
  sed -i \
    -e "s|__ACCOUNT_ID__|$ACCOUNT_ID|g" -e "s|__REGION__|$AWS_REGION|g" \
    -e "s|__CLUSTER__|$CLUSTER|g"       -e "s|__K8S_VERSION__|$K8S_VERSION|g" \
    -e "s|__NODE_TYPE__|$NODE_TYPE|g"   -e "s|__NODE_MIN__|$NODE_MIN|g" -e "s|__NODE_MAX__|$NODE_MAX|g" \
    -e "s|__VPC_CIDR__|$VPC_CIDR|g"     -e "s|__DOMAIN__|$DOMAIN|g" \
    -e "s|__APP_HOST__|$APP_HOST|g"     -e "s|__ARGOCD_HOST__|$ARGOCD_HOST|g" \
    -e "s|__CERT_ARN__|$CERT_ARN|g"     -e "s|__GIT_REPO_URL__|$GIT_REPO_URL|g" "$f"
  echo "filled $f"
done
grep -rn '__[A-Z0-9_]*__' gitops platform eksctl || echo "all placeholders filled"
```

`sed -i` edits the file in place. The `|` is the separator, so the `/` and `:` in URLs and ARNs need no escaping.

**4.3 Review and push:**

```bash
git diff --stat
git add -A && git commit -m "Configure for $CLUSTER" && git push
```

---

## Step 5: IAM policies for the controllers (script: 01-create-cluster.sh)

Two controllers running in the cluster call AWS APIs:

| Policy name | File | Lets the controller… |
| --- | --- | --- |
| `argo-eks-lbc` | [policies/aws-load-balancer-controller.json](../policies/aws-load-balancer-controller.json) | create and modify ALBs, target groups and security groups |
| `argo-eks-external-dns` | [policies/external-dns.json](../policies/external-dns.json) | write records into your Route 53 zone |

Create each one if it doesn't exist yet:

```bash
for p in lbc:aws-load-balancer-controller external-dns:external-dns; do
  name="$CLUSTER-${p%%:*}"          # text before ':'  -> argo-eks-lbc
  file="policies/${p#*:}.json"      # text after ':'   -> policies/aws-load-balancer-controller.json
  if aws iam get-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$name" >/dev/null 2>&1; then
    echo "$name exists"
  else
    aws iam create-policy --policy-name "$name" --policy-document "file://$file" --query Policy.Arn --output text
  fi
done
```

Check:

```bash
aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName,'$CLUSTER-')].[PolicyName,Arn]" --output table
```

The policies must exist **before** eksctl runs, because [eksctl/cluster.yaml](../eksctl/cluster.yaml) attaches
them by ARN (`iam.podIdentityAssociations`).

---

## Step 6: ECR repositories (script: 01-create-cluster.sh)

> **Repo names must match the overlay.** Argo CD pulls whatever
> [gitops/bmi-app/overlays/prod/kustomization.yaml](../gitops/bmi-app/overlays/prod/kustomization.yaml) names in `newName:`.
> The overlay now points at **`bmi-backend` / `bmi-frontend`** (no prefix), but `01-create-cluster.sh` and
> `03-release.sh` still use **`argo-eks/bmi-backend`**. This guide follows the overlay. Check which one you have:
> ```bash
> grep newName gitops/bmi-app/overlays/prod/kustomization.yaml
> ```
> and set `REPO_PREFIX` to match. Use an empty value for `…amazonaws.com/bmi-backend`, or `"$CLUSTER/"` for `…/argo-eks/bmi-backend`.

```bash
REPO_PREFIX=""        # or: REPO_PREFIX="$CLUSTER/"
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

for r in bmi-backend bmi-frontend; do
  aws ecr describe-repositories --repository-names "$REPO_PREFIX$r" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$REPO_PREFIX$r" \
      --image-scanning-configuration scanOnPush=true --query repository.repositoryUri --output text
done
aws ecr describe-repositories --query 'repositories[].repositoryUri' --output table
```

`describe … || create …` is the "create only if missing" pattern used throughout the scripts.
`scanOnPush` makes ECR scan each image for known CVEs.

---

## Step 7: Create the EKS cluster with eksctl (script: 01-create-cluster.sh)

Read [eksctl/cluster.yaml](../eksctl/cluster.yaml) first. This one file describes everything that eksctl builds:

| Section | What it creates |
| --- | --- |
| `vpc` | VPC `10.1.0.0/16`, 3 public + 3 private subnets (already tagged for ALBs), **one** NAT gateway |
| `accessConfig` | EKS access entries (`API` mode); your identity becomes cluster admin |
| `addons` | vpc-cni (with network policy), kube-proxy, coredns, pod-identity agent, metrics-server, EBS CSI driver |
| `iam.podIdentityAssociations` | links the `aws-load-balancer-controller` and `external-dns` service accounts to the policies from Step 5 |
| `managedNodeGroups` | 2–4 × `m7i-flex.large` in private subnets, AL2023, 20 GiB disk |
| `cloudWatch` | control plane logs: api, audit, authenticator |

**7.1 Dry run.** This prints the full config eksctl will use, with all defaults filled in:

```bash
eksctl create cluster -f eksctl/cluster.yaml --dry-run | less
```

**7.2 Create** (15–20 minutes; eksctl drives CloudFormation):

```bash
eksctl get cluster --name "$CLUSTER" --region "$AWS_REGION" 2>/dev/null \
  || eksctl create cluster -f eksctl/cluster.yaml
```

> To see what eksctl does for you, build the same cluster with plain AWS CLI commands
> instead: [Appendix: cluster without eksctl](#appendix-build-the-cluster-without-eksctl-plain-aws-cli).
> Use **one** of the two, not both.

While it runs, watch the progress from a second Git Bash window:

```bash
source scripts/config.env
aws cloudformation list-stacks --stack-status-filter CREATE_IN_PROGRESS CREATE_COMPLETE \
  --query "StackSummaries[?contains(StackName,'$CLUSTER')].[StackName,StackStatus]" --output table
```

You'll see `eksctl-argo-eks-cluster` (VPC + control plane) and then
`eksctl-argo-eks-nodegroup-general`. If creation fails, the reason is in **CloudFormation →
the stack → Events**:

```bash
aws cloudformation describe-stack-events --stack-name eksctl-$CLUSTER-cluster \
  --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" --output table
```

### 7.3 Inspect what eksctl built

**Network:**

```bash
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[].[AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,Tags[?Key==`kubernetes.io/role/elb`]|[0].Value,Tags[?Key==`kubernetes.io/role/internal-elb`]|[0].Value]' \
  --output table      # 3 public (elb=1) + 3 private (internal-elb=1)
aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC_ID --query 'NatGateways[].[NatGatewayId,State,SubnetId]' --output table
aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID \
  --query 'RouteTables[].[RouteTableId,Routes[?DestinationCidrBlock==`0.0.0.0/0`]|[0].[GatewayId,NatGatewayId]]' --output json
```

**IAM roles eksctl created** (the cluster role, the node role, and one Pod Identity role per association):

```bash
aws iam list-roles --query "Roles[?starts_with(RoleName,'eksctl-$CLUSTER')].RoleName" --output table

# Cluster role and its policies
CLUSTER_ROLE=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.roleArn --output text); echo "$CLUSTER_ROLE"
aws iam list-attached-role-policies --role-name "${CLUSTER_ROLE##*/}" --output table

# Node role: AmazonEKSWorkerNodePolicy, AmazonEKS_CNI_Policy, AmazonEC2ContainerRegistryReadOnly, AmazonSSMManagedInstanceCore
NODE_ROLE=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name general --query nodegroup.nodeRole --output text)
aws iam list-attached-role-policies --role-name "${NODE_ROLE##*/}" --output table
```

**Trust policies** answer *who may assume a role*. Compare the three kinds:

```bash
aws iam get-role --role-name "${CLUSTER_ROLE##*/}" --query Role.AssumeRolePolicyDocument   # eks.amazonaws.com
aws iam get-role --role-name "${NODE_ROLE##*/}"    --query Role.AssumeRolePolicyDocument   # ec2.amazonaws.com

# Pod Identity: list the associations, then read one role's trust policy (pods.eks.amazonaws.com)
aws eks list-pod-identity-associations --cluster-name "$CLUSTER" \
  --query 'associations[].[namespace,serviceAccount,associationId]' --output table
ASSOC=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --service-account aws-load-balancer-controller --namespace kube-system --query 'associations[0].associationId' --output text)
LBC_ROLE=$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER" --association-id "$ASSOC" --query association.roleArn --output text)
aws iam get-role --role-name "${LBC_ROLE##*/}" --query Role.AssumeRolePolicyDocument
aws iam list-attached-role-policies --role-name "${LBC_ROLE##*/}"                          # -> argo-eks-lbc from Step 5
```

`${VAR##*/}` removes everything up to the last `/`, turning a role ARN into a role name.

---

## Step 8: Connect kubectl

This is `kubeconfig()` in `lib.sh`. Run it again whenever kubectl loses the cluster.

```bash
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"
kubectl config current-context
kubectl get nodes -o wide            # 2 nodes, STATUS Ready, INTERNAL-IP 10.1.x.x, no EXTERNAL-IP
```

See what eksctl installed:

```bash
kubectl get pods -A                                  # coredns, aws-node, kube-proxy, ebs-csi-*, metrics-server, eks-pod-identity-agent
aws eks list-addons --cluster-name "$CLUSTER"
aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --output table
kubectl top nodes                                    # works once metrics-server is Ready
```

### 8.1 Who can use the cluster (IAM → Kubernetes)

`authenticationMode: API` means cluster access is controlled by **EKS access entries**, an AWS API,
not the old `aws-auth` ConfigMap. kubectl sends a token signed with your IAM credentials, and EKS
maps your IAM ARN to Kubernetes permissions:

```bash
aws eks list-access-entries --cluster-name "$CLUSTER" --output table     # your user + the node role
MY_ARN=$(aws sts get-caller-identity --query Arn --output text)
aws eks list-associated-access-policies --cluster-name "$CLUSTER" --principal-arn "$MY_ARN" --output table
kubectl auth whoami                                                       # how Kubernetes sees you
kubectl auth can-i '*' '*' --all-namespaces                               # yes = cluster admin
```

Give another IAM user or role access, for example a teammate with read-only access:

```bash
OTHER=arn:aws:iam::$ACCOUNT_ID:user/teammate
aws eks create-access-entry --cluster-name "$CLUSTER" --principal-arn "$OTHER"
aws eks associate-access-policy --cluster-name "$CLUSTER" --principal-arn "$OTHER" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy \
  --access-scope type=cluster          # or: type=namespace,namespaces=bmi-app
# Admin instead of read-only: .../cluster-access-policy/AmazonEKSClusterAdminPolicy
aws eks list-access-policies --query 'accessPolicies[].name'   # every available policy
```

Remove access with `aws eks delete-access-entry --cluster-name "$CLUSTER" --principal-arn "$OTHER"`.

---

## Step 9: Default StorageClass gp3 (script: 02-install-platform.sh)

Postgres requests a volume without naming a class, so it gets the **default** StorageClass.
[platform/storageclass-gp3.yaml](../platform/storageclass-gp3.yaml) creates an encrypted gp3 class.
`WaitForFirstConsumer` creates the volume in the AZ where the pod lands.

```bash
kubectl apply -f platform/storageclass-gp3.yaml
# Only one class may be the default; EKS may also ship gp2 as default.
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite 2>/dev/null || true
kubectl get storageclass             # exactly one "(default)", on gp3
```

---

## Step 10: Gateway API CRDs (script: 02-install-platform.sh)

LB Controller v3 watches Gateway API objects as well as Ingress, and it expects their CRDs to
exist when it starts. `--server-side` is needed because these CRDs are too large for
client-side apply.

```bash
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.0/config/crd/gateway/gateway-crds.yaml
kubectl get crd | grep -E 'gateway|elbv2'
```

---

## Step 11: AWS Load Balancer Controller (script: 02-install-platform.sh)

This controller turns every `Ingress` with `ingressClassName: alb` into a real ALB.

```bash
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
echo "$VPC_ID"

helm upgrade --install aws-load-balancer-controller aws-load-balancer-controller \
  --repo https://aws.github.io/eks-charts -n kube-system \
  --set clusterName="$CLUSTER" --set region="$AWS_REGION" --set vpcId="$VPC_ID" \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 10m

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=300s
```

- `helm upgrade --install` installs the first time and upgrades after that, so it's safe to run again.
- `--repo` installs directly from the chart URL without `helm repo add`.
- `serviceAccount.name` **must** equal the Pod Identity association in `cluster.yaml`, or the controller has no AWS permissions.
- The `rollout status` matters: the controller runs a **webhook** that checks every Service and Ingress. If it's not ready,
  later installs fail with `failed calling webhook "mservice.elbv2.k8s.aws"`.

Check:

```bash
helm -n kube-system list
kubectl -n kube-system get deploy aws-load-balancer-controller        # READY 2/2
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=20
```

---

## Step 12: ExternalDNS (script: 02-install-platform.sh)

ExternalDNS reads `spec.rules[].host` from every Ingress and creates the matching A record in
Route 53. Its settings are in [platform/external-dns-values.yaml](../platform/external-dns-values.yaml):
`domainFilters: [bestclick.click]`, `policy: upsert-only` (it never deletes records), and `txtOwnerId: argo-eks`.

```bash
helm upgrade --install external-dns external-dns \
  --repo https://kubernetes-sigs.github.io/external-dns/ -n external-dns --create-namespace \
  -f platform/external-dns-values.yaml --wait --timeout 5m

kubectl -n external-dns logs deploy/external-dns --tail=20     # "All records are already up to date" = permissions OK
```

---

## Step 13: Argo CD (script: 02-install-platform.sh)

[platform/argocd-values.yaml](../platform/argocd-values.yaml) does three things:

- `server.insecure: true`: TLS ends at the ALB, which forwards plain HTTP to argocd-server.
- `timeout.reconciliation: 60s`: Argo CD polls Git every 60 seconds instead of 180.
- `server.ingress`: creates an Ingress for `argocd.bestclick.click` with `group.name: shared`, so the UI and the app share **one** ALB.

```bash
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm -n argocd --create-namespace \
  -f platform/argocd-values.yaml --wait --timeout 10m

kubectl -n argocd get pods
kubectl -n argocd get ingress        # ADDRESS = k8s-shared-….elb.amazonaws.com after 1-3 minutes
```

This Ingress is the first one in the cluster, so this is when the LB Controller creates the ALB
and ExternalDNS creates `argocd.bestclick.click`. Watch both happen:

```bash
kubectl -n kube-system logs deploy/aws-load-balancer-controller -f     # "successfully deployed model"
kubectl -n external-dns logs deploy/external-dns -f                    # "CREATE argocd.bestclick.click A"
```

Get the admin password and log in:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

- UI: **https://argocd.bestclick.click** (DNS takes 2–5 minutes), user `admin`
- Without DNS: `kubectl -n argocd port-forward svc/argocd-server 8080:80`, then open http://localhost:8080

---

## Step 14: App namespace and secrets (script: 02-install-platform.sh)

The database password is **never stored in Git**. Create it once, directly in the cluster:

```bash
kubectl create namespace bmi-app --dry-run=client -o yaml | kubectl apply -f -   # idempotent "create"

if ! kubectl -n bmi-app get secret postgres-secret >/dev/null 2>&1; then
  DB_PASS=$(openssl rand -hex 16)          # hex only, so it's safe inside a URL
  kubectl -n bmi-app create secret generic postgres-secret \
    --from-literal=POSTGRES_DB=bmidb --from-literal=POSTGRES_USER=bmi_user \
    --from-literal=POSTGRES_PASSWORD="$DB_PASS"
  kubectl -n bmi-app create secret generic backend-secret \
    --from-literal=DATABASE_URL="postgres://bmi_user:$DB_PASS@bmi-postgres-svc:5432/bmidb"
else
  echo "secrets exist - keep them"
fi
kubectl -n bmi-app get secrets
```

**Don't recreate these secrets after Postgres has started.** Postgres sets the password only
when it first initialises the volume. A new secret then no longer matches the database, and the
backend fails with `password authentication failed`.

To read a secret value back:

```bash
kubectl -n bmi-app get secret backend-secret -o jsonpath='{.data.DATABASE_URL}' | base64 -d; echo
```

---

## Step 15: Build and push the images (script: 03-release.sh)

ECR tags are unique per build. The script makes them from `<git short sha>-<timestamp>`:

```bash
TAG="$(git rev-parse --short HEAD)-$(date +%Y%m%d%H%M%S)"
echo "$TAG"

# Docker logs in to ECR with a 12-hour token from your AWS identity
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

for c in backend frontend; do
  docker build --platform linux/amd64 -t "$REGISTRY/${REPO_PREFIX}bmi-$c:$TAG" "app/$c"
  docker push "$REGISTRY/${REPO_PREFIX}bmi-$c:$TAG"
done

aws ecr describe-images --repository-name "${REPO_PREFIX}bmi-backend" \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].[imageTags[0],imagePushedAt]' --output text
```

`--platform linux/amd64` matters: m7i nodes are x86. An image built on an ARM machine (Apple
Silicon) would crash with `exec format error`.

---

## Step 16: Point Git at the new tag (script: 03-release.sh)

**This commit is the deployment.** Argo CD deploys whatever tag Git names, and nothing else.

```bash
OVERLAY=gitops/bmi-app/overlays/prod/kustomization.yaml
sed -i -E "s|^(\s*newTag:).*|\1 $TAG|" "$OVERLAY"    # rewrite both newTag lines
grep -n -E 'newName|newTag' "$OVERLAY"

git add "$OVERLAY"
git commit -m "release: bmi images $TAG"
git push origin "HEAD:$GIT_BRANCH"
```

Preview what Argo CD will render, using the Kustomize built into kubectl:

```bash
kubectl kustomize gitops/bmi-app/overlays/prod | grep -E 'image:|host:'
```

---

## Step 17: Create the Argo CD root app (script: 02-install-platform.sh)

This is the **only** Argo CD object you apply by hand. [gitops/argocd/root-app.yaml](../gitops/argocd/root-app.yaml)
watches `gitops/argocd/apps/`. Argo CD creates every Application it finds there, which today is
[bmi-app.yaml](../gitops/argocd/apps/bmi-app.yaml) (the "app of apps" pattern).

```bash
kubectl apply -f gitops/argocd/root-app.yaml
kubectl -n argocd get applications -w      # root, then bmi-app -> Synced / Healthy  (Ctrl+C to stop)
```

> The script runs this at the end of `02-install-platform.sh`, before any image exists. That works,
> but `bmi-app` stays in `ImagePullBackOff` until Steps 15–16. This guide pushes the images first,
> so the first sync succeeds.

Watch `bmi-app` sync in waves:

```bash
kubectl -n bmi-app get pods,jobs,pvc -w
```

| Wave | Object | What you'll see |
| --- | --- | --- |
| 0 | Postgres StatefulSet + PVC | PVC `data-postgres-0` goes `Pending` → `Bound` (a new gp3 EBS volume) |
| 1 | `bmi-migrations` Job (Sync hook) | pod `Completed`; it ran the SQL in `migrations/` |
| 2 | backend + HPA, frontend | 2 backend pods, frontend pods `Running` |
| 3 | Ingress `bmi` | joins the `shared` ALB; ExternalDNS creates `argo-bmi.bestclick.click` |

---

## Step 18: Verify end to end

```bash
kubectl -n argocd get applications                     # both Synced + Healthy
kubectl -n bmi-app get pods,svc,hpa,ingress,pvc
kubectl -n bmi-app logs job/bmi-migrations             # migration output
kubectl -n bmi-app logs deploy/bmi-backend --tail=20

nslookup "$APP_HOST"                                   # resolves to the ALB
curl -sI "http://$APP_HOST"  | head -3                 # 301 -> https (ssl-redirect)
curl -s  "https://$APP_HOST" | head -5                 # the React index.html
```

Then open **https://argo-bmi.bestclick.click**, add a measurement and refresh the page. It's stored in Postgres.

AWS side:

```bash
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-shared')].[LoadBalancerName,State.Code,DNSName]" --output table
aws ec2 describe-volumes --filters Name=tag:kubernetes.io/created-for/pvc/name,Values=data-postgres-0 \
  --query 'Volumes[].[VolumeId,Size,VolumeType,Encrypted,State]' --output table
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?contains(Name,'argo')].[Name,Type]" --output table
```

(If `$ZONE_ID` is empty, set it first: `ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query 'HostedZones[0].Id' --output text)`.)

---

## Day 2: Release a new version

1. Change code in `app/`.
2. Repeat **Step 15** (new `TAG`) and **Step 16** (commit + push), or run `bash scripts/03-release.sh`.
3. Argo CD picks up the commit within about 60 seconds and runs a rolling update:

```bash
kubectl -n bmi-app rollout status deploy/bmi-backend
kubectl -n bmi-app get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
```

**Rollback:** `git revert <release commit> && git push`. Git is the source of truth.

**See self-heal in action:** change something by hand, and Argo CD changes it back:

```bash
kubectl -n bmi-app set image deploy/bmi-frontend frontend=nginx:latest   # container name: check with the command above
kubectl -n bmi-app get deploy bmi-frontend -w                            # reverted within about 60 s
```

---

## Useful commands for exploring

| Want to… | Command |
| --- | --- |
| Force Argo CD to re-check Git now | `kubectl -n argocd annotate application bmi-app argocd.argoproj.io/refresh=hard --overwrite` |
| See why an app is OutOfSync / Degraded | `kubectl -n argocd describe application bmi-app` (see `Status.Conditions` and `Resources`) |
| Events in a namespace, newest last | `kubectl -n bmi-app get events --sort-by=.lastTimestamp` |
| Why a pod won't start | `kubectl -n bmi-app describe pod <name>` (the Events section at the bottom) |
| Logs of a crashed container | `kubectl -n bmi-app logs <pod> --previous` |
| Open a psql shell | `kubectl -n bmi-app exec -it postgres-0 -- psql -U bmi_user -d bmidb` |
| Call the backend from inside the cluster | `kubectl -n bmi-app run tmp --rm -it --image=curlimages/curl -- sh` |
| Show the values a Helm release uses | `helm -n argocd get values argocd` |
| List every Helm release | `helm list -A` |
| Who you are in the cluster | `kubectl auth whoami` |
| Node and pod CPU and memory | `kubectl top nodes` / `kubectl top pods -n bmi-app` |
| Scale the node group | `eksctl scale nodegroup --cluster $CLUSTER --name general --nodes 3` |
| What eksctl manages | `eksctl get nodegroup --cluster $CLUSTER` / `eksctl get addons --cluster $CLUSTER` |

The `argocd` CLI is optional. `winget install argoproj.argocd`, then:

```bash
argocd login "$ARGOCD_HOST" --username admin --grpc-web
argocd app list
argocd app get bmi-app
argocd app history bmi-app
argocd app sync bmi-app
```

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `x509: certificate … not yet valid … mservice.elbv2.k8s.aws` | PC clock ahead of AWS (Step 2) | Fix the clock, then `helm -n kube-system uninstall aws-load-balancer-controller` and redo Step 11 |
| Helm `cannot re-use a name that is still in use` | A failed release is still installed | `helm -n <ns> uninstall <name>` and install again |
| Helm `no cached repo found` | Stale global Helm cache on Windows | Set `HELM_REPOSITORY_*` as in Step 1 |
| `error: You must be logged in to the server (Unauthorized)` | A different AWS profile than the one that created the cluster | `echo $AWS_PROFILE`, run Step 1 again, then Step 8 |
| eksctl fails, stack `ROLLBACK_COMPLETE` | Quota, an instance type not offered in an AZ, or a missing IAM policy | Read the stack events (Step 7), `eksctl delete cluster -f eksctl/cluster.yaml`, then retry |
| Ingress has no ADDRESS | LBC not running or missing permissions | `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| `ImagePullBackOff` | The overlay's `newName:newTag` doesn't exist in ECR | Compare `grep newName -A1 $OVERLAY` with `aws ecr describe-images --repository-name …`; see the note in Step 6 |
| `exec format error` | Image built for ARM | Rebuild with `--platform linux/amd64` |
| Backend `password authentication failed` | Secrets recreated after Postgres initialised | Restore the old password, or delete PVC `data-postgres-0` (**this deletes the data**) |
| PVC stays `Pending` | No default StorageClass, or EBS CSI has no role | `kubectl get sc`; `aws eks list-pod-identity-associations --cluster-name $CLUSTER` |
| Argo CD `repository not found` | The repo is private | Make it public, or add it in **Settings → Repositories** |
| DNS name doesn't resolve | ExternalDNS permissions or filter | `kubectl -n external-dns logs deploy/external-dns` |

---

## Clean up (script: 99-destroy.sh)

**The order matters.** The ALB and the EBS volume were created *by controllers in the cluster*,
not by eksctl. If you delete the cluster first, they're orphaned and the VPC can't be deleted.

```bash
source scripts/config.env && aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"

# 1. Argo CD apps. Their finalizer deletes everything they created (Ingress, so the app's ALB rule; pods)
kubectl -n argocd delete application root    --ignore-not-found --wait=true --timeout=10m
kubectl -n argocd delete application bmi-app --ignore-not-found --wait=true --timeout=10m
# StatefulSet PVCs are never pruned; deleting the namespace releases the EBS volume
kubectl delete namespace bmi-app --ignore-not-found --wait=true --timeout=10m

# 2. Argo CD (its Ingress was the last one on the ALB), then the controllers
helm -n argocd uninstall argocd --wait
sleep 60                                            # give the LBC time to delete the ALB
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-shared')].LoadBalancerName"   # should be []
helm -n external-dns uninstall external-dns
helm -n kube-system uninstall aws-load-balancer-controller

# 3. Cluster, node group and VPC (10-15 minutes)
eksctl delete cluster -f eksctl/cluster.yaml --wait --disable-nodegroup-eviction

# 4. ECR (--force also deletes the images); use your REPO_PREFIX from Step 6
for r in bmi-backend bmi-frontend; do aws ecr delete-repository --repository-name "${REPO_PREFIX}$r" --force; done

# 5. IAM policies
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
for p in lbc external-dns; do aws iam delete-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-$p"; done
```

6. **Route 53:** ExternalDNS is `upsert-only`, so delete the `argo-bmi` and `argocd` A and TXT records yourself.
   Keep the ACM certificate and the hosted zone if other projects use them.

Final check that nothing billable is left:

```bash
aws eks list-clusters
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp'
```

---

## Appendix: build the cluster without eksctl (plain AWS CLI)

This builds the same thing as [eksctl/cluster.yaml](../eksctl/cluster.yaml) in Step 7, one AWS API
call at a time: network, IAM roles, cluster, add-ons, node group and Pod Identity. Use it **in
place of** Step 7, then continue with Step 8. Once you've done this by hand, you'll know exactly
what eksctl and Terraform automate.

The names below end in `-cli` so they never clash with the roles eksctl creates.
Run Steps 1, 2 and 5 first so that `$CLUSTER`, `$ACCOUNT_ID` and the two controller policies exist.

**Save the IDs as you go.** If your shell closes, the variables are lost. This appends each
`NAME=value` to a file you can `source` later:

```bash
keep() { eval "$1=\"$2\""; echo "$1=\"$2\"" >> .cli-ids.env; echo "$1=$2"; }
# later, in a new shell:  source scripts/config.env && source .cli-ids.env
```

(Add `.cli-ids.env` to `.gitignore`. It holds no secrets, but it doesn't belong in Git.)

### A.1 VPC

```bash
keep VPC_ID "$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$CLUSTER-vpc}]" --query Vpc.VpcId --output text)"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames   # nodes need DNS names to join EKS
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support

read -r -a AZS <<<"$(aws ec2 describe-availability-zones --filters Name=zone-type,Values=availability-zone \
  --query 'AvailabilityZones[0:3].ZoneName' --output text)"
echo "${AZS[@]}"                                    # ap-south-1a ap-south-1b ap-south-1c
```

### A.2 Subnets (3 public + 3 private, tagged for the LB Controller)

The CIDRs assume `VPC_CIDR=10.1.0.0/16`. Private subnets are larger because **every pod gets a VPC IP**.
The `kubernetes.io/role/*` tags tell the LB Controller where to place internet-facing and internal ALBs.

```bash
PUB_CIDRS=(10.1.0.0/20 10.1.16.0/20 10.1.32.0/20)
PRIV_CIDRS=(10.1.64.0/19 10.1.96.0/19 10.1.128.0/19)
for i in 0 1 2; do
  keep PUB$i "$(aws ec2 create-subnet --vpc-id "$VPC_ID" --availability-zone "${AZS[$i]}" --cidr-block "${PUB_CIDRS[$i]}" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$CLUSTER-public-${AZS[$i]}},{Key=kubernetes.io/role/elb,Value=1}]" \
    --query Subnet.SubnetId --output text)"
  eval aws ec2 modify-subnet-attribute --subnet-id "\$PUB$i" --map-public-ip-on-launch
  keep PRIV$i "$(aws ec2 create-subnet --vpc-id "$VPC_ID" --availability-zone "${AZS[$i]}" --cidr-block "${PRIV_CIDRS[$i]}" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$CLUSTER-private-${AZS[$i]}},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
    --query Subnet.SubnetId --output text)"
done
```

### A.3 Internet gateway, NAT gateway, route tables

- **Public subnets** route `0.0.0.0/0` to the internet gateway. The ALB and the NAT gateway live here.
- **Private subnets** route `0.0.0.0/0` to the NAT gateway. Nodes live here and reach ECR and the EKS API outbound only.

```bash
keep IGW "$(aws ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$CLUSTER-igw}]" \
  --query InternetGateway.InternetGatewayId --output text)"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID"

keep PUB_RT "$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text)"
aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW"
for s in "$PUB0" "$PUB1" "$PUB2"; do aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$s"; done

# One NAT gateway (the cheap option; eksctl "Single"). Billed by the hour plus per GB.
keep EIP "$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)"
keep NAT "$(aws ec2 create-nat-gateway --subnet-id "$PUB0" --allocation-id "$EIP" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$CLUSTER-nat}]" --query NatGateway.NatGatewayId --output text)"
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT"          # about 1-2 minutes

keep PRIV_RT "$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text)"
aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT"
for s in "$PRIV0" "$PRIV1" "$PRIV2"; do aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$s"; done

# Optional and free: S3 gateway endpoint. ECR image layers come from S3, so this skips the NAT (saves NAT data cost).
aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --service-name "com.amazonaws.$AWS_REGION.s3" \
  --vpc-endpoint-type Gateway --route-table-ids "$PRIV_RT"
```

### A.4 IAM role for the EKS control plane

```bash
keep CLUSTER_ROLE_ARN "$(aws iam create-role --role-name "$CLUSTER-cluster-role-cli" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}' \
  --query Role.Arn --output text)"
aws iam attach-role-policy --role-name "$CLUSTER-cluster-role-cli" --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```

### A.5 IAM role for the worker nodes

```bash
keep NODE_ROLE_ARN "$(aws iam create-role --role-name "$CLUSTER-node-role-cli" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --query Role.Arn --output text)"
for p in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy --role-name "$CLUSTER-node-role-cli" --policy-arn "arn:aws:iam::aws:policy/$p"
done
```

| Policy | Why the node needs it |
| --- | --- |
| `AmazonEKSWorkerNodePolicy` | the kubelet describes the cluster and registers the node |
| `AmazonEKS_CNI_Policy` | the VPC CNI (`aws-node`) attaches ENIs and assigns pod IPs |
| `AmazonEC2ContainerRegistryReadOnly` | pull images from ECR (yours and the EKS add-on images) |
| `AmazonSSMManagedInstanceCore` | optional: shell into a node with `aws ssm start-session` (no SSH keys) |

### A.6 IAM roles for the pods (Pod Identity)

All three roles trust the same principal, `pods.eks.amazonaws.com`. *Which* pod gets *which* role
is decided later by the association (A.10), not by the trust policy.

```bash
POD_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'

for r in lbc:arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-lbc \
         external-dns:arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-external-dns \
         ebs-csi:arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy; do
  name="$CLUSTER-${r%%:*}-cli"; policy="${r#*:}"
  aws iam create-role --role-name "$name" --assume-role-policy-document "$POD_TRUST" --query Role.Arn --output text
  aws iam attach-role-policy --role-name "$name" --policy-arn "$policy"
done
LBC_ROLE_ARN=arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER-lbc-cli
DNS_ROLE_ARN=arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER-external-dns-cli
EBS_ROLE_ARN=arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER-ebs-csi-cli
```

### A.7 The EKS cluster (control plane)

```bash
aws eks create-cluster --name "$CLUSTER" --kubernetes-version "$K8S_VERSION" \
  --role-arn "$CLUSTER_ROLE_ARN" \
  --resources-vpc-config "subnetIds=$PRIV0,$PRIV1,$PRIV2,$PUB0,$PUB1,$PUB2,endpointPublicAccess=true,endpointPrivateAccess=true" \
  --access-config authenticationMode=API,bootstrapClusterCreatorAdminPermissions=true \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator"],"enabled":true}]}' \
  --tags managed-by=aws-cli,project=eks-argocd-3tier \
  --query cluster.status
aws eks wait cluster-active --name "$CLUSTER"        # about 8-12 minutes
aws eks describe-cluster --name "$CLUSTER" --query 'cluster.[status,version,endpoint]'
```

- `subnetIds` lists the subnets where EKS places the control plane's ENIs. Listing both kinds is the usual practice.
- `endpointPublicAccess=true` lets kubectl on your PC reach the API. Add `publicAccessCidrs=<your-ip>/32` to limit it to your IP.
- `bootstrapClusterCreatorAdminPermissions=true` gives **your** IAM identity admin access (Step 8.1).

### A.8 Add-ons that the nodes need to become Ready

```bash
aws eks create-addon --cluster-name "$CLUSTER" --addon-name eks-pod-identity-agent
aws eks create-addon --cluster-name "$CLUSTER" --addon-name vpc-cni --configuration-values '{"enableNetworkPolicy":"true"}'
aws eks create-addon --cluster-name "$CLUSTER" --addon-name kube-proxy
aws eks describe-addon-versions --kubernetes-version "$K8S_VERSION" --addon-name vpc-cni \
  --query 'addons[0].addonVersions[0].addonVersion'   # shows the default version picked
```

### A.9 Managed node group

```bash
aws eks create-nodegroup --cluster-name "$CLUSTER" --nodegroup-name general \
  --node-role "$NODE_ROLE_ARN" --subnets "$PRIV0" "$PRIV1" "$PRIV2" \
  --instance-types "$NODE_TYPE" --ami-type AL2023_x86_64_STANDARD --disk-size 20 \
  --scaling-config "minSize=$NODE_MIN,maxSize=$NODE_MAX,desiredSize=2" \
  --labels role=general --query nodegroup.status
aws eks wait nodegroup-active --cluster-name "$CLUSTER" --nodegroup-name general   # about 3-5 minutes
```

The node group gets only the **private** subnets, so the nodes have no public IP and reach the internet through the NAT.

### A.10 Add-ons that need nodes, and Pod Identity associations

```bash
aws eks create-addon --cluster-name "$CLUSTER" --addon-name coredns
aws eks create-addon --cluster-name "$CLUSTER" --addon-name metrics-server
aws eks create-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver \
  --pod-identity-associations "serviceAccount=ebs-csi-controller-sa,roleArn=$EBS_ROLE_ARN"

aws eks create-pod-identity-association --cluster-name "$CLUSTER" \
  --namespace kube-system  --service-account aws-load-balancer-controller --role-arn "$LBC_ROLE_ARN"
aws eks create-pod-identity-association --cluster-name "$CLUSTER" \
  --namespace external-dns --service-account external-dns                 --role-arn "$DNS_ROLE_ARN"

aws eks list-addons --cluster-name "$CLUSTER"
for a in $(aws eks list-addons --cluster-name "$CLUSTER" --query addons --output text); do
  printf '%-24s %s\n' "$a" "$(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$a" --query addon.status --output text)"
done                                                  # all ACTIVE
```

An association can exist before its namespace or service account does. Helm creates those in Steps 11 and 12.

Now continue with **[Step 8](#step-8-connect-kubectl)**. Everything from there on is the same for both paths.

### A.11 Clean up the plain-CLI cluster

First do clean-up steps 1–2 above (Argo CD apps, namespace, Helm releases, ALB gone). Then delete in **reverse** order:

```bash
source scripts/config.env && source .cli-ids.env

aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name general
aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name general
for a in $(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --query 'associations[].associationId' --output text); do
  aws eks delete-pod-identity-association --cluster-name "$CLUSTER" --association-id "$a"; done
aws eks delete-cluster --name "$CLUSTER"
aws eks wait cluster-deleted --name "$CLUSTER"

aws ec2 delete-nat-gateway --nat-gateway-id "$NAT"
aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT"
aws ec2 release-address --allocation-id "$EIP"
for e in $(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID --query 'VpcEndpoints[].VpcEndpointId' --output text); do
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$e"; done
aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID"
aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
for s in "$PUB0" "$PUB1" "$PUB2" "$PRIV0" "$PRIV1" "$PRIV2"; do aws ec2 delete-subnet --subnet-id "$s"; done
aws ec2 delete-route-table --route-table-id "$PUB_RT"
aws ec2 delete-route-table --route-table-id "$PRIV_RT"
# Leftover security groups (for example from the LBC) block VPC deletion. Delete all except "default":
for g in $(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
  aws ec2 delete-security-group --group-id "$g"; done
aws ec2 delete-vpc --vpc-id "$VPC_ID"

# IAM: detach every policy before deleting each role
for r in cluster-role node-role lbc external-dns ebs-csi; do
  name="$CLUSTER-$r-cli"
  for p in $(aws iam list-attached-role-policies --role-name "$name" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$name" --policy-arn "$p"; done
  aws iam delete-role --role-name "$name"
done
rm -f .cli-ids.env
```

Then do clean-up steps 4–6 above (ECR, the two controller policies, Route 53 records).
