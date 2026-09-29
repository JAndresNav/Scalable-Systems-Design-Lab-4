terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state in the existing bucket in this same account.
  # use_lockfile keeps the lock in S3 itself, so no DynamoDB table is needed
  # (the Academy account cannot always create one).
  backend "s3" {
    bucket       = "744998"
    key          = "lab4/terraform.tfstate"
    region       = "us-east-1"
    profile      = "academy"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.name_prefix
      ManagedBy = "terraform"
      Course    = "diseno-sistemas-escalables"
    }
  }
}
