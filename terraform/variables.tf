# ---------- General ----------
variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile for Terraform and kubectl/helm auth. null = default credential chain."
  type        = string
  default     = "abip007home"
}

variable "cluster_name" {
  description = "EKS cluster name. Prefixes IAM roles/policies and ECR repositories."
  type        = string
  default     = "argo-eks"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "tags" {
  type = map(string)
  default = {
    "managed-by" = "terraform"
    "project"    = "eks-argocd-3tier"
  }
}

# ---------- Network ----------
variable "vpc_cidr" {
  description = "VPC CIDR (3 public /20 + 3 private /19 across 3 AZs)."
  type        = string
  default     = "10.1.0.0/16"
}

variable "single_nat_gateway" {
  description = "true = one NAT gateway (cheap). false = one per AZ (HA)."
  type        = bool
  default     = true
}

variable "api_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API, e.g. [\"203.0.113.10/32\"]."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------- Nodes ----------
variable "node_instance_types" {
  description = "Free-plan eligible: m7i-flex.large / c7i-flex.large = 29 pods/node, t3.small = 11."
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

# ---------- DNS / TLS ----------
variable "domain_name" {
  description = "Public Route 53 hosted zone in this account."
  type        = string
  default     = "bestclick.click"
}

variable "app_host" {
  description = "Public hostname of the app (must match the overlay in gitops/)."
  type        = string
  default     = "argo-bmi.bestclick.click"
}

variable "argocd_host" {
  description = "Public hostname of the Argo CD UI."
  type        = string
  default     = "argocd.bestclick.click"
}

variable "certificate_arn" {
  description = "ACM certificate for domain + *.domain. Empty = look up the newest ISSUED one (scripts/00-configure.sh requests it)."
  type        = string
  default     = ""
}

# ---------- GitOps ----------
variable "git_repo_url" {
  description = "Git repository Argo CD watches (this project, pushed to GitHub)."
  type        = string
  default     = "https://github.com/abip007/eks-argocd-3tier.git"
}

variable "git_branch" {
  type    = string
  default = "main"
}

# ---------- Versions ----------
variable "aws_lbc_version" {
  description = "LB Controller release whose gateway CRDs are installed (policies/aws-load-balancer-controller.json matches v3.6.0)."
  type        = string
  default     = "v3.6.0"
}

variable "gateway_api_version" {
  type    = string
  default = "v1.6.0"
}

variable "aws_lbc_chart_version" {
  description = "null = latest."
  type        = string
  default     = null
}

variable "external_dns_chart_version" {
  description = "null = latest."
  type        = string
  default     = null
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version; null = latest."
  type        = string
  default     = null
}

variable "argocd_apps_chart_version" {
  description = "argocd-apps Helm chart version; null = latest."
  type        = string
  default     = null
}
