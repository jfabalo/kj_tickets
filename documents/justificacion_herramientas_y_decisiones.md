# Justificacion de herramientas y decisiones tecnicas

Este documento explica por que se han usado las herramientas y servicios del proyecto, comparandolos con alternativas razonables. La idea es poder defender no solo "que usamos", sino "por que lo usamos asi".

## Resumen de la arquitectura elegida

```text
Loadgen ECS/Fargate
  -> RabbitMQ en EC2
  -> Workers ECS/Fargate
  -> PostgreSQL en EC2
  -> SQS DLQ para fallos definitivos

Scaler ECS/Fargate
  -> RabbitMQ Management API
  -> ECS UpdateService
  -> cambia desired_count del service de workers
```

El sistema se diseno para cumplir estos requisitos del enunciado:

```text
procesamiento asincrono
workers stateless
persistencia transaccional
no overselling
escalado dinamico
mediciones fiables
tolerancia a fallos
despliegue reproducible
```

## Terraform en vez de despliegue manual

Usamos Terraform porque permite definir la infraestructura como codigo.

Alternativa:

```text
crear recursos manualmente desde AWS Console
```

Por que no era buena opcion:

```text
seria dificil repetir el despliegue
habria mas riesgo de errores manuales
seria mas dificil explicar exactamente que se creo
seria mas facil dejar recursos encendidos por accidente
```

Con Terraform podemos crear y destruir:

```text
EC2 RabbitMQ
EC2 PostgreSQL
ECR
ECS/Fargate
SQS DLQ
CloudWatch Logs
Security Groups
```

Justificacion defendible:

```text
Terraform nos da reproducibilidad, control de coste y trazabilidad. Toda la
infraestructura usada en la practica queda descrita en archivos .tf y se puede
levantar o destruir con comandos.
```

## Terraform en vez de CDK

Inicialmente CDK era una opcion razonable, pero en AWS Academy el bootstrap estandar dio problemas por restricciones del laboratorio.

Problema detectado:

```text
CDK bootstrap crea roles, buckets y recursos auxiliares que pueden fallar en AWS Academy
```

Por eso elegimos Terraform:

```text
no depende del bootstrap moderno de CDK
permite crear ECR explicitamente
permite controlar mejor que recursos se crean
encaja mejor con las restricciones de AWS Academy
```

Justificacion defendible:

```text
Elegimos Terraform porque era la opcion mas robusta dentro de AWS Academy. CDK
habria sido valido en una cuenta AWS completa, pero el laboratorio tenia
restricciones con el bootstrap y Terraform nos permitia controlar mejor el
despliegue.
```

## AWS Academy como entorno real

Usamos AWS Academy porque la practica pide servicios cloud reales y AWS era el entorno disponible.

Nos permite demostrar:

```text
Fargate real
ECS Services reales
EC2 reales
CloudWatch Logs reales
ECR real
SQS real
escalado dinamico real
```

Justificacion defendible:

```text
No simulamos el sistema solo en local. Lo desplegamos en AWS Academy para poder
medir comportamiento real de red, colas, workers, logs y escalado.
```

## VPC default en vez de VPC propia

Usamos la VPC default de AWS Academy.

Alternativa:

```text
crear una VPC propia con subnets, route tables, internet gateway y NAT Gateway
```

Por que elegimos VPC default:

```text
reduce complejidad
reduce tiempo de despliegue
evita NAT Gateway, que consume presupuesto
AWS Academy ya trae subnets publicas funcionales
es suficiente para EC2 y Fargate en esta practica
```

Compensacion:

```text
menos aislamiento que una VPC disenada desde cero
menos parecido a una arquitectura productiva completa
```

Justificacion defendible:

```text
Para una practica academica con presupuesto limitado, la VPC default era una
decision pragmatica. La seguridad se controlo con security groups restrictivos.
```

## EC2 para RabbitMQ en vez de servicio gestionado

Usamos RabbitMQ en EC2 porque el enunciado exige procesamiento asincrono con una cola y menciona RabbitMQ en una VM EC2 como opcion valida.

Alternativas:

```text
Amazon SQS como cola principal
Amazon MQ gestionado
RabbitMQ local
Kafka/MSK
```

Por que no usamos SQS como cola principal:

