resource "aws_cloudfront_origin_access_control" "sprites" {
  name                              = "${aws_s3_bucket.sprites.bucket}-oac"
  description                       = "CloudFront access to the private sprite bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_cache_policy" "html" {
  name        = "creatura-html-no-cache"
  comment     = "Always revalidate the frontend entry point"
  default_ttl = 0
  max_ttl     = 0
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_distribution" "sprites" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = var.cloudfront_price_class
  comment             = "Creature sprites CDN"

  origin {
    domain_name              = aws_s3_bucket.sprites.bucket_regional_domain_name
    origin_id                = "s3-${aws_s3_bucket.sprites.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.sprites.id
  }

  ordered_cache_behavior {
    path_pattern           = "assets/*"
    target_origin_id       = "s3-${aws_s3_bucket.sprites.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  ordered_cache_behavior {
    path_pattern           = "sprites/*"
    target_origin_id       = "s3-${aws_s3_bucket.sprites.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  default_cache_behavior {
    target_origin_id       = "s3-${aws_s3_bucket.sprites.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = aws_cloudfront_cache_policy.html.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}