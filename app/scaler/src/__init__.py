"""Paquete del autoscaler.

El modulo ejecutable es `src.scaler`. Terraform lo ejecuta como servicio
ECS/Fargate para observar RabbitMQ y modificar desired_count de workers.
"""
