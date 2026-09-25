# Slowking

Azure Function encargada de procesar los registros de auditoría generados por el proceso de reconciliación de hospitalización y enviarlos a New Relic mediante Azure API Management.

## Descripción

**Slowking** implementa el proceso de integración entre la base de datos de hospitalización y New Relic.

La solución consulta periódicamente los registros pendientes de la tabla:

```text
dbo.HospitalizationReconciliationAudit
```

Los registros son reclamados por la Azure Function, enviados a través de Azure API Management y finalmente registrados en New Relic como eventos de tipo:

```text
HospitalizationReconciliation
```

La Azure Function utiliza **Managed Identity** para autenticarse contra Azure SQL Database. La credencial de New Relic no se almacena en la Function; permanece administrada por Azure API Management.

## Arquitectura

```text
Azure Elastic Job
        │
        ▼
usp_ReconcileHospitalization
        │
        ▼
HospitalizationReconciliationAudit
        │
        ▼
Azure Function - Slowking
        │
        ├── Claim registros pendientes
        │
        ├── POST /events
        │
        ▼
Azure API Management
        │
        ├── Agrega credenciales de New Relic
        ├── Configura headers
        └── Redirige al endpoint de New Relic
        │
        ▼
New Relic
        │
        ▼
HospitalizationReconciliation
```

## Componentes de Azure

| Componente        | Valor                                          |
| ----------------- | ---------------------------------------------- |
| Function App      | `func-hospitalization-reconciliation-nr`       |
| Proyecto          | `Slowking`                                     |
| Runtime           | .NET 8 Isolated                                |
| Sistema operativo | Linux                                          |
| Hosting           | Flex Consumption                               |
| Base de datos     | `INDIGO049`                                    |
| SQL Server        | `ssindigo.database.windows.net`                |
| API Management    | `apim-vieehrerp-prod-eus2`                     |
| API APIM          | `hospitalization-reconciliation-observability` |
| Endpoint APIM     | `/hospitalization-reconciliation/events`       |
| Evento New Relic  | `HospitalizationReconciliation`                |

## Funcionamiento

La Function se ejecuta mediante un Timer Trigger cada cinco minutos.

Actualmente utiliza la siguiente expresión CRON:

```text
0 2/5 * * * *
```

Esto ejecuta la Function en los minutos:

```text
02
07
12
17
22
27
32
37
42
47
52
57
```

El desplazamiento respecto al proceso de reconciliación permite dar tiempo a que la transacción que genera los registros de auditoría finalice antes de que la Function intente procesarlos.

## Flujo de procesamiento

Cada ejecución realiza las siguientes operaciones:

1. Consulta hasta 100 registros pendientes.
2. Marca los registros como `PROCESSING`.
3. Incrementa el contador de intentos.
4. Envía cada registro a Azure API Management.
5. Si APIM responde correctamente, marca el registro como `SENT`.
6. Si APIM devuelve un error, marca el registro como `ERROR`.
7. Los registros en estado `ERROR` pueden ser reintentados hasta cinco veces.
8. Los registros que permanezcan en `PROCESSING` durante más de 15 minutos son recuperados para permitir un nuevo procesamiento.

## Estados de New Relic

Los registros utilizan el siguiente estado:

| Estado       | Descripción                                    |
| ------------ | ---------------------------------------------- |
| `NULL`       | Registro aún no procesado                      |
| `PENDING`    | Registro pendiente de envío                    |
| `PROCESSING` | Registro actualmente reclamado por la Function |
| `SENT`       | Registro enviado correctamente                 |
| `ERROR`      | Se presentó un error durante el envío          |

El estado se almacena directamente en:

```text
dbo.HospitalizationReconciliationAudit
```

## Stored Procedures

La Function utiliza tres procedimientos almacenados.

### 1. Reclamar registros

```text
dbo.usp_ClaimHospitalizationAuditForNewRelic
```

Responsabilidades:

* Recuperar registros pendientes.
* Seleccionar máximo 100 registros por ejecución.
* Evitar que dos ejecuciones procesen simultáneamente el mismo registro.
* Marcar los registros como `PROCESSING`.
* Incrementar `NewRelicAttempts`.
* Recuperar registros que quedaron en `PROCESSING` durante más de 15 minutos.

La selección utiliza bloqueos:

```sql
UPDLOCK
READPAST
ROWLOCK
```

Esto permite realizar el procesamiento de forma segura ante ejecuciones concurrentes.

### 2. Marcar envío exitoso

```text
dbo.usp_MarkHospitalizationAuditSent
```

Actualiza:

```text
NewRelicStatus = SENT
NewRelicSentAt = SYSUTCDATETIME()
NewRelicProcessingAt = NULL
NewRelicResponse = respuesta de APIM
```

### 3. Marcar error

