data "aws_iam_policy_document" "cloudfront_s3_read" {
  statement {
    sid       = "AllowCloudFrontReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.sprites.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.sprites.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "sprites" {
  bucket     = aws_s3_bucket.sprites.id
  policy     = data.aws_iam_policy_document.cloudfront_s3_read.json
  depends_on = [aws_s3_bucket_public_access_block.sprites]
}