# Slowking

Slowking reconcilia información de hospitalización y publica la auditoría resultante en New Relic a través de Azure API Management (APIM).

El proyecto tiene dos partes que se ejecutan de forma independiente:

- **Reconciliación SQL:** `beds.usp_ReconcileHospitalization` revisa estancias, camas, traslados y devolutivos de medicamentos. Permite simular las correcciones o confirmarlas y guardar su auditoría.
- **Publicación de eventos:** una Azure Function con Timer Trigger recorre las bases configuradas, reclama registros de auditoría y envía un evento por petición HTTP a APIM.

Este documento describe el código y los scripts incluidos en el repositorio. La Function no ejecuta el procedimiento de reconciliación; este debe invocarse desde un proceso externo, como Azure Elastic Jobs, o desde una sesión SQL.

## Arquitectura

```text
Ejecutor SQL externo / Azure Elastic Jobs
    |
    v
beds.usp_ReconcileHospitalization
    |
    | Ejecución confirmada: auditoría por regla y acción
    v
beds.HospitalizationReconciliationAudit (en cada base de datos)
    |
    | Timer: 0 2/5 * * * *
    v
Azure Function: ProcessHospitalizationAudit
    |-- Recorre SQL_DATABASES de forma secuencial
    |-- Recupera registros con procesamiento vencido
    |-- Reclama hasta 100 registros por base
    |-- Envía cada evento y actualiza su estado
    |
    | POST + Ocp-Apim-Subscription-Key
    v
Azure API Management
    |
    | Integración con el collector de New Relic
    v
Evento: HospitalizationReconciliation
```

La infraestructura de Azure, la programación del ejecutor SQL y las políticas de APIM se administran fuera de este repositorio.

## Tecnologías y dependencias

Las versiones declaradas en `Slowking.csproj` son:

- .NET 8 (`net8.0`) y Azure Functions v4 con modelo Isolated Worker.
- `Microsoft.Azure.Functions.Worker` y `Microsoft.Azure.Functions.Worker.Sdk`: `2.0.0`.
- `Microsoft.Azure.Functions.Worker.Extensions.Timer`: `4.3.1`.
- `Microsoft.EntityFrameworkCore` y su proveedor SQL Server: `9.0.9`.
- `Microsoft.Data.SqlClient`: `6.1.3`.

`package.json` incorpora Azure Functions Core Tools con rango `^4.15.1`; `package-lock.json` fija la versión `4.15.1`. Node.js se utiliza para esa herramienta de desarrollo, mientras que la aplicación se ejecuta en .NET. El paquete fijado de Core Tools declara Node.js `>=22`.

## Estructura del repositorio

