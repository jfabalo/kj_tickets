# Imagen del worker real de venta de tickets.
#
# Explicacion simple:
#   Empaqueta app/worker/src/worker.py para ejecutarlo como contenedor Fargate.
#
# Explicacion tecnica:
#   Instala dependencias Python, copia el paquete src y arranca `python -m
#   src.worker`. Las conexiones RabbitMQ/PostgreSQL/SQS llegan por variables de
#   entorno inyectadas por Terraform en worker_service.tf.

FROM python:3.13-slim

# PYTHONUNBUFFERED fuerza logs inmediatos hacia CloudWatch.
# PYTHONDONTWRITEBYTECODE evita crear __pycache__ dentro del contenedor.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Directorio de trabajo simple para que `python -m src.worker` resuelva el paquete.
WORKDIR /app

# Copiamos requirements primero para aprovechar cache de Docker si solo cambia codigo.
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Copiamos el paquete Python real del worker.
COPY src/ /app/src/

# Entrada del contenedor Fargate definida por Terraform worker_service.tf.
CMD ["python", "-m", "src.worker"]
