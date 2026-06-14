# Hallazgos del probe AWS Academy

Fecha local: 2026-06-07

## Identidad

- Cuenta: `065586234233`.
- Region: `us-east-1`.
- Rol asumido: `arn:aws:sts::065586234233:assumed-role/voclabs/user5144451=jfuentes`.
- Tipo de laboratorio indicado: `ALLv2ES-LA-LTI13-158976`.
- Sesion: aproximadamente 4 horas.
- Budget: 50 USD.

## Estado local PyCharm

- AWS CLI disponible.
- CDK disponible usando `cdk.cmd`.
- NPM disponible usando `npm.cmd`.
- Node disponible.
- Docker disponible.
- Git disponible.
- Las credenciales locales funcionan al cargarlas desde `tools/aws/set-academy-env.ps1`.

## Servicios visibles con permisos read-only

Servicios consultados correctamente:

- STS.
- CloudFormation.
- S3 list.
- IAM list roles.
- EC2 describe VPCs, subnets, security groups, instances.
- ECS list clusters.
- ECS list account settings.
- ECR describe repositories/images.
- Lambda list functions.
- SQS list queues.
- CloudWatch list metrics.
- CloudWatch logs describe log groups.

## Red disponible

- Existe VPC default: `vpc-0b379683405b06ceb`.
- CIDR: `172.31.0.0/16`.
- Hay subnets default publicas en varias AZs.
- Las subnets tienen `MapPublicIpOnLaunch = true`.
- Existe security group default: `sg-08d96e8b362c055b6`.

Implicacion:

- Podemos disenar inicialmente sobre la VPC default para reducir complejidad de AWS Academy.
- Evitaremos NAT Gateway salvo que sea estrictamente necesario, porque consume presupuesto.

## Recursos activos detectados

No se detectaron:

- Instancias EC2 activas.
- Clusters ECS activos.
- Colas SQS activas.
- Load balancers activos.
- Volumenes EBS sueltos en estado `available`.

Si esto sigue igual, no hay compute activo consumiendo presupuesto de forma relevante.

## Recursos residuales detectados

Existe repositorio ECR:

- Nombre: `ticket-worker`.
- URI: `065586234233.dkr.ecr.us-east-1.amazonaws.com/ticket-worker`.
- Contiene varias imagenes.
- Imagen principal aproximada: 66.7 MB.

Implicacion:

- ECR no ejecuta compute, pero almacena imagenes.
- El coste deberia ser bajo, pero conviene limpiarlo cuando decidamos rehacer desde cero.
- No se ha borrado nada durante el probe.

## CloudFormation

Stacks observados:

- Stack de AWS Academy: `c201082a5133234l15433453t1w065586234233`, estado `CREATE_COMPLETE`.
- Stack `TicketSystemStack`, dos ejecuciones previas, estado `DELETE_COMPLETE`.
- Stack `CDKToolkit`, una ejecucion previa `DELETE_COMPLETE` y otra en `ROLLBACK_COMPLETE`.

## CDK bootstrap

El stack `CDKToolkit` quedo en `ROLLBACK_COMPLETE`.

Recursos implicados en el fallo/rollback:

- `ImagePublishingRole`.
- `FilePublishingRole`.
- `LookupRole`.
- `CloudFormationExecutionRole`.
- `StagingBucket`.
- `ContainerAssetsRepository`.
- `CdkBootstrapVersion`.

Los eventos muestran rollback de bootstrap estandar de CDK. No aparece todavia un `AccessDenied` claro en la salida revisada, pero el patron es compatible con limitaciones de AWS Academy sobre bootstrap moderno, especialmente por creacion de roles IAM administrados por CDK y bucket de assets.

Implicacion:

- No debemos asumir que `cdk bootstrap` estandar funcionara.
- La ruta mas segura es probar CDK con bootstrap adaptado o despliegue sin assets pesados.
- Para Fargate con imagen Docker, necesitaremos una estrategia concreta para ECR/assets.

## Prueba minima CDK realizada

Se creo una app CDK minima en `infra/cdk` con una sola cola SQS.

Resultado de `cdk synth`:

- Correcto.
- Con `DefaultStackSynthesizer`, la plantilla incluia dependencia de `/cdk-bootstrap/hnb659fds/version`.
- Con `BootstraplessSynthesizer`, desaparecia el parametro de bootstrap, pero CDK seguia intentando usar roles de bootstrap durante deploy.
- Con `CliCredentialsStackSynthesizer`, desaparecian los roles, pero aparecia dependencia del bucket `cdk-hnb659fds-assets-065586234233-us-east-1`.
- Con `LegacyStackSynthesizer`, el manifest quedo limpio: sin roles de bootstrap, sin bucket de assets y sin parametro de bootstrap.

Resultado de deploy minimo:

