# -----------------------------------------------------------------------------
# Bastion SSM (facultatif) : atteindre la base depuis un poste, sans l'ouvrir au public.
#
# Petite instance EC2 sans port ouvert ni clé SSH : on l'atteint par Session Manager
# (HTTPS 443, marche aussi sur les réseaux qui bloquent le 5432), qui relaie vers la RDS.
# Sur le poste, la base répond alors sur localhost:15432 (commande en sortie : bastion_tunnel_command).
#
# Activer : create_bastion = true et bastion_tunnel_users = ["<utilisateur IAM>"], puis apply.
# Retirer : create_bastion = false, puis apply (instance, rôle, groupe et règle supprimés).
#
# Placé dans un sous-réseau public avec une IP publique (aucune règle entrante) : l'agent SSM
# joint AWS sans le NAT, donc le bastion marche aussi quand la stack est en pause (paused = true).
# -----------------------------------------------------------------------------

variable "create_bastion" {
  description = "Crée le bastion SSM pour accéder à la base depuis un poste (environ 3 $/mois)."
  type        = bool
  default     = false
}

variable "bastion_tunnel_users" {
  description = "Noms des utilisateurs IAM autorisés à ouvrir le tunnel vers la base par ce bastion."
  type        = list(string)
  default     = []
}

variable "bastion_instance_type" {
  description = "Type d'instance (Graviton, ARM64) : le bastion ne fait que relayer."
  type        = string
  default     = "t4g.nano"
}

locals {
  bastion_count = var.create_bastion ? 1 : 0
  bastion_name  = "${var.cluster_name}-bastion"
}

# Dernière Amazon Linux 2023 ARM64 (l'agent SSM y est préinstallé).
data "aws_ssm_parameter" "bastion_ami" {
  count = local.bastion_count
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# Rôle de l'instance : juste ce qu'il faut pour s'enregistrer auprès de Session Manager.
resource "aws_iam_role" "bastion" {
  count = local.bastion_count
  name  = local.bastion_name
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count      = local.bastion_count
  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  count = local.bastion_count
  name  = local.bastion_name
  role  = aws_iam_role.bastion[0].name
}

# Aucune règle entrante : tout passe par Session Manager.
resource "aws_security_group" "bastion" {
  count       = local.bastion_count
  name_prefix = "${local.bastion_name}-"
  description = "Bastion SSM - aucune entree"
  vpc_id      = module.vpc.vpc_id
  tags        = { Name = local.bastion_name }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  count             = local.bastion_count
  security_group_id = aws_security_group.bastion[0].id
  description       = "Session Manager (HTTPS) et la base"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# La base accepte le bastion, en plus des nœuds du cluster.
resource "aws_vpc_security_group_ingress_rule" "rds_from_bastion" {
  count                        = local.bastion_count
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL depuis le bastion SSM"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.bastion[0].id
}

resource "aws_instance" "bastion" {
  count                       = local.bastion_count
  ami                         = data.aws_ssm_parameter.bastion_ami[0].insecure_value
  instance_type               = var.bastion_instance_type
  subnet_id                   = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.bastion[0].id]
  iam_instance_profile        = aws_iam_instance_profile.bastion[0].name

  metadata_options {
    http_tokens = "required" # IMDSv2 uniquement
  }

  root_block_device {
    encrypted = true
  }

  tags = { Name = local.bastion_name }

  lifecycle {
    # Une nouvelle AMI ne doit pas recréer le bastion à chaque apply.
    ignore_changes = [ami]
  }
}

# Chaque utilisateur cité peut ouvrir un tunnel vers ce bastion, et rien d'autre.
resource "aws_iam_user_policy" "bastion_tunnel" {
  for_each = var.create_bastion ? toset(var.bastion_tunnel_users) : toset([])
  name     = "${local.bastion_name}-tunnel"
  user     = each.value
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:StartSession"
        Resource = [
          aws_instance.bastion[0].arn,
          "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/AWS-StartPortForwardingSessionToRemoteHost",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:TerminateSession", "ssm:ResumeSession"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:*:*:session/$${aws:username}-*"
      },
    ]
  })
}

output "bastion_instance_id" {
  description = "Identifiant du bastion SSM (null s'il n'est pas créé)."
  value       = var.create_bastion ? aws_instance.bastion[0].id : null
}

output "bastion_tunnel_command" {
  description = "Tunnel vers la base depuis un poste : elle répond ensuite sur localhost:15432."
  value = var.create_bastion ? join(" ", [
    "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.bastion[0].id}",
    "--document-name AWS-StartPortForwardingSessionToRemoteHost",
    "--parameters host=${aws_db_instance.creatura.address},portNumber=5432,localPortNumber=15432",
  ]) : null
}