```text
Slowking/
|-- .github/
|   `-- workflows/
|       `-- deploy-function-app.yml
|-- Data/
|   `-- HospitalizationDbContext.cs
|-- Entities/
|   `-- HospitalizationReconciliationAudit.cs
|-- Functions/
|   `-- ProcessHospitalizationAudit.cs
|-- Models/
|   `-- HospitalizationAuditEvent.cs
|-- Scripts/
|   |-- Create Table [beds].[HospitalizationReconciliationAudit].sql
|   `-- [beds].[usp_ReconcileHospitalization].sql
|-- Services/
|   `-- HospitalizationAuditService.cs
|-- .gitignore
|-- host.json
|-- package.json
|-- package-lock.json
|-- Program.cs
|-- README.md
`-- Slowking.csproj
```

Responsabilidades principales:

- `Program.cs` configura el host, registra `HospitalizationAuditService` como singleton y agrega `IHttpClientFactory`.
- `ProcessHospitalizationAudit.cs` contiene el timer, el recorrido por bases, la construcción del payload y el manejo de respuestas de APIM.
- `HospitalizationAuditService.cs` construye las conexiones SQL y realiza la reclamación, recuperación y actualización de auditorías.
- `HospitalizationDbContext.cs` define el mapeo de Entity Framework Core a la tabla de auditoría.
- `HospitalizationReconciliationAudit.cs` representa la entidad persistida y `HospitalizationAuditEvent.cs` los datos recuperados para publicar.
- `host.json` habilita el muestreo de Application Insights. La conexión con el recurso de observabilidad debe configurarse en el entorno.

## Reconciliación SQL

### Objetos y preparación

Los scripts incluidos crean la tabla de auditoría, sus índices y el procedimiento de reconciliación. Deben aplicarse en cada base que vaya a participar en el proceso.

El procedimiento depende de estos objetos de negocio existentes:

- `dbo.CHREGESTA`: estancias.
- `dbo.CHCAMASHO`: camas, indicadores y configuración de asignación.
- `dbo.CHTRAMEDC`: cabeceras de traslado de medicamentos.
- `dbo.HCDEVMEDC` y `dbo.HCDEVMEDD`: cabeceras y detalles de devolutivos.
- `dbo.CHREGEGRE`: egresos.
- `dbo.VMedicinesSupplies` y `dbo.HCFISIPRO`: validación de medicamentos pendientes en la unidad funcional de origen.

Orden de preparación:

1. Verificar que el esquema `beds` y los objetos de negocio existan en la base destino.
2. Ejecutar `Scripts/Create Table [beds].[HospitalizationReconciliationAudit].sql`.
3. Ejecutar `Scripts/[beds].[usp_ReconcileHospitalization].sql`.
4. Ejecutar una simulación y revisar el resumen.
5. Configurar por separado el proceso que invocará la reconciliación confirmada.

El script de tabla solo la crea si no existe; no actualiza estructuras existentes. No hay migraciones de Entity Framework Core ni creación automática de la base al iniciar la Function.

### Parámetros y ejecución

El procedimiento recibe:

- `@SoloSimular BIT = 1`: revierte las modificaciones al terminar. Con `0`, confirma las correcciones y después inserta su auditoría en la tabla física.
- `@WildcardStartDate DATE = '19000101'`: inicio del rango que identifica fechas de fin de estancia abiertas.
- `@WildcardEndDate DATE = '19000102'`: fin de ese rango.

Las comparaciones del rango son inclusivas (`>=` y `<=`). Estos parámetros identifican el valor comodín de una estancia abierta; no representan un período de fechas de ingreso que se quiera procesar. Algunas reglas agregan condiciones sobre `REGESTADO`.

Simulación, que también es el comportamiento predeterminado:

```sql
EXEC beds.usp_ReconcileHospitalization
    @SoloSimular = 1;
```

Ejecución con cambios persistentes:

```sql
EXEC beds.usp_ReconcileHospitalization
    @SoloSimular = 0,
    @WildcardStartDate = '19000101',
    @WildcardEndDate = '19000102';
