# core_infra.tf
#
# Objetivo del archivo:
#   Crear la infraestructura base que permanece viva durante las pruebas:
#   - RabbitMQ en EC2 como cola asincrona.
#   - PostgreSQL en EC2 como fuente de verdad transaccional.
#   - SQS DLQ para fallos definitivos.
#   - ECR para imagenes Docker de worker/loadgen/scaler.
#   - Security groups para separar trafico interno y acceso del operador.
#
# Por que esta separado de worker/loadgen/scaler:
#   RabbitMQ y PostgreSQL tardan mas en arrancar. Mantenerlos como base estable
#   evita recrear todo el stack en cada experimento y reduce tiempo/coste.

locals {
  # Nombre comun usado como prefijo en recursos AWS.
  # Ejemplo con defaults: ticket-service-academy.
  core_name = "${var.project_name}-${var.environment}"

  # Subnet fija para las EC2. sort() hace que la eleccion sea determinista aunque
  # AWS devuelva las subnets en distinto orden.
  core_subnet_id = sort(data.aws_subnets.default.ids)[0]

  # Patron count=0/1. Cuando enable_core_infra=false no se crea infraestructura
  # real, evitando costes accidentales en AWS Academy.
  core_resources = var.enable_core_infra ? 1 : 0

  # Usuario RabbitMQ creado en el bootstrap de la instancia.
  rabbitmq_user = "ticket_user"
  # Usuario PostgreSQL creado por el contenedor postgres.
  postgres_user = "ticket_user"
  # Base de datos de la aplicacion.
  postgres_db = "tickets"
  # Cola principal de compras pendiente de procesar.
  rabbitmq_queue = "tickets.buy"
  # Vhost RabbitMQ por defecto. En la API HTTP se codifica como %2F.
  rabbitmq_vhost = "/"
  # Puerto de RabbitMQ Management UI/API.
  rabbitmq_ui_port = 15672
  # Puerto AMQP usado por loadgen y workers.
  rabbitmq_port = 5672
  # Puerto PostgreSQL usado por workers, loadgen y scripts locales.
  postgres_port = 5432
}