```text
el enunciado pedia una cola como RabbitMQ en EC2
queriamos usar RabbitMQ Management API para medir backlog y tasas
RabbitMQ permite exchange, routing key, queue y consumidores AMQP clasicos
SQS se reservo para DLQ, no para sustituir RabbitMQ
```

Por que no usamos Amazon MQ:

```text
puede tener mas coste
puede tener restricciones en AWS Academy
anade dependencia de un servicio gestionado que no era necesario
EC2 daba control total y era mas facil de justificar con el enunciado
```

Por que no usamos Kafka/MSK:

```text
mas complejo para esta practica
mas coste
el patron necesario era cola de trabajo, no streaming distribuido complejo
```

Por que EC2 tiene sentido:

```text
instalamos RabbitMQ con Docker
controlamos exchange, queue y binding
tenemos RabbitMQ Management UI/API
podemos medir messages_ready, unacked, consumers y publish_rate
```

Justificacion defendible:

```text
Usamos RabbitMQ en EC2 porque cumple el requisito de comunicacion indirecta y
asincrona, permite desacoplar productor y workers, y nos da metricas de backlog
para el autoscaler. SQS se uso solo como DLQ para fallos definitivos.
```

## EC2 para PostgreSQL en vez de RDS

Usamos PostgreSQL en EC2 porque el enunciado pide PostgreSQL o MySQL en una VM EC2.

Alternativas:

```text
Amazon RDS PostgreSQL
DynamoDB
base de datos local
Aurora
```

Por que no usamos RDS/Aurora:

```text
el enunciado especificaba PostgreSQL/MySQL en EC2
RDS puede tener mas coste o restricciones en AWS Academy
EC2 con Docker era suficiente y controlable
```

Por que no usamos DynamoDB:

```text
el modelo de consistencia y transacciones seria distinto
el enunciado pedia PostgreSQL/MySQL
queriamos constraints SQL, UNIQUE, CHECK y transacciones ACID claras
```

Por que PostgreSQL era adecuado:

```text
transacciones ACID
row-level locking
UPDATE condicional
UNIQUE sobre request_id
UNIQUE sobre seat_id
CHECK sold_count <= total_tickets
consultas SQL para metricas y percentiles
```

Justificacion defendible:

```text
PostgreSQL es la fuente de verdad porque la venta de tickets necesita
consistencia fuerte. La cola puede redeliverar mensajes, pero PostgreSQL evita
overselling mediante transacciones, locks y constraints.
```

## PostgreSQL en vez de MySQL

MySQL tambien habria sido valido, pero elegimos PostgreSQL por comodidad y expresividad.

Motivos:

```text
soporte claro de transacciones ACID
percentile_cont para calcular p50/p95/p99 directamente en SQL
constraints y tipos robustos
buena integracion con psycopg en Python
```

Justificacion defendible:

```text
PostgreSQL facilito tanto la correccion bajo concurrencia como la medicion
experimental. Las ventas y las metricas salen de la misma fuente de verdad.
```

## ECS Fargate para workers en vez de Lambda

El enunciado permitia usar Lambda o Fargate para workers stateless. Elegimos Fargate.

Alternativa:

```text
AWS Lambda como worker
```

Por que Fargate encaja mejor:

```text
RabbitMQ usa conexiones AMQP persistentes
un worker puede mantenerse consumiendo de la cola con basic_consume
controlamos desired_count directamente
podemos medir capacidad por worker de forma clara
encaja con el modelo de workers permanentes y escalables
evita adaptar RabbitMQ a invocaciones Lambda
```

Problemas que tendriamos con Lambda:

```text
Lambda funciona mejor con eventos gestionados como SQS, API Gateway o EventBridge
RabbitMQ externo en EC2 no dispara Lambda de forma tan directa en este diseno
las conexiones AMQP persistentes no encajan tan naturalmente con ejecuciones efimeras
la concurrencia Lambda seria otra metrica distinta a desired_count de ECS
la demostracion visual de workers subiendo/bajando seria menos directa
```

Ventaja de Lambda que aceptamos perder:

```text
scale-to-zero mas natural
menos gestion de contenedores
facturacion muy granular
```

Justificacion defendible:

```text
Elegimos Fargate porque nuestros workers son consumidores AMQP de larga vida.
Cada task mantiene conexion con RabbitMQ, procesa mensajes con ack manual y ECS
permite escalar horizontalmente cambiando desired_count. Lambda era posible, pero
habria obligado a adaptar el patron de consumo y habria hecho menos directa la
demostracion del numero de workers.
```