```

Las correcciones se ejecutan dentro de una transacción con `XACT_ABORT ON`. Se solicita un bloqueo exclusivo con `sp_getapplock`, asociado a la transacción, sobre el recurso `beds.usp_ReconcileHospitalization`. El tiempo de espera es cero: si otra ejecución mantiene el bloqueo, se informa el error.

### Reglas implementadas

Las descripciones siguientes corresponden a las condiciones ejecutables del script, incluidas las modificaciones recientes de las reglas 5 y 6.

1. **Asignación de cama con estancia abierta.** Cambia `ESTADCAMA` de `1` (Libre) a `2` (Asignada) cuando existe una estancia cuya fecha final está en el rango comodín. El filtro actual no exige `REGESTADO = 1` ni verifica que exista una única estancia en la cama.

2. **Limpieza de alerta de traslado.** Para una estancia abierta con `REGESTADO = 1`, elimina `CAMTRAMED` cuando no existe un traslado del mismo paciente e ingreso en estado Enviado (`ORDESTADO = '1'`). El valor escrito en la cama es `0`; el texto de `NewValue` de esta regla todavía indica `CAMTRAMED=NULL`.

3. **Activación de alerta de traslado pendiente.** Activa `CAMTRAMED = 1` en las camas relacionadas con un traslado Enviado cuando el paciente e ingreso tienen exactamente dos estancias abiertas y existen estancias abiertas en origen y destino.

4. **Aceptación de traslado materializado.** Cambia `ORDESTADO` de `'1'` a `'2'` cuando queda una sola estancia abierta del paciente e ingreso y ya no existe una estancia abierta en la cama origen. La comprobación adicional de que la estancia restante sea la cama destino está comentada en la versión actual.

5. **Limpieza de alerta de devolución finalizada.** Para una estancia abierta con `REGESTADO = 1` y `CAMDEVMED = 1`, exige que no haya cabeceras pendientes (`DEVESTADO = '1'`), que exista alguna cabecera finalizada (`'2'` o `'3'`) y que los detalles asociados a cabeceras finalizadas no tengan `PROESTADO` o `CANPENDIE` nulos. Limpia `CAMDEVMED = 0`, `BedType = NULL` y `TypeTransfer = NULL`. En esta versión, las condiciones que rechazaban un estado de detalle diferente al de la cabecera o una cantidad pendiente distinta de cero están comentadas; esos valores por sí solos no bloquean esta regla.

6. **Detección de doble estancia elegible.** Evalúa grupos de exactamente dos estancias abiertas del mismo paciente e ingreso, ordenadas por `FECINIEST DESC, ID DESC`. Solo admite `REGESTADO` en `(1, 2)` para ambas. Excluye traslados Enviados entre las dos camas, el escenario con ambas camas en `TypeTransfer = 3` y tipos `BedType` complementarios `1/2`, medicamentos con existencia física pendiente en la unidad funcional de origen y camas actuales abiertas para otro paciente o ingreso. Registra la acción `DETECTADO`; las correcciones se realizan en las reglas 7 y 8. Las comparaciones que exigían fechas de inicio distintas y camas diferentes están comentadas.

7. **Cierre de la estancia anterior.** Para los casos de la regla 6, establece la fecha final de la estancia anterior exactamente en la fecha inicial de la más reciente y deja `REGESTADO = 2`. Limpia `BedType` y `TypeTransfer` de la cama anterior.

8. **Normalización de la estancia vigente.** En los mismos casos, normaliza la estancia más reciente a `FECFINEST = '19000101'` y `REGESTADO = 1` cuando hace falta. Limpia `BedType` y `TypeTransfer` de la cama actual.

9. **Limpieza final de alerta de traslado.** Repite la validación de `CAMTRAMED` después de reconciliar los traslados y la deja en `0` si ya no quedan órdenes Enviadas del paciente e ingreso.

10. **Reconciliación de cabecera de devolutivo.** Para una cabecera pendiente, exige detalles existentes, todos en estados finales `2/3`, con `CANPENDIE = 0` y sin pendientes válidos o inválidos. Actualiza `DEVESTADO` con el estado del primer detalle, ordenado por `DD.Id`.

    **Subregla 10.1:** para los ingresos cuya cabecera se acaba de reconciliar, limpia `CAMDEVMED` de la cama con estancia abierta y `REGESTADO = 1` si ya no hay cantidades pendientes válidas. No activa alertas nuevas. Esta acción también se almacena con `Rule = 10`; se distingue por `RuleDescription` y `Action`.

11. **Cierre de estancias con egreso registrado.** Ordena las estancias abiertas con `REGESTADO = 1` de un ingreso que aparece en `CHREGEGRE`. Cierra cada una con el inicio de la siguiente y la última con `FECEGRESO`; establece `REGESTADO = 2` y libera las camas asociadas que estén asignadas.

12. **Liberación de cama asignada sin estancia abierta.** Si una cama tiene `ESTADCAMA = 2` y no existe una estancia con fecha final en el rango comodín, establece `ESTADCAMA = 1`, `CAMTRAMED = 0`, `CAMDEVMED = 0`, `BedType = NULL` y `TypeTransfer = NULL`.

13. **Conciliación cronológica de más de dos estancias abiertas.** Agrupa por `NUMINGRES` y ordena por `FECINIEST, ID`. Cierra todas salvo la última con la fecha de inicio de la siguiente y `REGESTADO = 2`. Libera las camas cerradas únicamente si no conservan otra estancia abierta con `REGESTADO = 1`. Aunque su descripción menciona ingresos sin egreso, esta regla no consulta `CHREGEGRE` ni filtra inicialmente por `REGESTADO`; se ejecuta después de la regla 11.

### Resultados y auditoría

En el camino exitoso, el procedimiento devuelve un resumen con `InicioEjecucion`, `FinEjecucion`, `SoloSimular`, `ResultadoEjecucion`, `TotalRegistrosAuditoria`, `TotalCambios`, `TotalNoCorregidos` y `TotalDetectados`. Los contadores representan eventos de auditoría, no necesariamente camas o ingresos distintos.

En simulación, las correcciones se revierten y no se insertan auditorías en la tabla física. El camino exitoso devuelve el resumen; no incluye un segundo conjunto con el detalle de la simulación.

En ejecución confirmada, cada evento de auditoría se inserta con:

- `Container = DB_NAME()` y las fechas de creación, inicio y fin de ejecución.
- Número y descripción de regla, acción, identificadores, valores anterior/nuevo y detalle.
- `NewRelicStatus = NULL`, `NewRelicAttempts = 0` y los demás campos de envío en `NULL`.

El bloque de errores revierte la transacción si sigue activa, agrega una auditoría temporal de regla `999` y acción `ERROR`, devuelve el detalle disponible y notifica el error con `RAISERROR`. No persiste esa auditoría de error en la tabla física.

**Límite transaccional actual:** la inserción de auditoría ocurre después del `COMMIT` de las correcciones. Si esa inserción falla, las correcciones ya confirmadas permanecen en la base aunque la llamada termine con error.

## Publicación de auditorías

### Programación y procesamiento por base

La Function `ProcessHospitalizationAudit` utiliza la expresión de seis campos:

```text
0 2/5 * * * *
```

Se activa en el segundo cero de los minutos `02, 07, 12, 17, 22, 27, 32, 37, 42, 47, 52, 57` de cada hora. La expresión está fija en el código; el repositorio no configura explícitamente una zona horaria para el timer.

En cada ejecución:

1. Recorre secuencialmente los nombres de `SQL_DATABASES`, separados por coma. Elimina entradas vacías y espacios alrededor de cada nombre.
2. En cada base, convierte en `ERROR` los registros `PROCESSING` cuya fecha de procesamiento sea anterior a 15 minutos.
3. En una transacción `ReadCommitted`, selecciona hasta 100 auditorías elegibles por `Id`, usando `UPDLOCK`, `READPAST` y `ROWLOCK`.
4. Las marca `PROCESSING`, registra la fecha UTC, borra la respuesta previa e incrementa `NewRelicAttempts`.
5. Recupera los datos mediante `UPDATE ... OUTPUT` y confirma la reclamación antes de iniciar el envío HTTP.
6. Envía cada registro de forma secuencial a APIM. Una respuesta HTTP 2xx permite marcarlo `SENT`; otra respuesta produce `ERROR`.

Se reclama **un solo lote por base y ejecución**. Un error de una base se registra y permite continuar con las siguientes; una cancelación solicitada detiene el procesamiento.

### Estados y reintentos

- `NULL` o `PENDING`: elegible para reclamación.
- `PROCESSING`: reclamado para envío; conserva `NewRelicProcessingAt`.
- `SENT`: APIM devolvió HTTP 2xx y se pudo confirmar el estado en SQL. Se completa `NewRelicSentAt` y se limpia `NewRelicProcessingAt`.
- `ERROR`: envío fallido o procesamiento vencido. Se limpia `NewRelicProcessingAt` y se guarda una respuesta o excepción.

Los registros `ERROR` se reclaman mientras `ISNULL(NewRelicAttempts, 0) < 5`. El contador aumenta al reclamar, no al completar el envío. La recuperación de registros vencidos tampoco omite este límite; con cinco intentos quedan en `ERROR` y requieren revisión operativa. Los estados `NULL` y `PENDING` no tienen una comprobación adicional del contador en la consulta actual.

Las excepciones de envío intentan marcar el registro como `ERROR`. Si SQL tampoco permite actualizarlo, queda disponible para la recuperación por timeout, siempre que tenga fecha de procesamiento y cumpla el límite de intentos.

Las actualizaciones a `SENT` y `ERROR` requieren que el registro todavía esté en `PROCESSING`; de lo contrario, el servicio genera una excepción. Entity Framework Core tiene configurados hasta tres reintentos ante errores SQL transitorios, con demora máxima de cinco segundos entre reintentos.

### Contrato HTTP y evento

La petición utiliza la URL completa de `APIM_HOSPITALIZATION_AUDIT_URL`:

```http
POST <APIM_HOSPITALIZATION_AUDIT_URL>
Content-Type: application/json
Ocp-Apim-Subscription-Key: <APIM_SUBSCRIPTION_KEY>
```

El cuerpo es **un objeto JSON por auditoría**, no un arreglo. Ejemplo con datos ficticios:

```json
{
  "eventType": "HospitalizationReconciliation",
  "container": "BASE_HOSPITALIZACION_A",
  "auditId": 12345,
  "createdAt": "2026-11-09T14:30:00",
  "startExecution": "2026-11-09T14:25:00",
  "endExecution": "2026-11-09T14:29:30",
  "rule": 1,
  "ruleDescription": "Estancia activa con cama en estado Libre",
  "action": "UPDATE_CAMA",
  "identificationNumber": "PACIENTE_EJEMPLO",
  "admissionNumber": "0000000001",
  "bed": 1427,
  "previousBed": 1427,
  "newBed": 1427,
  "originBed": null,
  "destinationBed": null,
  "transferConsecutive": null,
  "previousValue": "1",
  "newValue": "2",
  "detail": "La estancia activa indica que el paciente permanece en la cama."
}
```

El mapeo de campos es:

- `auditId` corresponde a `Id`; `container` toma el nombre de la base que la Function está procesando, aunque el modelo también recupera `Container` de la fila.
- `identificationNumber` corresponde a `IPCODPACI` y `admissionNumber` a `NUMINGRES`.
- `bed`, `previousBed` y `newBed` corresponden a `CODICAMAS`, `CODICAMAS_PREVIOUSLY` y `CODICAMAS_AFTER`.
- `originBed`, `destinationBed` y `transferConsecutive` corresponden a `CODICAORI`, `CODICADES` y `CODCONCEC`.
- Los demás campos transportan las fechas, la regla, la acción y el detalle de auditoría.

**La implementación actual envía el identificador del paciente como `identificationNumber`.** El acceso y la retención en APIM y New Relic deben contemplar este dato.

APIM debe aceptar este contrato y resolver la integración con New Relic, incluida su credencial y cualquier adaptación del cuerpo que requiera el backend. Sus políticas no están incluidas en el repositorio y la Function no configura una clave de New Relic.

`SENT` confirma el éxito HTTP recibido desde APIM y la actualización local; no hay una consulta posterior de confirmación en New Relic. Tampoco hay garantía de entrega exactamente una vez: si APIM acepta el evento y falla la actualización SQL, puede volver a enviarse. La pareja `(container, auditId)` permite rastrear posibles duplicados entre las distintas bases.

## Configuración

### Variables de la aplicación

Configurar estas seis variables tanto en Azure como en desarrollo local:

- `SQL_SERVER`: servidor SQL utilizado por todas las bases; por ejemplo, `tcp:servidor.database.windows.net,1433`.
- `SQL_DATABASES`: nombres de bases separados por coma; por ejemplo, `BASE_HOSPITALIZACION_A,BASE_HOSPITALIZACION_B`.
- `USER_ID`: usuario de autenticación SQL, con acceso a las bases configuradas.
- `PASSWORD`: contraseña de ese usuario.
- `APIM_HOSPITALIZATION_AUDIT_URL`: URL completa del endpoint de publicación.
- `APIM_SUBSCRIPTION_KEY`: clave que se envía en `Ocp-Apim-Subscription-Key`.

El servicio construye una cadena de conexión por base con `SqlConnectionStringBuilder` y timeout de conexión de 30 segundos. **La autenticación implementada es usuario y contraseña SQL**; no lee `SQL_CONNECTION_STRING` ni utiliza Managed Identity para SQL.

El constructor informa errores cuando falta alguna variable requerida o cuando `SQL_DATABASES` no contiene nombres después de dividirla. La comprobación de las demás variables es de presencia, por lo que también deben tener valores válidos.

### Ejemplo de `local.settings.json`

Crear este archivo en la raíz y sustituir los valores de ejemplo:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated",
    "SQL_SERVER": "tcp:servidor.database.windows.net,1433",
    "SQL_DATABASES": "BASE_HOSPITALIZACION_A,BASE_HOSPITALIZACION_B",
    "USER_ID": "usuario_slowking",
    "PASSWORD": "REEMPLAZAR_LOCALMENTE",
    "APIM_HOSPITALIZATION_AUDIT_URL": "https://mi-apim.azure-api.net/hospitalization-reconciliation/events",
    "APIM_SUBSCRIPTION_KEY": "REEMPLAZAR_LOCALMENTE"
  }
}
```

