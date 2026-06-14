# Imagen del load generator.
#
# Explicacion simple:
#   Empaqueta app/loadgen/src/loadgen.py para ejecutarlo como task temporal en
#   ECS/Fargate o como ayuda local.
#
# Explicacion tecnica:
#   El CMD por defecto muestra ayuda porque run-loadgen-aws.ps1 inyecta el comando
#   real con ECS containerOverrides. Terraform proporciona defaults de conexion
#   por variables de entorno en loadgen_task.tf.

FROM python:3.13-slim

# Logs sin buffer para que ECS/CloudWatch los muestre en tiempo real.
# No escribimos bytecode porque la imagen es efimera y no lo necesita.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Dependencias antes que codigo para cachear capas entre cambios del loadgen.
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY src/ /app/src/

# El comando real lo inyecta run-loadgen-aws.ps1 mediante ECS overrides.
CMD ["python", "-m", "src.loadgen", "--help"]
