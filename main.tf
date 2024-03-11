terraform {
  backend "s3" {
    bucket = "voicedeck-tf-state"
    key    = "voicedeck-production-terraform-state"
    region = "eu-central-1"
  }
}

data "aws_availability_zones" "available" {}

locals {
  name   = "vd-prod"
  region = "eu-central-1"

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Name = local.name
  }

  user_data = <<-EOT
        #!/bin/bash

        cat <<'EOF' >> /etc/ecs/ecs.config
        ECS_CLUSTER=${local.name}
        ECS_LOGLEVEL=debug
        ECS_CONTAINER_INSTANCE_TAGS=${jsonencode(local.tags)}
        ECS_ENABLE_TASK_IAM_ROLE=true
        EOF
      EOT
}

################################################################################
# Cluster
################################################################################

module "ecs_cluster" {
  source = "terraform-aws-modules/ecs/aws"

  cluster_name = local.name

  default_capacity_provider_use_fargate = false

  autoscaling_capacity_providers = {
    vd = {
      auto_scaling_group_arn = module.autoscaling.autoscaling_group_arn

      managed_termination_protection = "ENABLED"

      managed_scaling = {
        maximum_scaling_step_size = 5

        minimum_scaling_step_size = 1

        status = "ENABLED"

        target_capacity = 80
      }

      default_capacity_provider_strategy = {
        weight = 100

        base = 1
      }
    }
  }

  tags = local.tags
}

################################################################################
# Service
################################################################################


module "directusCMS" {
  source = "terraform-aws-modules/ecs/aws//modules/service"

  name        = "directusCMS"
  cluster_arn = module.ecs_cluster.cluster_arn

  cpu    = 930
  memory = 930

  network_mode = "host"

  # Task Definition
  requires_compatibilities = ["EC2"]
  capacity_provider_strategy = { # On-demand instances
    vd = {
      capacity_provider = module.ecs_cluster.autoscaling_capacity_providers["vd"].name
      weight            = 1
      base              = 1
    }
  }


  # Container definition(s)
  container_definitions = {
    ("directus") = {
      image = "directus/directus:10.9.2"
      secrets = [
        {
          name      = "KEY"
          valueFrom = "${var.container_secret}:KEY::"
        },
        {
          name      = "SECRET"
          valueFrom = "${var.container_secret}:SECRET::"
        },
        {
          name      = "ADMIN_EMAIL"
          valueFrom = "${var.container_secret}:ADMIN_EMAIL::"
        },
        {
          name      = "ADMIN_PASSWORD"
          valueFrom = "${var.container_secret}:ADMIN_PASSWORD::"
        },
        {
          name      = "DB_HOST"
          valueFrom = "${var.container_secret}:DB_HOST::"
        },
        {
          name      = "DB_PORT"
          valueFrom = "${var.container_secret}:DB_PORT::"
        },
        {
          name      = "DB_DATABASE"
          valueFrom = "${var.container_secret}:DB_DATABASE::"
        },
        {
          name      = "DB_USER"
          valueFrom = "${var.container_secret}:DB_USER::"
        },
        {
          name      = "DB_PASSWORD"
          valueFrom = "${var.container_secret}:DB_PASSWORD::"
        },
        {
          name      = "STORAGE_LOCATIONS"
          valueFrom = "${var.container_secret}:STORAGE_LOCATIONS::"
        },
        {
          name      = "STORAGE_SUPABASE_DRIVER"
          valueFrom = "${var.container_secret}:STORAGE_SUPABASE_DRIVER::"
        },
        {
          name      = "STORAGE_SUPABASE_SERVICE_ROLE"
          valueFrom = "${var.container_secret}:STORAGE_SUPABASE_SERVICE_ROLE::"
        },
        {
          name      = "STORAGE_SUPABASE_BUCKET"
          valueFrom = "${var.container_secret}:STORAGE_SUPABASE_BUCKET::"
        },
        {
          name      = "STORAGE_SUPABASE_PROJECT_ID"
          valueFrom = "${var.container_secret}:STORAGE_SUPABASE_PROJECT_ID::"
        }
      ]

      environment = [
        {
          name  = "DB_CLIENT"
          value = "postgres"
        },
        {
          name  = "STORAGE_SUPABASE_HEALTHCHECK_THRESHOLD"
          value = "1000"
        },
        {
          name  = "CORS_ENABLED"
          value = "true"
        },
        {
          name  = "CORS_ORIGIN"
          value = "*"
        },
        {
          name  = "TELEMETRY"
          value = "false"
        },
      ]

      port_mappings = [
        {
          name          = "directus"
          containerPort = 8055
          protocol      = "tcp"
        }
      ]

      readonly_root_filesystem = false
    }
  }