## ECS Service para workers

Los workers se ejecutan como ECS Service, no como tasks sueltas.

Motivo:

```text
deben estar vivos continuamente
si una task falla, ECS puede reemplazarla
el autoscaler puede modificar desired_count
permite ver desired/running/pending en ECS
```

Justificacion defendible:

```text
Un worker no es un job puntual; es un consumidor permanente de cola. Por eso se
modela como ECS Service.
```

## ECS task one-shot para loadgen en vez de service

El loadgen se ejecuta como task temporal.

Alternativa:

```text
dejar el loadgen como ECS Service permanente
ejecutarlo desde el portatil
```

Por que no es service:

```text
solo se necesita durante un experimento
si quedara vivo gastaria Fargate sin necesidad
su ciclo de vida es publicar carga y terminar
```

Por que no dejarlo local:

```text
la red del portatil puede sesgar la tasa de publicacion
los relojes local/AWS pueden generar metricas inconsistentes
desde Fargate usa IP privada hacia RabbitMQ/PostgreSQL
representa mejor una carga dentro de AWS
```

Justificacion defendible:

```text
El loadgen es una task one-shot porque no forma parte permanente del sistema de
venta. Se ejecuta dentro de AWS para que la medicion no dependa de la red local.
```

## ECS Service para scaler

El scaler se ejecuta como ECS Service porque debe estar vivo durante toda la prueba de elasticidad.

Motivo:

```text
consulta RabbitMQ cada pocos segundos
calcula el numero de workers
llama ECS UpdateService
si falla, ECS puede reiniciarlo
```

Alternativa:

```text
script local que escale desde el portatil
CloudWatch alarms + Application Auto Scaling
```

Por que no script local:

```text
dependeria del portatil durante la prueba
seria menos cloud-native
el profesor veria menos claro que el autoscaling vive dentro del sistema
```

Por que no CloudWatch alarms:

```text
RabbitMQ en EC2 no publica directamente nuestras metricas custom necesarias
queriamos aplicar explicitamente las formulas del enunciado
el scaler propio permite loguear lambda, backlog, by_lambda y by_backlog
```

Justificacion defendible:

```text
Implementamos un scaler propio para demostrar claramente las formulas del
enunciado. CloudWatch/ECS muestran no solo que se escala, sino por que se toma
cada decision.
```

## Docker

Usamos Docker para empaquetar worker, loadgen y scaler.

Motivos:

```text
misma imagen en local y en Fargate
dependencias aisladas
despliegue reproducible
ECS/Fargate ejecuta contenedores
```

Justificacion defendible:

```text
Docker evita depender de configuraciones manuales en la maquina de ejecucion.
Cada componente se empaqueta con sus librerias y se publica en ECR.
```

## ECR

Usamos ECR como registry Docker privado en AWS.

Alternativas:

```text
Docker Hub
GitHub Container Registry
imagenes locales
```

Por que ECR:

```text
integracion directa con ECS/Fargate
misma cuenta y region AWS
autenticacion con AWS CLI/LabRole
evita depender de servicios externos
```

Justificacion defendible:

```text
ECR es el lugar natural para almacenar las imagenes que ECS/Fargate debe ejecutar.
```

## SQS DLQ en vez de usar solo RabbitMQ

Usamos SQS como Dead Letter Queue, no como cola principal.

Alternativa:

```text
usar una cola DLQ dentro de RabbitMQ
descartar mensajes fallidos
usar SQS como cola principal
```

Por que SQS DLQ:

```text
el enunciado pedia SQS DLQ
separa fallos definitivos del flujo normal de RabbitMQ
permite inspeccionar mensajes corruptos o agotados
evita bloquear la cola principal con poison messages
```

Justificacion defendible:

```text
RabbitMQ gestiona el flujo normal de compras. SQS DLQ conserva evidencia de
fallos definitivos para auditoria y depuracion.
```

## CloudWatch Logs

Usamos CloudWatch Logs para observabilidad.

Motivos:

```text
ECS/Fargate envia stdout/stderr a CloudWatch
podemos ver logs de workers, scaler y loadgen
podemos usar Logs Insights
permite ensenar decisiones del autoscaler en la entrevista
```

Limitacion:

```text
no son metricas custom completas
algunas graficas requieren parsear logs o usar CSV locales
```

Justificacion defendible:

