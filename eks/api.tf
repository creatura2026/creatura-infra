# =============================================================================
# CREATURA - Entrée publique de l'API : CloudFront -> ALB -> NodePort du back
#
# L'ALB est géré ici par Terraform (pas par un contrôleur Kubernetes) : son nom
# DNS est une sortie de la stack et `terraform destroy` le supprime sans étape
# manuelle. Il vise le NodePort du Service creatura-backend sur chaque nœud.
#
# Seul CloudFront peut le joindre (liste de préfixes gérée par AWS) : les
# navigateurs passent par https://<domaine CloudFront>/api/*, la même origine
# que le front. La route est déclarée dans infra/cloudfront.tf, à partir de la
# sortie api_origin_domain_name.
#
# Limite connue : sans nom de domaine, pas de certificat pour l'ALB. Le tronçon
# CloudFront -> ALB est donc en HTTP. Avec un domaine : certificat ACM, écouteur
# 443 ici, et origin_protocol_policy = "https-only" côté CloudFront.
# =============================================================================

variable "api_node_port" {
  description = "NodePort du Service creatura-backend (k8s/backend/service.yaml)."
  type        = number
  default     = 30080
}

variable "api_health_path" {
  description = "Chemin de santé de l'API, interrogé par l'ALB sur chaque nœud."
  type        = string
  default     = "/api/v1/health"
}

data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "api_alb" {
  name_prefix = "creatura-api-alb-"
  description = "ALB de l API Creatura - entree limitee a CloudFront"
  vpc_id      = module.vpc.vpc_id
  tags        = { Component = "api" }

  lifecycle {
    create_before_destroy = true
  }
}

# Cette liste de préfixes compte pour 55 règles sur les 60 autorisées par groupe :
# ne pas ajouter d'autres règles d'entrée ici.
resource "aws_vpc_security_group_ingress_rule" "api_alb_from_cloudfront" {
  security_group_id = aws_security_group.api_alb.id
  description       = "HTTP depuis CloudFront uniquement"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
}

# L'entrée correspondante sur les nœuds est dans main.tf (node_security_group_additional_rules).
resource "aws_vpc_security_group_egress_rule" "api_alb_to_nodes" {
  security_group_id            = aws_security_group.api_alb.id
  description                  = "Trafic et controles de sante vers le NodePort du back"
  ip_protocol                  = "tcp"
  from_port                    = var.api_node_port
  to_port                      = var.api_node_port
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_lb" "api" {
  name               = "${var.cluster_name}-api"
  load_balancer_type = "application"
  internal           = false
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.api_alb.id]

  drop_invalid_header_fields = true
  tags                       = { Component = "api" }
}

resource "aws_lb_target_group" "api" {
  name_prefix          = "capi-"
  port                 = var.api_node_port
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 30
  tags                 = { Component = "api" }

  # Le NodePort répond sur tous les nœuds dès qu'un pod du back est prêt.
  health_check {
    path                = var.api_health_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Les WebSocket de la salle d'échange passent par cet écouteur sans réglage particulier.
resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# Les nœuds du groupe managé s'inscrivent d'eux-mêmes comme cibles, y compris après un remplacement.
resource "aws_autoscaling_attachment" "api" {
  autoscaling_group_name = module.eks.eks_managed_node_groups["backend"].node_group_autoscaling_group_names[0]
  lb_target_group_arn    = aws_lb_target_group.api.arn
}

output "api_origin_domain_name" {
  description = "Nom DNS de l'ALB : valeur de la variable api_origin_domain_name de la stack infra/."
  value       = aws_lb.api.dns_name
}