`UseDevelopmentStorage=true` requiere tener Azurite en ejecución; también puede utilizarse una conexión de Storage del entorno de desarrollo. Azurite no está incluido en las dependencias de este proyecto.

`local.settings.json` está excluido por `.gitignore`. En Azure, configurar los valores correspondientes en la Function App, junto con el almacenamiento y la configuración del host que requiera el entorno. Las credenciales deben administrarse fuera del código fuente, mediante la configuración protegida del entorno o referencias a Key Vault.

### Permisos SQL y conectividad

El consumidor accede directamente a la tabla mediante SQL parametrizado y Entity Framework Core. No utiliza procedimientos `usp_ClaimHospitalizationAuditForNewRelic`, `usp_MarkHospitalizationAuditSent` ni `usp_MarkHospitalizationAuditError`.

Un usuario de base ya creado para la Function necesita permisos de lectura y actualización sobre la tabla en **cada base configurada**. Ejemplo:

```sql
GRANT SELECT, UPDATE
ON OBJECT::beds.HospitalizationReconciliationAudit
TO [usuario_slowking];
```

El ejecutor de reconciliación necesita por separado autorización para ejecutar `beds.usp_ReconcileHospitalization` y acceder a sus dependencias según el modelo de permisos de la base. La Function también necesita conectividad de red hacia SQL Server y APIM.

