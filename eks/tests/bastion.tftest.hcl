# Plan sans identifiants AWS : terraform -chdir=eks test
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-north-1a", "eu-north-1b"] }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/admin", user_id = "AIDAEXEMPLE" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::123456789012:user/admin" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  kubernetes_version           = "1.35"
  endpoint_public_access_cidrs = ["203.0.113.10/32"]
  administrator_principal_arn  = "arn:aws:iam::123456789012:user/admin"
}

run "sans_bastion_par_defaut" {
  command = plan

  assert {
    condition     = length(aws_instance.bastion) == 0 && length(aws_vpc_security_group_ingress_rule.rds_from_bastion) == 0
    error_message = "Le bastion ne doit pas exister sans create_bastion"
  }
  assert {
    condition     = output.bastion_instance_id == null
    error_message = "Pas d'identifiant de bastion sans bastion"
  }
}

run "bastion_active" {
  command = plan

  variables {
    create_bastion       = true
    bastion_tunnel_users = ["dbAccess"]
  }

  assert {
    condition     = aws_instance.bastion[0].instance_type == "t3.micro" && aws_instance.bastion[0].associate_public_ip_address
    error_message = "Bastion t3.micro (offre gratuite) dans un sous-réseau public"
  }
  assert {
    condition     = aws_instance.bastion[0].metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 obligatoire"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.rds_from_bastion[0].from_port == 5432
    error_message = "La base doit accepter le bastion sur le port 5432"
  }
  assert {
    condition     = keys(aws_iam_user_policy.bastion_tunnel) == ["dbAccess"]
    error_message = "Seuls les utilisateurs cités peuvent ouvrir le tunnel"
  }
}
