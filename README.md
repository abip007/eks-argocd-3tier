# BMI Health Tracker on EKS, deployed by Argo CD

A 3-tier app (React/nginx → Node.js API → PostgreSQL on EBS) on Amazon EKS,
deployed with **GitOps**: Argo CD keeps the cluster equal to this Git repo. To release,
you push a commit. Nobody runs `kubectl apply` for the app.

```
 git push ──► GitHub ◄── polls every 60 s ── Argo CD ──► bmi-app namespace
                                                         │
 Browser ─HTTPS─► ALB (ACM cert) ──► frontend (nginx) ──/api──► backend ──► postgres (gp3 EBS)
                     ▲                                             ▲
           LB Controller creates it                 HPA 2-6 pods (metrics-server)
 Route 53 ◄── ExternalDNS writes A records for every Ingress host
```

## Three ways to build the platform (pick one)

All three create the same thing: VPC, EKS cluster, node group, add-ons, Pod Identity roles,
ECR repos, LB Controller, ExternalDNS and Argo CD. After that, **Argo CD deploys the app
from `gitops/` in every case.**

| Path | Start here | Best for |
| --- | --- | --- |
| AWS Console (click-by-click + CloudShell) | [docs/01-console-guide.md](docs/01-console-guide.md) | Learning what each piece is |
| Shell scripts (eksctl + helm) | [Shell path](#shell-path) | Fast, repeatable, few tools |
| Command line, step by step (what the scripts do, one command at a time) | [docs/02-command-line-guide.md](docs/02-command-line-guide.md) | Understanding and debugging the scripts |
| Terraform | [Terraform path](#terraform-path) | Infrastructure as code with state, plan and destroy |

They use the same resource names (`argo-eks-*`), so **don't mix paths in one account**.

### Common first steps (all paths)

1. Create the GitHub repo `eks-argocd-3tier` (public, or add credentials in Argo CD) and push this folder.
2. Edit [scripts/config.env](scripts/config.env) (profile, region, domain, hosts, Git URL).
3. `bash scripts/00-configure.sh`. It finds or requests the ACM certificate, then writes your
   account ID, hosts, certificate and Git URL into `gitops/`, `platform/` and `eksctl/`.
4. `git add -A && git commit -m "configure" && git push`. Argo CD reads these values from Git.

Tools on your PC: AWS CLI v2, kubectl, Helm 3, Docker Desktop, Git Bash, and **eksctl** (shell
path, `winget install eksctl`) or **Terraform ≥ 1.6** (Terraform path).

### Shell path

```bash
bash scripts/01-create-cluster.sh     # IAM policies, ECR, eksctl cluster (~20 min)
bash scripts/02-install-platform.sh   # StorageClass, LBC, ExternalDNS, Argo CD, secrets, root app
bash scripts/03-release.sh            # build + push images, bump tag in Git -> Argo CD deploys
bash scripts/99-destroy.sh            # tear everything down in the right order
```

### Terraform path

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars    # keep values equal to scripts/config.env
terraform init
terraform plan -out tf.plan && terraform apply tf.plan   # ~25 min, needs aws + kubectl on PATH
cd .. && bash scripts/03-release.sh             # first images -> Argo CD deploys the app
terraform -chdir=terraform output argocd_admin_password_command
```

`terraform destroy` first deletes the Argo CD apps and the app namespace
(`terraform_data.app_teardown`), so the ALB and EBS volume are gone before the VPC is deleted.

## Day-2: the release loop

```bash
# change code in app/, then:
bash scripts/03-release.sh
```
The script builds both images with a unique tag, pushes them to ECR, rewrites the two `newTag:`
lines in [gitops/bmi-app/overlays/prod/kustomization.yaml](gitops/bmi-app/overlays/prod/kustomization.yaml),
commits and pushes. Argo CD syncs within about 60 seconds. To roll back, `git revert` that commit.

## Layout

| Path | What |
| --- | --- |
| `app/` | Backend (Express + pg) and frontend (React/Vite → nginx) source and Dockerfiles |
| `gitops/argocd/` | `root-app.yaml` (app-of-apps) and `apps/` (one Application per app) |
| `gitops/bmi-app/base/` | Kustomize base: Postgres, migration Job, backend + HPA, frontend, Ingress |
| `gitops/bmi-app/overlays/prod/` | Environment values: image registry and tags, host, certificate |
| `platform/` | StorageClass and Helm values for Argo CD / ExternalDNS (shell + console paths) |
| `policies/` | IAM policies for the LB Controller and ExternalDNS (used by all three paths) |
| `eksctl/cluster.yaml` | Cluster definition for the shell path |
| `terraform/` | Terraform path |
| `scripts/` | `config.env` + numbered scripts |

## How the deploy works

- **Sync waves**: Postgres (wave 0) → migrations Job, an Argo CD `Sync` hook re-created each sync (wave 1) →
  backend/frontend (wave 2) → Ingress (wave 3).
- **Secrets are not in Git**. `postgres-secret` and `backend-secret` are created by
  `02-install-platform.sh`, by Terraform (`random_password`), or by hand (console guide, Step 12).
  For production, switch to External Secrets + AWS Secrets Manager.
- **One ALB** for the app and the Argo CD UI (`alb.ingress.kubernetes.io/group.name: shared`).
- **Pod Identity** (not IRSA) gives the LB Controller, ExternalDNS and the EBS CSI driver their AWS permissions.
- The backend Deployment has no `replicas`, and Argo CD ignores `/spec/replicas`, so the HPA and self-heal don't fight.

## Lessons carried over from eks-platform-terraform

- **PC clock skew breaks Helm installs.** Helm signs the LB Controller webhook certificate with your local clock.
  `02-install-platform.sh` checks the skew against AWS before installing anything.
- **Stale Windows Helm cache** (`no cached repo found`): the scripts and Terraform use a private `.helm/` folder.
- **A failed Helm release blocks reinstall** (`cannot re-use a name`). Run `helm uninstall` on it first.

Costs: the EKS control plane, NAT gateway, ALB and two m7i-flex.large nodes are billed by the hour. Destroy the stack when you're done.
