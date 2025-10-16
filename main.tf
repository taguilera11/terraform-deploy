########################################
# Terraform + Provider
########################################
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

########################################
# Variables
########################################
variable "aws_region"    { default = "us-east-1" }
variable "project_name"  { default = "sprint2" }
variable "instance_type" { default = "t2.nano" } # sube para DB si necesitas
variable "git_repo_url"  { default = "https://github.com/SSUAREZD/ProyectoArquisoftHermonitos.git" }
variable "git_branch"    { default = "vm-deploy" }

# Credenciales DB
variable "db_name"       { default = "proyecto_arquisoft" }
variable "db_user"       { default = "django" }
variable "db_password"   { default = "sprint2" }

# ALLOWED_HOSTS para Django (puede ser * o la IP/dominio)
variable "allowed_hosts" { default = "*" }

########################################
# Datos: VPC / Subnets / AMI Ubuntu 24.04
########################################
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Canonical Ubuntu 24.04 LTS (Noble)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

########################################
# Security Groups
########################################
# App: HTTP/HTTPS abiertos (sin SSH)
resource "aws_security_group" "app_sg" {
  name        = "${var.project_name}-app-sg"
  description = "SG for app (Nginx)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-app-sg" }
}

# DB: 5432 solo desde app_sg
resource "aws_security_group" "db_sg" {
  name        = "${var.project_name}-db-sg"
  description = "SG for PostgreSQL"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Postgres from app_sg"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-db-sg" }
}

########################################
# IAM para SSM (sin key pair / sin SSH)
########################################
resource "aws_iam_role" "ssm_role" {
  name = "${var.project_name}-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${var.project_name}-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

########################################
# EC2: Base de Datos (PostgreSQL)
########################################
resource "aws_instance" "db" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.db_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    apt-get install -y postgresql postgresql-contrib

    # Detecta rutas (14/15/16)
    PGCONF=$(ls /etc/postgresql/*/main/postgresql.conf | head -n1)
    PHBA=$(ls /etc/postgresql/*/main/pg_hba.conf | head -n1)

    # Escuchar en todas las interfaces
    sed -i "s/^#*listen_addresses.*/listen_addresses = '*'/" "$PGCONF"

    # Permitir clientes por md5 (restringe a tu CIDR si quieres)
    echo "host    all             all             0.0.0.0/0               md5" >> "$PHBA"

    systemctl restart postgresql
    systemctl enable postgresql

    # Crear usuario/DB si no existen
    sudo -u postgres psql -c "DO $$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${var.db_user}') THEN
        CREATE ROLE ${var.db_user} LOGIN PASSWORD '${var.db_password}';
      END IF;
    END$$;"

    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '${var.db_name}'" | grep -q 1 || \
      sudo -u postgres createdb -O ${var.db_user} ${var.db_name}
  EOF

  tags = { Name = "${var.project_name}-db" }
}

########################################
# EC2: App (Nginx + Gunicorn + Django + Redis)
########################################
resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    apt-get install -y python3-venv python3-pip git nginx redis-server

    systemctl enable --now redis-server

    APP_DIR="/srv/ProyectoArquisoftHermonitos"
    REPO_URL="${var.git_repo_url}"
    REPO_BRANCH="${var.git_branch}"

    mkdir -p "$APP_DIR"
    cd "$APP_DIR"

    if [ ! -d ".git" ]; then
      git clone "$REPO_URL" .
    fi
    git fetch --all
    git checkout "$REPO_BRANCH"
    git pull --ff-only

    python3 -m venv venv
    . venv/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt

    cat > .env <<ENV
    DJANGO_DEBUG=False
    DJANGO_SECRET_KEY=sprint2
    ALLOWED_HOSTS=${var.allowed_hosts}

    DB_NAME=${var.db_name}
    DB_USER=${var.db_user}
    DB_PASSWORD=${var.db_password}
    DB_HOST=${aws_instance.db.private_ip}
    DB_PORT=5432

    REDIS_URL=redis://127.0.0.1:6379/1
    ENV

    # Migraciones
    python manage.py migrate

    # Gunicorn como servicio
    cat >/etc/systemd/system/gunicorn.service <<'UNIT'
    [Unit]
    Description=gunicorn daemon for ProyectoArquisoft
    After=network.target

    [Service]
    User=ubuntu
    Group=www-data
    WorkingDirectory=/srv/ProyectoArquisoftHermonitos
    Environment="PATH=/srv/ProyectoArquisoftHermonitos/venv/bin"
    ExecStart=/srv/ProyectoArquisoftHermonitos/venv/bin/gunicorn \
      --workers 2 \
      --bind unix:/srv/ProyectoArquisoftHermonitos/gunicorn.sock \
      proyectoArquisoft.wsgi:application
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now gunicorn

    # Nginx reverse proxy
    cat >/etc/nginx/sites-available/proyecto <<'NGINX'
    server {
        listen 80;
        server_name _;

        # Estáticos (si más adelante usas collectstatic)
        # location /static/ {
        #     alias /srv/ProyectoArquisoftHermonitos/static/;
        # }

        location / {
            include proxy_params;
            proxy_pass http://unix:/srv/ProyectoArquisoftHermonitos/gunicorn.sock;
        }
    }
    NGINX

    ln -sf /etc/nginx/sites-available/proyecto /etc/nginx/sites-enabled/proyecto
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl reload nginx
    systemctl enable nginx
  EOF

  depends_on = [aws_instance.db]

  tags = { Name = "${var.project_name}-app" }
}

########################################
# Outputs
########################################
output "app_public_ip" {
  value       = aws_instance.app.public_ip
  description = "IP pública de la APP (Nginx)."
}

output "db_private_ip" {
  value       = aws_instance.db.private_ip
  description = "IP privada de la DB (PostgreSQL)."
}
