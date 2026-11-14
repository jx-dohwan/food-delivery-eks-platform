# Current objects never expire. Age AND retained-history count must both be
# exceeded before a noncurrent version is eligible for permanent expiration.
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    id     = "retain-state-history"
    status = "Enabled"
    filter { prefix = "terraform/" }
    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 10
    }
  }
  rule {
    id     = "remove-empty-delete-markers"
    status = "Enabled"
    filter { prefix = "terraform/" }
    expiration { expired_object_delete_marker = true }
  }
  depends_on = [aws_s3_bucket_versioning.terraform_state_versioning]
}
