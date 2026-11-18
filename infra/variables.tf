variable "aws_region" {
  description = "AWS region where the bucket is created."
  type        = string
  default     = "eu-north-1"
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

variable "api_origin_domain_name" {
  description = "DNS name of the backend load balancer (output api_origin_domain_name of the eks/ stack). Empty: CloudFront has no /api/* route."
  type        = string
  default     = ""
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
variable "custom_domain" {
  description = "Domain served by the distribution (output domain_name of dns/). Empty: the CloudFront hostname only."
  type        = string
  default     = ""
}

variable "certificate_arn" {
  description = "ACM certificate in us-east-1 for custom_domain, already ISSUED (output certificate_arn of dns/)."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route 53 zone of custom_domain (output zone_id of dns/): ALIAS records to the distribution."
  type        = string
  default     = ""

  validation {
    condition     = (var.custom_domain == "") == (var.certificate_arn == "") && (var.custom_domain == "") == (var.route53_zone_id == "")
    error_message = "custom_domain, certificate_arn and route53_zone_id are set together (outputs of dns/), or all left empty."
  }
}
