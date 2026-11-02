terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state on purpose (see brief). State files are git-ignored.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "daily-briefing"
      ManagedBy = "terraform"
    }
  }
}