  load_balancer = {
    service = {
      target_group_arn = module.alb.target_groups["directusCMS"].arn
      container_name   = "directus"
      container_port   = 8055
    }
  }

  subnet_ids = module.vpc.public_subnets
  security_group_rules = {
    directus_ingress = {
      type                     = "ingress"
      from_port                = 8055
      to_port                  = 8055
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.alb.security_group_id
    }
    all_egress = {
      type        = "egress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      description = "Allow all egress traffic"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = local.tags
}


################################################################################
# Supporting Resources
################################################################################

# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html#ecs-optimized-ami-linux
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended"
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name = local.name

  load_balancer_type = "application"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  # For example only
  enable_deletion_protection = false

  # Security Group
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }

    all_https = {
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  listeners = {
    ex_directus = {
      port     = 80
      protocol = "HTTP"

      forward = {
        target_group_key = "directusCMS"
      }
    }

    ex_directus_https = {
      port            = 443
      protocol        = "HTTPS"
      ssl_policy      = "ELBSecurityPolicy-2016-08"
      certificate_arn = "arn:aws:acm:eu-central-1:211125586837:certificate/772ba8fd-3220-4f14-9ed3-adff998efb96"

      forward = {
        target_group_key = "directusCMS"
      }
    }
  }



  target_groups = {
    directusCMS = {
      protocol                          = "HTTP"
      port                              = 8055
      target_type                       = "instance"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 300
        matcher             = "200"
        path                = "/server/health"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # Theres nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }
  }

  tags = local.tags
}

module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 7.4"

  name = local.name

  # On-demand instances

  instance_type              = "t3.micro"
  use_mixed_instances_policy = false
  block_device_mappings = [
    {
      # Root volume
      device_name = "/dev/xvda"
      no_device   = 0
      ebs = {
        delete_on_termination = true
        encrypted             = true
        volume_size           = 30
        volume_type           = "gp3"
      }
    }
  ]


  user_data = base64encode(local.user_data)




  image_id = jsondecode(data.aws_ssm_parameter.ecs_optimized_ami.value)["image_id"]


  security_groups             = [module.autoscaling_sg.security_group_id]
  iam_instance_profile_name   = "ecsInstanceRole"
  create_iam_instance_profile = false

  ##

  ignore_desired_capacity_changes = true


  vpc_zone_identifier = module.vpc.public_subnets
  health_check_type   = "EC2"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1

  # https://github.com/hashicorp/terraform-provider-aws/issues/12582
  autoscaling_group_tags = {
    AmazonECSManaged = true
  }

  # Required for  managed_termination_protection = "ENABLED"
  protect_from_scale_in = true

  tags = local.tags
}

module "autoscaling_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = local.name
  description = "Autoscaling group security group"
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      rule                     = "http-80-tcp"
      source_security_group_id = module.alb.security_group_id
    }
  ]
  ingress_with_cidr_blocks = [
    {
      from_port   = 8055
      to_port     = 8055
      protocol    = "tcp"
      description = "Directus CMS"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1

  egress_rules = ["all-all"]

  tags = local.tags
}
