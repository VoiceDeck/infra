locals {

  vpc_cidr = "10.0.0.0/16"


}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs              = local.azs
  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway           = true
  single_nat_gateway           = true

  enable_dns_hostnames                   = true
  enable_dns_support                     = true

  tags = local.tags
}