```text
dbo.usp_MarkHospitalizationAuditError
```

Actualiza:

```text
NewRelicStatus = ERROR
NewRelicProcessingAt = NULL
NewRelicResponse = detalle del error
```

El registro podrá ser procesado nuevamente mientras:

```text
NewRelicAttempts < 5
```

## Columnas utilizadas para New Relic

La tabla de auditoría contiene los siguientes campos relacionados con el procesamiento:

```text
NewRelicStatus
NewRelicProcessingAt
NewRelicSentAt
NewRelicAttempts
NewRelicResponse
```

Ejemplo:

```text
NewRelicStatus        = SENT
NewRelicProcessingAt  = NULL
NewRelicSentAt        = 2026-09-24 14:35:20
NewRelicAttempts      = 1
NewRelicResponse      = HTTP 200 - ...
```

## Payload enviado a New Relic

La Function construye un evento con información de la auditoría.

Ejemplo simplificado:

```json
[
  {
    "eventType": "HospitalizationReconciliation",
    "auditId": 12345,
    "createdAt": "2026-09-24T14:30:00Z",
    "startExecution": "2026-09-24T14:25:00Z",
    "endExecution": "2026-09-24T14:29:30Z",
    "rule": "UPDATE_CAMA",
    "ruleDescription": "Estancia activa con cama en estado Libre",
    "action": "UPDATE_CAMA",
    "admissionNumber": "6025279",
    "bed": "1427",
    "previousBed": null,
    "newBed": null,
    "originBed": null,
    "destinationBed": null,
    "transferConsecutive": null,
    "previousValue": "1",
    "newValue": "2",
    "detail": "Cama actualizada a estado ocupado"
  }
]
```

El código no envía `IPCODPACI` a New Relic.

Esto evita enviar innecesariamente un identificador directo del paciente a una plataforma de observabilidad.

## Identificación del evento

Cada evento incluye:

```text
auditId
```

Este valor corresponde al:

```text
Id
```

de `HospitalizationReconciliationAudit`.

Se utiliza para facilitar la trazabilidad y detectar posibles duplicados.

La arquitectura no pretende garantizar exactamente una entrega **exactly-once**. Por ejemplo, si New Relic recibe correctamente el evento pero la Function falla antes de ejecutar `usp_MarkHospitalizationAuditSent`, el registro podría volver a procesarse.

Por esta razón, `auditId` funciona como identificador de trazabilidad.

## Azure API Management

La Function no se comunica directamente con New Relic.

Utiliza el siguiente endpoint:

```text
POST https://apim-vieehrerp-prod-eus2.azure-api.net/hospitalization-reconciliation/events
```

APIM se encarga de:

* Recibir el evento.
* Agregar la credencial de New Relic.
* Configurar los headers necesarios.
* Redirigir la petición al collector de New Relic.
* Mantener la credencial de New Relic fuera de la Function.

El backend configurado es:

```text
https://insights-collector.newrelic.com
```

La Function nunca debe almacenar el License Key de New Relic.

## Variables de entorno

### Azure

```text
SQL_CONNECTION_STRING
APIM_HOSPITALIZATION_AUDIT_URL
```

Ejemplo:

```text
SQL_CONNECTION_STRING=
Server=tcp:ssindigo.database.windows.net,1433;
Initial Catalog=INDIGO049;
Authentication=Active Directory Managed Identity;
Encrypt=True;
TrustServerCertificate=False;
Connection Timeout=30;
```

```text
APIM_HOSPITALIZATION_AUDIT_URL=
https://apim-vieehrerp-prod-eus2.azure-api.net/hospitalization-reconciliation/events
```

### Desarrollo local

Para desarrollo local se puede utilizar:

```text
Authentication=Active Directory Default;
```

Ejemplo:

```text
Server=tcp:ssindigo.database.windows.net,1433;
Initial Catalog=INDIGO049;
Authentication=Active Directory Default;
Encrypt=True;
TrustServerCertificate=False;
Connection Timeout=30;
```

## Seguridad

La Function utiliza **System Assigned Managed Identity** para conectarse a Azure SQL.

No se deben almacenar:

* Usuario de SQL.
* Contraseña de SQL.
* New Relic License Key.
* Secrets de APIM.

El acceso de la Managed Identity se limita a los procedimientos almacenados requeridos:

```sql
GRANT EXECUTE ON OBJECT::dbo.usp_ClaimHospitalizationAuditForNewRelic
TO [func-hospitalization-reconciliation-nr];

GRANT EXECUTE ON OBJECT::dbo.usp_MarkHospitalizationAuditSent
TO [func-hospitalization-reconciliation-nr];

GRANT EXECUTE ON OBJECT::dbo.usp_MarkHospitalizationAuditError
TO [func-hospitalization-reconciliation-nr];
```

