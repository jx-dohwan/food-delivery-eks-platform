locals {
  region     = "ap-northeast-2"
  az_names   = slice(data.aws_availability_zones.available_az.names, 0, 3)
  owner      = var.owner
  vpc_cidr   = var.vpc_cidr
  tag_header = var.owner == "" ? "" : "${var.owner}-"
  # Shared by cluster creation, discovery tags and the later DNS lookup.
  # A lookup must not depend on a pending EKS resource just to obtain its name.
  cluster_name = "${local.tag_header}cluster"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  cidr_header = "${split(".", var.vpc_cidr)[0]}.${split(".", var.vpc_cidr)[1]}"

  subnet_map = merge([
    for idx, key in ["public", "private", "db"] : {
      for i, az_name in local.az_names : "${key}-${substr(az_name, -1, 1)}" => {
        type = key
        az   = az_name
        # idx=0(public) -> 0,1,2 / idx=1(private) -> 10,11,12 / idx=2(db) -> 20,21,22
        cidr = "${local.cidr_header}.${i + (idx * 10)}.0/24"
      }
    }
  ]...)
}

output "subnet_map" {
  value = local.subnet_map
}