```text
CloudWatch nos permite observar el sistema real: workers procesando, scaler
tomando decisiones y loadgen publicando carga.
```

## Python

Usamos Python para worker, loadgen y scaler.

Alternativas:

```text
Java
Node.js
Go
```

Por que Python:

```text
implementacion rapida
librerias maduras para RabbitMQ, PostgreSQL y AWS
pika para AMQP
psycopg para PostgreSQL
boto3 para AWS
requests para RabbitMQ Management API
pandas/matplotlib para analisis
```

Justificacion defendible:

```text
Python nos permitio centrarnos en la arquitectura distribuida y en las metricas,
sin invertir demasiado tiempo en boilerplate.
```

## PowerShell

Usamos PowerShell para scripts operativos porque el entorno de desarrollo era Windows.

Los scripts automatizan:

```text
cargar credenciales AWS Academy
terraform apply/destroy
docker build/push
run-loadgen en ECS
limpieza de RabbitMQ/PostgreSQL/SQS
recogida de resultados
monitorizacion de scaling
```

Justificacion defendible:

```text
PowerShell era la opcion mas practica para automatizar el flujo completo desde
Windows sin depender de comandos manuales repetitivos.
```

## Pandas y Matplotlib

Usamos Pandas y Matplotlib para procesar CSV y generar graficas.

Motivos:

```text
leer CSV exportados desde PostgreSQL
calcular comparativas
generar throughput vs workers
generar latencias p50/p95/p99
generar backlog vs workers
generar comparaciones baseline/autoscaling
```

Justificacion defendible:

```text
Las graficas del informe salen de datos reales exportados del sistema, no de
mediciones inventadas ni solo de tiempos del cliente.
```

## Por que no usamos HTTP/REST como camino principal de compra

Una alternativa comun seria:

```text
cliente -> API REST -> servicio de ventas -> base de datos
```

No lo elegimos como camino principal porque el enunciado exige procesamiento asincrono con cola.

RabbitMQ aporta:

```text
desacoplamiento temporal
backlog observable
suavizado de picos
workers escalables
at-least-once delivery
```

Justificacion defendible:

```text
REST seria adecuado para una API publica, pero la practica queria estudiar
comunicacion indirecta y elasticidad basada en cola. Por eso el camino principal
usa RabbitMQ.
```

## Por que no usamos arquitectura totalmente serverless

Una alternativa seria:

```text
API Gateway + Lambda + SQS + DynamoDB
```

No la elegimos porque:

```text
el enunciado pedia RabbitMQ en EC2
el enunciado pedia PostgreSQL/MySQL en EC2
queriamos demostrar workers stateless con Fargate
queriamos consistencia SQL fuerte y transacciones visibles
```

Justificacion defendible:

```text
Una solucion serverless completa seria interesante, pero se alejaria de los
requisitos concretos de la practica. Nuestra arquitectura cumple explicitamente
RabbitMQ en EC2, PostgreSQL en EC2 y workers stateless.
```

## Trade-offs principales

### Consistencia vs escalabilidad

Elegimos consistencia fuerte en PostgreSQL.

Ventaja:

```text
no overselling
idempotencia robusta
resultados de negocio correctos
```

Coste:

```text
PostgreSQL puede convertirse en cuello de botella
las transacciones anaden latencia
hay contencion en hotspot
```

### Fargate vs Lambda

Fargate:

```text
mejor para consumidores AMQP persistentes
desired_count visible y controlable
mas facil de demostrar en ECS
```

Lambda:

```text
mejor scale-to-zero
menos gestion de contenedores
pero peor encaje con RabbitMQ EC2 y consumo continuo AMQP
```

### EC2 vs servicios gestionados

EC2:

```text
cumple el enunciado
mas control
mas barato/controlable en AWS Academy
```

Servicios gestionados:

```text
menos administracion
mejor para produccion
pero mas coste/restricciones y menos alineado con el enunciado
```

## Frase final para defensa

```text
Las herramientas se eligieron para cumplir el enunciado de forma demostrable:
RabbitMQ en EC2 nos da comunicacion asincrona y backlog medible; PostgreSQL en
EC2 nos da consistencia fuerte y transacciones ACID; Fargate nos da workers
stateless escalables; Terraform hace el despliegue reproducible; SQS actua como
DLQ; CloudWatch permite observar decisiones y errores; y Python/PowerShell
automatizan implementacion, pruebas y recogida de resultados.
```
