##############################
# VARIABLES (ajusta a tu gusto)
##############################
variable "aws_region"    { default = "us-east-1" }
variable "key_name"      { default = "mi-keypair" } # EXISTENTE en tu cuenta
variable "instance_type" { default = "t2.nano" }    # app y db; sube en db si quieres
variable "project_name"  { default = "sprint2" }

# Repo de tu app
variable "git_repo_url"  { default = "https://github.com/SSUAREZD/ProyectoArquisoftHermonitos.git" }
variable "git_branch"    { default = "vm-deploy" }

# Credenciales DB
variable "db_name"       { default = "proyecto_arquisoft" }
variable "db_user"       { default = "django" }
variable "db_password"   { default = "sprint2" }    # cámbiala!

# Dominio/IP (para ALLOWED_HOSTS). Usa * si no tienes dominio aún.
variable "allowed_hosts" { default = "*" }

# AMI Ubuntu 24.04 LTS (HVM) en us-east-1. Cambia si usas otra región.
variable "ubuntu_ami" {
  default = "ami-0e86e20dae9224db8"
}

provider "aws" {
  region = var.aws_region
}

##############################
# SECURITY GROUPS
##############################
# SG de la APP: HTTP/HTTPS abiertos al mundo (y SSH opcional desde tu IP)
resource "aws_security_group" "app_sg" {
  name        = "${var.project_name}-app-sg"
  description = "SG for app (Nginx, Docker)"
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
  # SSH (opcional). Cambia tu IP pública aquí o elimina esta regla.
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
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
}

# SG de la DB: solo acepta 5432 desde el SG de la APP
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
  # SSH opcional a DB (si quieres entrar a administrarla). Elimínalo si no lo necesitas.
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
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
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

##############################
# EC2: BASE DE DATOS (PostgreSQL)
##############################
resource "aws_instance" "db" {
  ami                         = var.ubuntu_ami
  instance_type               = var.instance_type
  subnet_id                   = element(data.aws_subnet_ids.default.ids, 0)
  vpc_security_group_ids      = [aws_security_group.db_sg.id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  tags = {
    Name = "${var.project_name}-db"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    apt-get update -y
    apt-get install -y postgresql postgresql-contrib

    # Asegura que Postgres acepte conexiones
    PGCONF="/etc/postgresql/16/main/postgresql.conf"
    PHBA="/etc/postgresql/16/main/pg_hba.conf"
    if [ ! -f "$PGCONF" ]; then
      # fallback versión (Ubuntu podría tener 14/15/16)
      PGCONF=$(ls /etc/postgresql/*/main/postgresql.conf | head -n1)
      PHBA=$(ls /etc/postgresql/*/main/pg_hba.conf | head -n1)
    fi

    sed -i "s/^#*listen_addresses.*/listen_addresses = '*'/" "$PGCONF"
    # Permite md5 desde la VPC (ajusta el CIDR si quieres ser más estricto)
    echo "host    all             all             0.0.0.0/0               md5" >> "$PHBA"

    systemctl restart postgresql

    # Crea DB y usuario
    sudo -u postgres psql -c "DO $$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${var.db_user}') THEN
        CREATE ROLE ${var.db_user} LOGIN PASSWORD '${var.db_password}';
      END IF;
    END$$;"

    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '${var.db_name}'" | grep -q 1 || \
      sudo -u postgres createdb -O ${var.db_user} ${var.db_name}
  EOF
}

##############################
# EC2: APP (Nginx + Gunicorn + Django + Redis con Docker)
##############################
resource "aws_instance" "app" {
  ami                         = var.ubuntu_ami
  instance_type               = var.instance_type
  subnet_id                   = element(data.aws_subnet_ids.default.ids, 0)
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  tags = {
    Name = "${var.project_name}-app"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -eux

    apt-get update -y
    apt-get install -y docker.io docker-compose-plugin git

    systemctl enable --now docker

    # Carpeta de despliegue
    mkdir -p /srv/app && cd /srv/app

    # Clona el repo
    git clone ${var.git_repo_url} repo
    cd repo
    git fetch --all
    git checkout ${var.git_branch}

    # Escribe .env para Django (app -> usa DB privada)
    cat > .env <<ENV
    DJANGO_DEBUG=False
    DJANGO_SECRET_KEY=sprint2
    ALLOWED_HOSTS=${var.allowed_hosts}

    DB_NAME=${var.db_name}
    DB_USER=${var.db_user}
    DB_PASSWORD=${var.db_password}
    DB_HOST=${aws_instance.db.private_ip}
    DB_PORT=5432

    REDIS_URL=redis://redis:6379/1
    ENV

    # Dockerfile para web (Django + Gunicorn)
    cat > Dockerfile <<'DOCKER'
    FROM python:3.12-slim

    WORKDIR /app
    ENV PYTHONDONTWRITEBYTECODE=1
    ENV PYTHONUNBUFFERED=1

    RUN apt-get update && apt-get install -y build-essential libpq-dev && rm -rf /var/lib/apt/lists/*

    COPY requirements.txt /app/requirements.txt
    RUN pip install --no-cache-dir -r requirements.txt

    COPY . /app

    # Collect static si lo usas en el futuro:
    # RUN python manage.py collectstatic --noinput || true

    # Gunicorn
    CMD ["gunicorn", "--bind", "0.0.0.0:8000", "proyectoArquisoft.wsgi:application", "--workers", "2"]
    DOCKER

    # Nginx conf (reverse proxy a web:8000)
    mkdir -p nginx
    cat > nginx/default.conf <<'NGINX'
    server {
      listen 80;
      server_name _;

      # Estáticos futuros:
      # location /static/ {
      #   alias /static/;
      # }

      location / {
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://web:8000;
      }
    }
    NGINX

    # docker-compose
    cat > docker-compose.yml <<'COMPOSE'
    services:
      web:
        build: .
        env_file: .env
        depends_on:
          - redis
        ports:
          - "8000:8000"   # expuesto solo interno de compose; Nginx atenderá 80
        networks:
          - appnet

      redis:
        image: redis:7-alpine
        command: ["redis-server", "--appendonly", "yes"]
        networks:
          - appnet

      nginx:
        image: nginx:alpine
        ports:
          - "80:80"
        volumes:
          - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
          # - ./static:/static:ro
        depends_on:
          - web
        networks:
          - appnet

    networks:
      appnet:
        driver: bridge
    COMPOSE

    # Instala dependencias y migra (usando contenedor web)
    docker compose build
    docker compose up -d

    # Espera a que web esté arriba y migra/crea superuser opcionalmente
    sleep 8
    docker compose exec -T web python manage.py migrate
    # (opcional) crear superusuario:
    # docker compose exec -T web python manage.py createsuperuser --noinput --username admin --email admin@example.com || true

    # Listo: Nginx en :80 sirve la app (proxy a web:8000), Redis en red interna.
  EOF
}

##############################
# OUTPUTS
##############################
output "app_public_ip" {
  value = aws_instance.app.public_ip
}

output "db_private_ip" {
  value = aws_instance.db.private_ip
}