- `cdk deploy AcademyCdkSmokeTestStack --require-approval never` funciono correctamente usando `LegacyStackSynthesizer`.
- CloudFormation creo una cola SQS temporal.
- Output generado: URL de la cola SQS temporal.
- `cdk destroy AcademyCdkSmokeTestStack --force` elimino correctamente la pila.

Verificacion posterior:

- `aws cloudformation describe-stacks --stack-name AcademyCdkSmokeTestStack` devuelve que el stack no existe.
- `aws sqs list-queues` no devuelve colas.

Conclusion:

- CDK puede usarse desde PyCharm/local contra AWS Academy.
- No se debe usar `cdk bootstrap` estandar.
- Para stacks sin assets, se debe usar `LegacyStackSynthesizer`.
- Para stacks con Docker/Fargate habra que evitar asset publishing automatico de CDK o usar ECR gestionado explicitamente.

## Prueba minima EC2 realizada

Se creo un segundo stack CDK en `infra/cdk`:

- Stack: `AcademyEc2SmokeTestStack`.
- Recurso principal: una instancia EC2 `t2.micro`.
- AMI: Amazon Linux 2023 desde parametro publico de SSM.
- Red: VPC default `vpc-0b379683405b06ceb`.
- Subnet: `subnet-032d3177811825ce8`.
- Security group: sin reglas de entrada, solo egress a Internet.
- Volumen: 8 GB `gp3`, `DeleteOnTermination = true`.
- Sin key pair.
- Sin IAM instance profile.

Resultado:

- `cdk synth AcademyEc2SmokeTestStack` funciono.
- `cdk diff AcademyEc2SmokeTestStack` mostro solo `AWS::EC2::SecurityGroup` y `AWS::EC2::Instance`.
- `cdk deploy AcademyEc2SmokeTestStack --require-approval never` funciono.
- Instancia temporal creada: `i-0ea12dc21a87715bd`.
- `cdk destroy AcademyEc2SmokeTestStack --force` funciono.

Verificacion posterior:

- El stack `AcademyEc2SmokeTestStack` ya no existe.
- No hay instancias con tag `academy-ec2-smoke-test` en estados activos.
- No hay volumenes EBS sueltos en estado `available`.
- No hay security groups con tag `academy-ec2-smoke-test`.

Conclusion:

- AWS Academy permite crear y destruir EC2 mediante CDK sin bootstrap estandar.
- Esto valida la base necesaria para RabbitMQ en EC2 y PostgreSQL/MySQL en EC2.
- El enfoque CDK sigue siendo viable para la practica definitiva.

## ECS/Fargate

ECS responde correctamente.

Configuracion observada:

- `fargateVCPULimit = enabled`.
- `containerInsights = disabled`.
- No hay clusters activos.

Implicacion:

- ECS/Fargate parece visible en la cuenta.
- Aun falta confirmar creacion real de cluster/service/task con una prueba controlada.

## Lambda

Lambda responde correctamente y hay funciones de la infraestructura del laboratorio.

Implicacion:

- Lambda existe en la cuenta.
- No se ha probado creacion de Lambdas propias.

## SQS

SQS responde, pero no hay colas listadas.

Implicacion:

- SQS parece disponible para DLQ.
- Falta confirmar creacion con CDK o CloudFormation.

## Riesgos principales

- Bootstrap estandar de CDK no es fiable en este laboratorio.
- Usar Fargate con imagen Docker exige ECR y roles; puede ser el punto de mayor friccion.
- Crear VPC/NAT/Load Balancer puede consumir presupuesto y permisos; se debe evitar salvo necesidad.
- La practica debe usar EC2 para RabbitMQ y PostgreSQL/MySQL, por lo que hay que probar EC2 con instancias pequenas y apagarlas/destruirlas rapidamente.

## Recomendacion tecnica

Siguiente prueba, todavia pequena y controlada:

1. No usar `cdk bootstrap` estandar.
2. Usar `LegacyStackSynthesizer` para stacks CDK que no requieran assets.
3. Para contenedores, crear o reutilizar ECR explicitamente y referenciar imagenes ya subidas, evitando que CDK publique assets Docker.
4. Mantener todos los despliegues con `cdk deploy` y `cdk destroy` controlados.
5. Para RabbitMQ y PostgreSQL, usar EC2 pequenas y security groups estrictos.
6. Mantener Terraform como plan B si ECS/Fargate o ECR presentan bloqueos fuertes.

## Limpieza pendiente

Posibles recursos a limpiar mas adelante:

- ECR repository `ticket-worker` y sus imagenes, si no se reutiliza.
- Stack `CDKToolkit` en `ROLLBACK_COMPLETE`, si estorba a futuros bootstrap.

No se debe borrar nada sin decision explicita, porque podria servir para diagnostico.