# AMI Amazon Linux 2023 obtenida desde SSM Parameter Store.
# Esto evita hardcodear AMI IDs, que cambian por region y con el tiempo.
data "aws_ssm_parameter" "al2023_ami" {
  # Solo se consulta cuando vamos a crear EC2.
  count = local.core_resources

  # Ruta oficial de AWS para la ultima AMI AL2023 x86_64.
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "random_password" "rabbitmq" {
  # Password generada solo si existe RabbitMQ.
  count = local.core_resources

  # 24 caracteres es suficiente para credencial temporal del laboratorio.
  length = 24
  # Sin caracteres especiales para evitar problemas de escaping en user_data/bash.
  special = false
}

resource "random_password" "postgres" {
  # Password generada solo si existe PostgreSQL.
  count = local.core_resources

  # Misma longitud que RabbitMQ.
  length = 24
  # Sin caracteres especiales para evitar problemas al inyectar en docker run.
  special = false
}

resource "aws_security_group" "workers" {
  # Security group de las tasks Fargate: worker, loadgen y scaler.
  count = local.core_resources

  # Nombre visible en EC2 Security Groups.
  name = "${local.core_name}-workers"
  # No expone puertos inbound porque las tasks no reciben trafico externo.
  description = "Ticket worker tasks: no inbound traffic"
  # Se crea en la default VPC de AWS Academy.
  vpc_id = data.aws_vpc.default.id

  egress {
    # Las tasks necesitan salida a:
    # - RabbitMQ/PostgreSQL por IP privada.
    # - ECR para pull de imagenes.
    # - CloudWatch Logs para logs.
    # - SQS para DLQ.
    # - ECS API para el autoscaler.
    description = "Allow outbound traffic to RabbitMQ, PostgreSQL, ECR, CloudWatch, and SQS"
    # from_port/to_port 0 + protocol -1 significa todos los puertos/protocolos.
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Salida abierta. El control real de entrada esta en SG de RabbitMQ/Postgres.
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rabbitmq" {
  # Security group asociado a la EC2 RabbitMQ.
  count = local.core_resources

  # Nombre visible para identificar el broker.
  name = "${local.core_name}-rabbitmq"
  # Describe que acepta trafico interno de workers y debug del operador.
  description = "RabbitMQ broker access for workers and operator"
  # Misma default VPC que el resto del stack.
  vpc_id = data.aws_vpc.default.id

  ingress {
    # Camino principal: Fargate publica/consume por AMQP usando IP privada.
    description = "AMQP from ECS workers"
    # Puerto inicial y final iguales porque solo abrimos 5672.
    from_port = local.rabbitmq_port
    to_port   = local.rabbitmq_port
    # AMQP usa TCP.
    protocol = "tcp"
    # Permite solo origen con SG workers, no todo internet.
    security_groups = [aws_security_group.workers[0].id]
  }

  ingress {
    # Camino auxiliar para operador: pruebas/debug desde maquina local si hace falta.
    description = "AMQP from operator for load generator tests"
    from_port   = local.rabbitmq_port
    to_port     = local.rabbitmq_port
    protocol    = "tcp"
    # Solo la IP publica indicada en var.operator_cidr.
    cidr_blocks = [var.operator_cidr]
  }

  ingress {
    # UI/API Management para observar cola, tasas y purgar mensajes.
    description = "RabbitMQ management UI from operator"
    from_port   = local.rabbitmq_ui_port
    to_port     = local.rabbitmq_ui_port
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }

  ingress {
    # El autoscaler corre en Fargate y lee RabbitMQ Management API por IP privada.
    description = "RabbitMQ management API from ECS scaler"
    from_port   = local.rabbitmq_ui_port
    to_port     = local.rabbitmq_ui_port
    protocol    = "tcp"
    # Origen: SG workers, compartido por scaler/worker/loadgen.
    security_groups = [aws_security_group.workers[0].id]
  }

  egress {
    # Permite que RabbitMQ salga para updates/bootstrap si lo necesita.
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "postgres" {
  # Security group asociado a la EC2 PostgreSQL.
  count = local.core_resources

  # Nombre visible en AWS.
  name = "${local.core_name}-postgres"
  # PostgreSQL acepta trafico interno y mantenimiento desde operador.
  description = "PostgreSQL access for workers and operator"
  # Default VPC de la practica.
  vpc_id = data.aws_vpc.default.id

  ingress {
    # Camino principal: worker/loadgen escriben requests, sales y metricas.
    description = "PostgreSQL from ECS workers"
    from_port   = local.postgres_port
    to_port     = local.postgres_port
    protocol    = "tcp"
    # Solo tasks Fargate con SG workers.
    security_groups = [aws_security_group.workers[0].id]
  }

  ingress {
    # Camino auxiliar: scripts locales limpian estado y exportan CSV.
    description = "PostgreSQL from operator for debug and metric exports"
    from_port   = local.postgres_port
    to_port     = local.postgres_port
    protocol    = "tcp"
    # Solo IP publica del operador.
    cidr_blocks = [var.operator_cidr]
  }

  egress {
    # Permite salida para bootstrap/updates.
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_sqs_queue" "ticket_failures_dlq" {
  # DLQ creada solo con core infra.
  count = local.core_resources

  # Nombre de la cola de fallos definitivos.
  name = "${local.core_name}-ticket-failures-dlq"
  # 14 dias: maximo SQS. Permite inspeccionar fallos despues de pruebas.
  message_retention_seconds = 1209600
  # Cifrado gestionado por SQS sin tener que crear KMS keys en Academy.
  sqs_managed_sse_enabled = true
}

resource "aws_ecr_repository" "worker" {
  # Repositorio ECR de la imagen app/worker.
  count = local.core_resources

  # Nombre configurable para evitar colisiones si se reutiliza cuenta.
  name = var.worker_repository_name
  # Permite terraform destroy aunque queden imagenes dentro del repositorio.
  force_delete = true

  image_scanning_configuration {
    # Desactivado para ahorrar tiempo/coste en la practica.
    scan_on_push = false
  }
}

resource "aws_ecr_repository" "loadgen" {
  # Repositorio ECR de la imagen app/loadgen.
  count = local.core_resources

  # Nombre del repo de generador de carga.
  name = var.loadgen_repository_name
  # Facilita limpieza completa con destroy.
  force_delete = true

  image_scanning_configuration {
    # No necesitamos escaneo para la entrega academica.
    scan_on_push = false
  }
}

resource "aws_ecr_repository" "scaler" {
  # Repositorio ECR de la imagen app/scaler.
  count = local.core_resources

  # Nombre del repo del autoscaler.
  name = var.scaler_repository_name
  # Destroy elimina repo aunque tenga imagen latest.
  force_delete = true

  image_scanning_configuration {
    # Escaneo desactivado para despliegue mas rapido.
    scan_on_push = false
  }
}

resource "aws_instance" "rabbitmq" {
  # Instancia EC2 que ejecuta RabbitMQ en Docker.
  count = local.core_resources

  # AMI Amazon Linux 2023 obtenida por SSM.
  ami = data.aws_ssm_parameter.al2023_ami[0].value
  # Tipo pequeno para controlar coste en AWS Academy.
  instance_type = var.ec2_instance_type
  # Subnet determinista dentro de la default VPC.
  subnet_id = local.core_subnet_id
  # Security group que abre AMQP/UI solo a origenes necesarios.
  vpc_security_group_ids = [aws_security_group.rabbitmq[0].id]
  # IP publica necesaria para operador y para no depender de bastion.
  associate_public_ip_address = true
  # Si cambia user_data, Terraform reemplaza instancia para aplicar bootstrap limpio.
  user_data_replace_on_change = true

  root_block_device {
    # Tamano del disco raiz. Guarda tambien el volumen Docker RabbitMQ.
    volume_size = var.ec2_root_volume_size
    # gp3 es el tipo EBS moderno y barato.
    volume_type = "gp3"
    # Al destruir EC2 se elimina el volumen para no dejar coste residual.
    delete_on_termination = true
  }

  # Script de arranque ejecutado por cloud-init la primera vez que inicia la EC2.
  # Instala Docker, arranca RabbitMQ Management y crea exchange/cola/binding.
  user_data = <<-EOF
    #!/bin/bash
    # Falla ante errores, variables indefinidas o pipes fallidos.
    set -euxo pipefail

    # Actualiza paquetes base de Amazon Linux.
    dnf update -y
    # Instala Docker para ejecutar RabbitMQ como contenedor.
    dnf install -y docker
    # Activa Docker y lo arranca inmediatamente.
    systemctl enable --now docker

    # Directorio persistente para datos de RabbitMQ en la instancia.
    mkdir -p /opt/rabbitmq
    # Elimina contenedor anterior si se reejecuta el bootstrap manualmente.
    docker rm -f ticket-rabbitmq || true
    # Arranca RabbitMQ con plugin management incluido.
    docker run -d \
      --name ticket-rabbitmq \
      --restart unless-stopped \
      -p ${local.rabbitmq_port}:5672 \
      -p ${local.rabbitmq_ui_port}:15672 \
      -e RABBITMQ_DEFAULT_USER='${local.rabbitmq_user}' \
      -e RABBITMQ_DEFAULT_PASS='${random_password.rabbitmq[0].result}' \
      -v /opt/rabbitmq:/var/lib/rabbitmq \
      rabbitmq:3-management

    # Espera hasta que la Management API responda antes de crear exchange/cola.
    for i in {1..60}; do
      if curl -fsS -u '${local.rabbitmq_user}:${random_password.rabbitmq[0].result}' http://localhost:15672/api/overview >/dev/null; then
        break
      fi
      sleep 5
    done

    # Crea exchange direct durable donde publica el loadgen.
    curl -fsS -u '${local.rabbitmq_user}:${random_password.rabbitmq[0].result}' \
      -H 'content-type: application/json' \
      -X PUT http://localhost:15672/api/exchanges/%2F/tickets.exchange \
      -d '{"type":"direct","durable":true,"auto_delete":false,"internal":false,"arguments":{}}'

    # Crea cola durable tickets.buy, donde esperan las compras.
    curl -fsS -u '${local.rabbitmq_user}:${random_password.rabbitmq[0].result}' \
      -H 'content-type: application/json' \
      -X PUT http://localhost:15672/api/queues/%2F/${local.rabbitmq_queue} \
      -d '{"durable":true,"auto_delete":false,"arguments":{}}'

    # Une exchange y cola con routing key ticket.buy.
    curl -fsS -u '${local.rabbitmq_user}:${random_password.rabbitmq[0].result}' \
      -H 'content-type: application/json' \
      -X POST http://localhost:15672/api/bindings/%2F/e/tickets.exchange/q/${local.rabbitmq_queue} \
      -d '{"routing_key":"ticket.buy","arguments":{}}'
  EOF

  tags = {
    # Nombre humano en consola EC2.
    Name = "${local.core_name}-rabbitmq"
    # Rol funcional para filtrar recursos.
    Role = "rabbitmq"
  }
}

resource "aws_instance" "postgres" {
  # Instancia EC2 que ejecuta PostgreSQL en Docker.
  count = local.core_resources

  # AMI Amazon Linux 2023.
  ami = data.aws_ssm_parameter.al2023_ami[0].value
  # Misma clase que RabbitMQ para mantener coste bajo.
  instance_type = var.ec2_instance_type
  # Misma subnet determinista.
  subnet_id = local.core_subnet_id
  # Security group de PostgreSQL.
  vpc_security_group_ids = [aws_security_group.postgres[0].id]
  # IP publica para scripts locales de mantenimiento/exportacion.
  associate_public_ip_address = true
  # Reemplaza instancia si cambia el schema/bootstrap.
  user_data_replace_on_change = true

  root_block_device {
    # Espacio para Docker y datos PostgreSQL.
    volume_size = var.ec2_root_volume_size
    # Disco gp3.
    volume_type = "gp3"
    # Evita volumenes huerfanos al destruir.
    delete_on_termination = true
  }

  # Bootstrap de PostgreSQL: instala Docker, escribe schema SQL inicial y arranca
  # postgres:16-alpine con volumen persistente en /opt/postgres/data.
  user_data = <<-EOF
    #!/bin/bash
    # Modo estricto para detectar errores de arranque.
    set -euxo pipefail

    # Actualiza paquetes base.
    dnf update -y
    # Instala Docker.
    dnf install -y docker
    # Arranca y habilita Docker.
    systemctl enable --now docker

    # Directorios persistentes: data para DB, init para scripts de inicializacion.
    mkdir -p /opt/postgres/data /opt/postgres/init
    # Script ejecutado automaticamente por la imagen postgres en primer arranque.
    cat > /opt/postgres/init/01_schema.sql <<'SQL'
    -- Tabla de experimentos: agrupa requests por run_id para poder medir tests.
    CREATE TABLE IF NOT EXISTS experiment_runs (
      run_id UUID PRIMARY KEY,
      workload_name TEXT NOT NULL,
      mode TEXT NOT NULL CHECK (mode IN ('unnumbered', 'numbered')),
      started_at TIMESTAMPTZ NOT NULL,
      completed_at TIMESTAMPTZ,
      expected_requests INTEGER,
      notes TEXT
    );

    -- Pool global para tickets no numerados. sold_count nunca puede superar total.
    CREATE TABLE IF NOT EXISTS ticket_pools (
      pool_id TEXT PRIMARY KEY,
      total_tickets INTEGER NOT NULL CHECK (total_tickets > 0),
      sold_count INTEGER NOT NULL DEFAULT 0 CHECK (sold_count >= 0),
      CHECK (sold_count <= total_tickets)
    );

    -- Inicializa el pool principal de 100000 tickets no numerados.
    INSERT INTO ticket_pools(pool_id, total_tickets, sold_count)
    VALUES ('main', 100000, 0)
    ON CONFLICT (pool_id) DO NOTHING;

    -- Tabla de asientos numerados: cada seat_id representa un asiento unico.
    CREATE TABLE IF NOT EXISTS seats (
      seat_id INTEGER PRIMARY KEY CHECK (seat_id BETWEEN 1 AND 100000),
      status TEXT NOT NULL CHECK (status IN ('available', 'sold')),
      request_id UUID UNIQUE,
      sold_at TIMESTAMPTZ
    );

    -- Crea los 100000 asientos numerados si no existen.
    INSERT INTO seats(seat_id, status)
    SELECT gs, 'available'
    FROM generate_series(1, 100000) AS gs
    ON CONFLICT (seat_id) DO NOTHING;

    -- Tabla central de requests y metricas end-to-end.
    CREATE TABLE IF NOT EXISTS requests (
      request_id UUID PRIMARY KEY,
      run_id UUID REFERENCES experiment_runs(run_id),
      mode TEXT NOT NULL CHECK (mode IN ('unnumbered', 'numbered')),
      seat_id INTEGER,
      status TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      enqueued_at TIMESTAMPTZ NOT NULL,
      worker_started_at TIMESTAMPTZ,
      completed_at TIMESTAMPTZ,
      result TEXT,
      error TEXT
    );

    -- Ventas efectivas. UNIQUE sobre request_id da idempotencia de negocio.
    -- UNIQUE sobre seat_id evita overselling en tickets numerados.
    CREATE TABLE IF NOT EXISTS sales (
      sale_id BIGSERIAL PRIMARY KEY,
      request_id UUID NOT NULL UNIQUE REFERENCES requests(request_id),
      mode TEXT NOT NULL CHECK (mode IN ('unnumbered', 'numbered')),
      seat_id INTEGER UNIQUE,
      sold_at TIMESTAMPTZ NOT NULL
    );

    -- Indice para exportar metricas por experimento rapidamente.
    CREATE INDEX IF NOT EXISTS idx_requests_run_id ON requests(run_id);
    -- Indice para ordenar/filtrar requests completadas.
    CREATE INDEX IF NOT EXISTS idx_requests_completed_at ON requests(completed_at);
    -- Indice para analisis temporal de ventas.
    CREATE INDEX IF NOT EXISTS idx_sales_sold_at ON sales(sold_at);
    SQL

    # Elimina contenedor anterior si existe.
    docker rm -f ticket-postgres || true
    # Arranca PostgreSQL con DB/usuario/password de Terraform y schema inicial.
    docker run -d \
      --name ticket-postgres \
      --restart unless-stopped \
      -p ${local.postgres_port}:5432 \
      -e POSTGRES_DB='${local.postgres_db}' \
      -e POSTGRES_USER='${local.postgres_user}' \
      -e POSTGRES_PASSWORD='${random_password.postgres[0].result}' \
      -v /opt/postgres/data:/var/lib/postgresql/data \
      -v /opt/postgres/init:/docker-entrypoint-initdb.d \
      postgres:16-alpine
  EOF

  tags = {
    # Nombre humano en consola EC2.
    Name = "${local.core_name}-postgres"
    # Rol funcional para filtrar recursos.
    Role = "postgres"
  }
}