## Desarrollo local

Requisitos:

- .NET SDK 8.
- Azure Functions Core Tools v4. Si se usa la dependencia npm del repositorio, Node.js 22 o superior y npm.
- Una base de desarrollo con los objetos y scripts SQL aplicados.
- Acceso a un endpoint APIM del entorno de desarrollo.
- Azurite en ejecución o una conexión válida de Azure Storage.

Desde la raíz del proyecto, restaurar y compilar:

```powershell
dotnet restore Slowking.csproj
dotnet build Slowking.csproj --configuration Release
```

Si Core Tools está instalado globalmente, iniciar el host:

```powershell
func start
```

Para utilizar la versión fijada en el repositorio:

```powershell
npm ci
npx --no-install func start
```

El timer consume y envía auditorías de las bases indicadas en la configuración local. Utilizar bases y credenciales de desarrollo para esta ejecución.

El repositorio no incluye una suite de pruebas automatizadas. La validación funcional requiere ejecutar la reconciliación en la base de desarrollo y comprobar el recorrido de auditoría hasta APIM/New Relic.

## Despliegue

### GitHub Actions

El flujo `.github/workflows/deploy-function-app.yml` es el mecanismo automatizado incluido. Se ejecuta con un `push` a `main` o manualmente mediante `workflow_dispatch`.

