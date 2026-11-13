variable "aws_region" {
  description = "AWS region for the bootstrap resources."
  type        = string
  default     = "eu-north-1"
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
