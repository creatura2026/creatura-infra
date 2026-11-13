# =============================================================================
# CREATURA - Pare-feu applicatif (AWS WAF) devant CloudFront
#
# Un seul WAF protège tout ce que sert la distribution : le front joueur,
# l'administration et l'API (/api/*). L'ALB de l'API n'accepte déjà que
# CloudFront (eks/api.tf) : on ne peut pas contourner le WAF.
#
# Interrupteur : waf_enabled = false par défaut (le WAF n'est pas dans l'offre
# gratuite) : l'apply automatique de la CI sur main ne le crée pas.
# scripts/aws-up.sh l'active en mode bloquant (option --no-waf pour s'en passer).
#
# Mode : waf_mode = "count" observe sans bloquer (à utiliser d'abord, pour
# vérifier que le jeu normal n'est pas touché), "block" bloque.
#
# Un WAF pour CloudFront doit être créé dans la région us-east-1.
# =============================================================================

variable "waf_enabled" {
  description = "Crée le WAF et l'associe à la distribution CloudFront."
  type        = bool
  default     = false
}

variable "waf_mode" {
  description = "count : les règles comptent sans bloquer ; block : elles bloquent."
  type        = string
  default     = "count"

  validation {
    condition     = contains(["count", "block"], var.waf_mode)
    error_message = "waf_mode doit valoir count ou block."
  }
}

variable "waf_login_rate_limit" {
  description = "Requêtes autorisées par adresse IP et par fenêtre de 5 minutes sur /api/v1/auth/* (connexion, inscription)."
  type        = number
  default     = 100

  validation {
    condition     = var.waf_login_rate_limit >= 10
    error_message = "AWS WAF impose une limite d'au moins 10 requêtes."
  }
}

variable "waf_log_retention_days" {
  description = "Durée de conservation des journaux du WAF, en jours."
  type        = number
  default     = 7
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

locals {
  waf_count = var.waf_enabled ? 1 : 0
  waf_block = var.waf_mode == "block"

  # Groupes de règles gérés par AWS (inclus dans le prix du WAF), par ordre d'évaluation.
  waf_managed_rules = [
    { name = "AWSManagedRulesAmazonIpReputationList", metric = "ip-reputation" },
    { name = "AWSManagedRulesCommonRuleSet", metric = "common" },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", metric = "known-bad-inputs" },
    { name = "AWSManagedRulesSQLiRuleSet", metric = "sql-injection" },
  ]
}

resource "aws_wafv2_web_acl" "creatura" {
  count    = local.waf_count
  provider = aws.us_east_1

  name        = "creatura-cloudfront"
  description = "Creatura - front, administration et API servis par CloudFront"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Essais de mots de passe en rafale sur la connexion et l'inscription.
  rule {
    name     = "limite-auth"
    priority = 0

    action {
      dynamic "block" {
        for_each = local.waf_block ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.waf_block ? [] : [1]
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit                 = var.waf_login_rate_limit
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/v1/auth/"
            positional_constraint = "STARTS_WITH"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "creatura-limite-auth"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.waf_managed_rules

    content {
      name     = rule.value.name
      priority = rule.key + 1

      # En mode count, les règles du groupe sont seulement comptées.
      override_action {
        dynamic "none" {
          for_each = local.waf_block ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = local.waf_block ? [] : [1]
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "creatura-${rule.value.metric}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "creatura-cloudfront"
    sampled_requests_enabled   = true
  }
}

# Journaux : le nom du groupe doit commencer par aws-waf-logs-.
resource "aws_cloudwatch_log_group" "waf" {
  count    = local.waf_count
  provider = aws.us_east_1

  name              = "aws-waf-logs-creatura"
  retention_in_days = var.waf_log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "creatura" {
  count    = local.waf_count
  provider = aws.us_east_1

  resource_arn            = aws_wafv2_web_acl.creatura[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]
}

output "waf_web_acl_arn" {
  description = "WAF associé à CloudFront. Vide si waf_enabled = false."
  value       = try(aws_wafv2_web_acl.creatura[0].arn, "")
}
