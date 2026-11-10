variable "aws_region" {
  description = "AWS region where the bucket is created."
  type        = string
  default     = "eu-west-3"
}

variable "bucket_name" {
  description = "Optional globally unique S3 bucket name. Leave empty to let AWS generate one from the prefix."
  type        = string
  default     = ""
}

variable "object_prefix" {
  description = "Prefix used for uploaded object keys."
  type        = string
  default     = "sprites/"
}

variable "cloudfront_price_class" {
  description = "CloudFront price class for the sprite distribution."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "cloudfront_price_class must be PriceClass_100, PriceClass_200, or PriceClass_All."
  }
}