El flujo:

1. Usa un runner `ubuntu-latest` y configura .NET `8.0.x`.
2. Ejecuta `dotnet publish Slowking.csproj --configuration Release --output ./publish`.
3. Elimina archivos de configuración local coincidentes dentro de `publish`.
4. Publica con `Azure/functions-action@v1` en `func-hospitalization-reconciliation-nr`.

Requiere configurar en GitHub:

- Secret `AZURE_FUNCTIONAPP_PUBLISH_PROFILE`: perfil de publicación de la Function App destino.
- Variable `AZURE_FUNCTIONAPP_SKU`: valor del SKU que se pasa a la acción de despliegue.

La concurrencia se agrupa como `deploy-hospitalization-production` con `cancel-in-progress: false`. El workflow no ejecuta pruebas, no aplica los scripts SQL y no crea recursos, políticas APIM ni variables de la aplicación; esos elementos deben estar preparados por separado.

### Publicación manual

Con Azure CLI y Core Tools disponibles, y una cuenta con acceso al recurso:

```powershell
az login
az account show
func azure functionapp publish func-hospitalization-reconciliation-nr
```

La publicación de la Function y la aplicación de los scripts SQL son operaciones independientes.

## Operación y diagnóstico

Los logs incluyen inicio y fin de ejecución, número de bases, auditorías reclamadas por base, identificador de auditoría, código HTTP de APIM, confirmación de estado, excepciones y cancelaciones.

