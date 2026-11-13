# =============================================================================
# CREATURA - Domaine du site : zone Route 53 déléguée et certificat HTTPS
#
# Stack PERMANENTE, à part : scripts/aws-down.sh ne la détruit pas. Une zone
# recréée change de serveurs de noms, et il faudrait refaire la délégation chez
# le registrar ; le certificat est gardé avec elle.
#
# Seul le sous-domaine (ex. creatura.creasmaloud.dev) est délégué à Route 53 :
# le reste du domaine reste chez le registrar. Après le premier apply, créer chez
# le registrar un enregistrement NS par serveur de la sortie name_servers (HOST :
# le sous-domaine, ex. « creatura »). Le certificat se valide alors seul, en
# quelques minutes (enregistrements de validation créés ici).
#
# La stack infra/ lit ces sorties (scripts/aws-up.sh) : alias du domaine sur la
# distribution CloudFront et enregistrements ALIAS vers elle.
# État local, comme bootstrap/ : terraform.tfstate dans ce dossier, à ne pas perdre.
# =============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "domain_name" {
  description = "Sous-domaine délégué à Route 53, qui sert le site (ex. creatura.creasmaloud.dev)."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "Nom de domaine en minuscules, sans point final (ex. creatura.creasmaloud.dev)."
  }
}

provider "aws" {
  region = "eu-north-1"
  default_tags {
    tags = { Project = "Creatura", ManagedBy = "Terraform", Stack = "dns" }
  }
}

# CloudFront n'accepte que des certificats de us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = { Project = "Creatura", ManagedBy = "Terraform", Stack = "dns" }
  }
}

resource "aws_route53_zone" "site" {
  name    = var.domain_name
  comment = "Creatura : sous-domaine délégué par le registrar (enregistrements NS)"
}

# Route 53 crée le SOA avec un TTL négatif de 86400 s : un « ce nom n'existe pas » mis en cache pendant
# la mise en place (avant l'ALIAS de infra/) durerait jusqu'à 24 h. Ramené à 5 minutes.
resource "aws_route53_record" "soa" {
  zone_id         = aws_route53_zone.site.zone_id
  name            = var.domain_name
  type            = "SOA"
  ttl             = 900
  records         = ["${aws_route53_zone.site.primary_name_server}. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 300"]
  allow_overwrite = true
}

# Le domaine et ses sous-domaines (ex. api.<domaine> plus tard), dans un seul certificat.
resource "aws_acm_certificate" "site" {
  provider                  = aws.us_east_1
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Le domaine et son joker partagent le même enregistrement de validation : allow_overwrite.
resource "aws_route53_record" "validation" {
  for_each = {
    for o in aws_acm_certificate.site.domain_validation_options : o.domain_name => o
  }

  zone_id         = aws_route53_zone.site.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

output "domain_name" {
  value = var.domain_name
}

output "zone_id" {
  value = aws_route53_zone.site.zone_id
}

output "name_servers" {
  description = "À déclarer chez le registrar : un enregistrement NS par serveur, HOST = le sous-domaine."
  value       = aws_route53_zone.site.name_servers
}

output "certificate_arn" {
  description = "Certificat ACM (us-east-1). Utilisable par CloudFront une fois validé (statut ISSUED)."
  value       = aws_acm_certificate.site.arn
}
