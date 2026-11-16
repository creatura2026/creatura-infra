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

override_resource {
  target          = time_static.db_final_snapshot
  override_during = plan
  values          = { rfc3339 = "2026-11-16T09:30:00Z" }
}

variables {
  kubernetes_version           = "1.35"
  endpoint_public_access_cidrs = ["203.0.113.10/32"]
  administrator_principal_arn  = "arn:aws:iam::123456789012:user/admin"
}

run "snapshot_final_a_la_destruction" {
  command = plan

  assert {
    condition     = aws_db_instance.creatura.skip_final_snapshot == false
    error_message = "Détruire la base sans snapshot final efface les comptes des joueurs"
  }
  assert {
    condition     = aws_db_instance.creatura.final_snapshot_identifier == "creatura-db-final-20261116-093000"
    error_message = "Le snapshot final doit commencer par creatura-db- pour être restauré par scripts/latest-db-snapshot.sh"
  }
}

run "restauration_depuis_un_snapshot" {
  command = plan

  variables {
    db_snapshot_identifier = "creatura-db-final-20261116-093000"
  }

  assert {
    condition     = aws_db_instance.creatura.snapshot_identifier == "creatura-db-final-20261116-093000"
    error_message = "Avec db_snapshot_identifier, la base est restaurée depuis ce snapshot"
  }
}
