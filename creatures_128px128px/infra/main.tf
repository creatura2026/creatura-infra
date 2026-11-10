locals {
  image_directory = abspath("${path.module}/../images")
  image_files     = fileset(local.image_directory, "*.png")
}

resource "aws_s3_bucket" "sprites" {
  bucket        = var.bucket_name != "" ? var.bucket_name : null
  bucket_prefix = var.bucket_name == "" ? "creatura-assets-" : null

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "sprites" {
  bucket = aws_s3_bucket.sprites.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "sprites" {
  bucket = aws_s3_bucket.sprites.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sprites" {
  bucket = aws_s3_bucket.sprites.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "sprites" {
  bucket = aws_s3_bucket.sprites.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "sprite" {
  for_each = local.image_files

  bucket       = aws_s3_bucket.sprites.id
  key          = "${var.object_prefix}${each.value}"
  source       = "${local.image_directory}/${each.value}"
  etag         = filemd5("${local.image_directory}/${each.value}")
  content_type = "image/png"
  cache_control = "public, max-age=31536000, immutable"

  depends_on = [aws_s3_bucket_ownership_controls.sprites]
}