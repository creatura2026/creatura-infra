variable "aws_region" {
  description = "AWS region for the bootstrap resources."
  type        = string
  default     = "eu-west-3"
}

variable "github_organization" {
  description = "GitHub organization or user that owns the infrastructure repository."
  type        = string
}

variable "github_repository" {
  description = "Infrastructure repository name, without the organization."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be only the repository name, such as creatura-infra, without the GitHub organization or a slash."
  }
}

variable "github_plan_environment" {
  description = "GitHub Environment used by pull-request Terraform plans."
  type        = string
  default     = "terraform-plan"
}

variable "github_production_environment" {
  description = "GitHub Environment used by production Terraform applies."
  type        = string
  default     = "production"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string

  validation {
    condition     = length(var.state_bucket_name) >= 3 && length(var.state_bucket_name) <= 63
    error_message = "state_bucket_name must contain between 3 and 63 characters."
  }
}

variable "terraform_state_key" {
  description = "Object key used for the main infrastructure Terraform state."
  type        = string
  default     = "creatura-infra/terraform.tfstate"
}

variable "application_bucket_name" {
  description = "Optional exact application bucket name. Leave empty to allow the creatura-assets-* naming convention used by the main stack."
  type        = string
  default     = ""
}