Consultar la cola por estado en cada base:

```sql
SELECT
    COALESCE(NewRelicStatus, 'NULL') AS Estado,
    COUNT_BIG(*) AS Cantidad
FROM beds.HospitalizationReconciliationAudit
GROUP BY NewRelicStatus;
```

Revisar errores recientes, incluidos los que agotaron los reintentos:

```sql
SELECT TOP (100)
    Id,
    Container,
    CreatedAt,
    [Rule],
    [Action],
    NewRelicStatus,
    NewRelicAttempts,
    NewRelicProcessingAt,
    NewRelicResponse
FROM beds.HospitalizationReconciliationAudit
WHERE NewRelicStatus = 'ERROR'
ORDER BY Id DESC;
```

Ejemplos de consulta NRQL, una vez que APIM haya integrado los eventos en New Relic:

```sql
SELECT *
FROM HospitalizationReconciliation
WHERE container = 'BASE_HOSPITALIZACION_A'
SINCE 1 hour ago
```

```sql
SELECT count(*)
FROM HospitalizationReconciliation
FACET container, rule
SINCE 24 hours ago
```

Ante fallos de configuración o conexión, revisar las seis variables requeridas, el acceso a cada base y la red. Ante respuestas no exitosas de APIM, revisar `NewRelicResponse`, la URL, la clave de suscripción y la integración del gateway con el backend. Una base sin registros reclamados puede no tener pendientes elegibles o tener errores que ya alcanzaron cinco intentos.

### Particularidades de la versión actual

- **Tamaño de respuestas:** el DDL y el mapeo EF definen `NewRelicResponse` con 100 caracteres, pero el servicio recorta las respuestas a 4000. Una respuesta que exceda la capacidad real de la columna puede impedir marcar el resultado del envío. El tamaño del esquema y el del código deben alinearse al preparar el entorno.
- **Tamaño de auditoría SQL:** la tabla temporal del procedimiento admite `ReglaDescripcion` de 500 y `Detalle` de 2000 caracteres, mientras que la tabla física admite 255 para ambos. Esta diferencia también debe considerarse al revisar errores de persistencia posteriores al `COMMIT`.
- **Nombre del esquema:** los scripts usan `beds` y el consumidor utiliza `Beds`. En bases con distinción entre mayúsculas y minúsculas se debe alinear el nombre del esquema antes de operar.
- **Clave de auditoría:** EF configura `Id` como clave; el DDL incluido lo declara `IDENTITY`, pero no crea una restricción `PRIMARY KEY`.
- **Fechas:** el procedimiento obtiene las fechas con `GETDATE()` y la Function registra los tiempos de procesamiento y envío con `DateTime.UtcNow`. El payload transporta las fechas SQL sin una conversión explícita de zona horaria.
- **Alcance del despliegue:** el repositorio no contiene infraestructura como código, políticas APIM, aprovisionamiento de New Relic ni configuración de Azure Elastic Jobs.
