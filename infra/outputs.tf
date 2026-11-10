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