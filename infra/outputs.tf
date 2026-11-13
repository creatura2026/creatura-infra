locals {
  # Custom domain when set (dns/ stack), the CloudFront hostname otherwise.
  public_url = "https://${var.custom_domain != "" ? var.custom_domain : aws_cloudfront_distribution.sprites.domain_name}"
}

output "bucket_name" {
  description = "Name of the S3 bucket containing the sprites."
  value       = aws_s3_bucket.sprites.bucket
}

output "bucket_arn" {
  description = "ARN of the S3 bucket containing the sprites."
  value       = aws_s3_bucket.sprites.arn
}

output "uploaded_object_keys" {
  description = "S3 keys uploaded by this configuration."
  value       = sort([for object in aws_s3_object.sprite : object.key])
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for the sprite CDN."
  value       = aws_cloudfront_distribution.sprites.id
}

output "cloudfront_domain_name" {
  description = "CloudFront hostname for the sprite CDN."
  value       = aws_cloudfront_distribution.sprites.domain_name
}

output "api_url" {
  description = "Public URL of the API, empty while api_origin_domain_name is not set."
  value       = var.api_origin_domain_name == "" ? "" : "${local.public_url}/api/v1"
}

output "site_url" {
  description = "Public URL of the player PWA. The admin dashboard is served under /admin/."
  value       = "${local.public_url}/"
}