La Function no requiere permisos directos de `SELECT`, `INSERT`, `UPDATE` o `DELETE` sobre la tabla de auditoría.

## Configuración de la base de datos

El usuario de Managed Identity debe existir en la base de datos:

```text
INDIGO049
```

Ejemplo:

```sql
CREATE USER [func-hospitalization-reconciliation-nr]
FROM EXTERNAL PROVIDER;
```

Verificación:

```sql
SELECT
    name,
    type_desc,
    authentication_type_desc
FROM sys.database_principals
WHERE name = 'func-hospitalization-reconciliation-nr';
```

## Desarrollo local

Restaurar las dependencias:

```powershell
dotnet restore
```

Compilar:

```powershell
dotnet build
```

Ejecutar:

```powershell
func start
```

El archivo:

```text
local.settings.json
```

debe contener la configuración necesaria para ejecutar la Function localmente.

Este archivo **no debe subirse al repositorio**.

## Despliegue

El despliegue recomendado se realiza mediante Azure Functions Core Tools.

Iniciar sesión:

```powershell
az login
```

Verificar la suscripción:

```powershell
az account show
```

Verificar Azure Functions Core Tools:

```powershell
func --version
```

Desplegar:

```powershell
func azure functionapp publish func-hospitalization-reconciliation-nr
```

No se recomienda realizar un ZIP manual desde la carpeta fuente.

El paquete generado para Azure Functions debe conservar la estructura requerida por la plataforma.

## Estructura del proyecto

```text
Slowking/
│
├── Functions/
│   └── ProcessHospitalizationAudit.cs
│
├── Models/
│   └── HospitalizationAuditEvent.cs
│
├── Services/
│   └── HospitalizationAuditService.cs
│
├── Program.cs
├── host.json
├── local.settings.json
├── .gitignore
├── Slowking.csproj
└── README.md
```

## Manejo de errores

La Function maneja errores en dos niveles.

### Error de APIM

Si APIM responde con un código diferente de 2xx:

```text
NewRelicStatus = ERROR
```

Se almacena la respuesta:

```text
NewRelicResponse
```

y el registro puede ser reintentado.

### Error durante el procesamiento

Si ocurre una excepción durante la comunicación con SQL o APIM, la Function registra el error en Application Insights y trata de marcar el registro como:

```text
ERROR
```

Si el registro queda en:

```text
PROCESSING
```

y no es finalizado, el procedimiento de reclamación lo recuperará después de 15 minutos.

## Reintentos

Cada registro tiene un contador:

```text
NewRelicAttempts
```

El máximo configurado es:

```text
5 intentos
```

La condición de reintento es:

```sql
NewRelicStatus = 'ERROR'
AND NewRelicAttempts < 5
```

Esto evita que un registro con un error permanente sea enviado indefinidamente.

## Observabilidad

La Function genera logs para:

* Inicio de ejecución.
* Cantidad de registros reclamados.
* Envíos exitosos.
* Respuestas HTTP de APIM.
* Errores de comunicación.
* Errores de SQL.
* Finalización del procesamiento.

La observabilidad de la infraestructura se realiza mediante Application Insights/Azure Monitor, mientras que los eventos funcionales de reconciliación se envían a New Relic.

## Consulta en New Relic

Los eventos pueden consultarse mediante NRQL:

```sql
SELECT *
FROM HospitalizationReconciliation
SINCE 1 hour ago
```

También pueden utilizarse consultas para analizar reglas específicas:

```sql
SELECT count(*)
FROM HospitalizationReconciliation
FACET rule
SINCE 24 hours ago
```

O acciones:

```sql
SELECT count(*)
FROM HospitalizationReconciliation
FACET action
SINCE 24 hours ago
```

## Consideraciones de diseño

La solución mantiene separadas las responsabilidades:

```text
SQL
│
└── Generación y persistencia de auditoría

Azure Function
│
└── Procesamiento y envío

APIM
│
└── Integración y seguridad de New Relic

New Relic
│
└── Observabilidad y análisis
```

Esto permite modificar el mecanismo de observabilidad sin modificar el procedimiento principal de reconciliación.

También evita que la base de datos tenga que realizar llamadas HTTP directamente.

## Principios de seguridad

* No almacenar secretos en código fuente.
* No almacenar el License Key de New Relic en SQL.
* No almacenar el License Key de New Relic en la Function.
* Utilizar Managed Identity para Azure SQL.
* Utilizar APIM como frontera de integración con New Relic.
* No enviar información innecesaria del paciente a New Relic.
* No subir `local.settings.json` al repositorio.
* No subir artefactos de compilación o publicación al repositorio.

## Nombre del proyecto

El nombre oficial del repositorio/proyecto es:

```text
Slowking
```

La Function App de Azure mantiene su nombre operativo:

```text
func-hospitalization-reconciliation-nr
```