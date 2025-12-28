# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Get availability zones in the region
data "aws_availability_zones" "available" {
  state = "available"
}
