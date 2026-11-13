locals {
  s3_origin_id = "s3-${aws_s3_bucket.sprites.id}"

  # AWS managed cache policies. Referencing them by ID needs no extra IAM permission.
  cache_policy_caching_optimized = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  cache_policy_caching_disabled  = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

  # AWS managed origin request policy "AllViewerExceptHostHeader": every header (Authorization,
  # WebSocket upgrade), cookie and query string reaches the backend.
  origin_request_policy_all_viewer_except_host = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

  api_origin_id = "api-backend"
  # One element when the backend load balancer is known, none otherwise.
  api_origins = var.api_origin_domain_name == "" ? [] : [var.api_origin_domain_name]

  # Paths whose file names are content-hashed (or never change) and can be cached for a long time.
  # admin/assets/* is the dashboard, built with the /admin/ base path.
  long_lived_path_patterns = ["assets/*", "admin/assets/*", "sprites/*"]
}

resource "aws_cloudfront_origin_access_control" "sprites" {
  name                              = "${aws_s3_bucket.sprites.bucket}-oac"
  description                       = "CloudFront access to the private Creatura bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "spa_rewrite" {
  name    = "creatura-spa-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Serve index.html for client-side routes of the player PWA and the admin dashboard"
  publish = true
  code    = file("${path.module}/functions/spa-rewrite.js")
}

resource "aws_cloudfront_distribution" "sprites" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = var.cloudfront_price_class
  comment             = "Creatura web apps (player PWA, admin dashboard) and sprites"

  origin {
    domain_name              = aws_s3_bucket.sprites.bucket_regional_domain_name
    origin_id                = local.s3_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.sprites.id
  }

  # Backend on EKS, behind the load balancer of the eks/ stack. No certificate exists for the
  # load balancer name, so CloudFront reaches it over HTTP; viewers always use HTTPS.
  dynamic "origin" {
    for_each = local.api_origins

    content {
      domain_name = origin.value
      origin_id   = local.api_origin_id

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  # Same origin as the web apps: the browser calls /api/v1 without CORS. Never cached,
  # every method allowed, no SPA rewrite.
  dynamic "ordered_cache_behavior" {
    for_each = local.api_origins

    content {
      path_pattern             = "api/*"
      target_origin_id         = local.api_origin_id
      viewer_protocol_policy   = "https-only"
      allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods           = ["GET", "HEAD"]
      compress                 = true
      cache_policy_id          = local.cache_policy_caching_disabled
      origin_request_policy_id = local.origin_request_policy_all_viewer_except_host
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.long_lived_path_patterns

    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = local.s3_origin_id
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true
      cache_policy_id        = local.cache_policy_caching_optimized
    }
  }

  # Everything else: index.html of both apps, service worker, web manifest, icons.
  # Never cached at the edge, so a new release is visible immediately.
  default_cache_behavior {
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = local.cache_policy_caching_disabled

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_rewrite.arn
    }
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
