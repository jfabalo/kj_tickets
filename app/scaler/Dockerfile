# Imagen del autoscaler.
#
# Explicacion simple:
#   Empaqueta app/scaler/src/scaler.py para ejecutarlo como servicio Fargate.
#
# Explicacion tecnica:
#   El contenedor consulta RabbitMQ Management API y actualiza desired_count del
#   ECS service de workers. Terraform inyecta endpoints, credenciales y limites.

FROM python:3.13-slim

# Necesario para ver decisiones del scaler en CloudWatch sin retraso.
# Evita escribir __pycache__ en el contenedor.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# requests/boto3 se instalan aqui para consultar RabbitMQ y ECS.
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY src/ /app/src/

# Servicio de larga vida: ECS mantiene una task corriendo si desired_count=1.
CMD ["python", "-m", "src.scaler"]
