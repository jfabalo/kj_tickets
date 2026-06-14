# main.tf
#
# Objetivo del archivo:
#   Obtener datos ya existentes en AWS Academy: cuenta, region, default VPC y
#   subnets. El resto de archivos reutiliza estos datos para no crear una red
#   completa desde cero.
#
# Por que default VPC:
#   AWS Academy/Learner Lab suele traer una VPC por defecto lista para EC2/ECS.
#   Usarla reduce coste, complejidad y tiempo de despliegue.

# Identidad de la cuenta AWS actual. Se usa en outputs y para trazabilidad.
data "aws_caller_identity" "current" {}

# Region efectiva del provider AWS. Permite exponerla por output sin duplicarla.
data "aws_region" "current" {}

# Busca la VPC marcada como default en la cuenta/region actual.
data "aws_vpc" "default" {
  # true significa: dame la VPC por defecto de esta region.
  default = true
}

# Lista todas las subnets que pertenecen a la default VPC.
data "aws_subnets" "default" {
  # Filtro AWS: solo subnets cuyo vpc-id coincide con la default VPC anterior.
  filter {
    # Nombre del atributo AWS por el que filtramos.
    name = "vpc-id"
    # Valor esperado: id real de la default VPC encontrada.
    values = [data.aws_vpc.default.id]
  }
}
