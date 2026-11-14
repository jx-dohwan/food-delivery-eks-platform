# Persistent, free external-access analysis. Never configure internal/unused access.
resource "aws_accessanalyzer_analyzer" "external_access" {
  analyzer_name = "food-delivery-external-access"
  type          = "ACCOUNT"

  tags = {
    Name      = "food-delivery-external-access"
    Project   = "food-delivery"
    ManagedBy = "terraform"
    Purpose   = "external-access-findings"
  }

  lifecycle {
    prevent_destroy = true
  }
}
