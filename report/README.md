# Report Artifacts

Esta carpeta contiene los datos y graficas usados para el informe final.

## Estructura

- `results/`: CSV reales exportados desde PostgreSQL y monitorizacion RabbitMQ/ECS.
- `loadgen_runs/`: JSON de trazabilidad de las ejecuciones del load generator en ECS Fargate.
- `figures/`: graficas generadas a partir de `results/`.
- `generate_figures.py`: graficas principales del informe.
- `generate_figures_max32.py`: graficas adicionales de autoscaling max32.
- `generate_completion_comparison.py`: comparativa de tiempo de finalizacion max1/max8/max32.

## Regenerar graficas

Crear un virtualenv local e instalar dependencias:

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r app\loadgen\requirements.txt -r report\requirements.txt
```

Ejecutar:

```powershell
.\.venv\Scripts\python.exe report\generate_figures.py
.\.venv\Scripts\python.exe report\generate_figures_max32.py
.\.venv\Scripts\python.exe report\generate_completion_comparison.py
```
