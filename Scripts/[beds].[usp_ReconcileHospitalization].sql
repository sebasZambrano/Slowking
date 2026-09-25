/****** Object:  StoredProcedure [beds].[usp_ReconcileHospitalization]    Script Date: 21/9/2026 10:09:47 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/* ============================================================================
PROCEDURE: beds.usp_ReconcileHospitalization

DESCRIPCIÓN:
----------------------------------------------------------------------------
Procedimiento almacenado encargado de ejecutar procesos automáticos de
reconciliación sobre la información de hospitalización, estancias, camas,
traslados de medicamentos y devolutivos.

Su objetivo es identificar inconsistencias de información que puedan
generar bloqueos operativos en el aplicativo y realizar, cuando las
condiciones lo permiten, las correcciones correspondientes de forma
controlada y trazable.

El procedimiento aplica un criterio conservador de reconciliación. Solo
realiza modificaciones cuando existe suficiente información para determinar
de forma segura el estado esperado. Los escenarios que corresponden a un
comportamiento operativo válido no son considerados inconsistencias y no
generan modificaciones ni registros de auditoría.

REGLAS IMPLEMENTADAS:
----------------------------------------------------------------------------
    REGLA 1  - RECONCILIACIÓN DE CAMA CON ESTANCIA ACTIVA

              Identifica camas que tienen una estancia activa
              asociada, pero cuyo estado no corresponde a
              "Asignada" (ESTADCAMA <> 2).

              Cuando existe una única estancia activa asociada,
              la cama se actualiza a estado Asignada
              (ESTADCAMA = 2).


   REGLA 2  - LIMPIEZA DE ALERTA DE TRASLADO SIN TRASLADO PENDIENTE

              Identifica camas con CAMTRAMED = 1 cuando no existe
              un traslado de medicamentos asociado en estado
              Enviado (ORDESTADO = '1').

              Se elimina la alerta estableciendo CAMTRAMED = 0.


   REGLA 3  - ACTIVACIÓN DE ALERTA POR TRASLADO PENDIENTE

              Identifica traslados de medicamentos en estado
              Enviado (ORDESTADO = '1') asociados a exactamente
              dos estancias abiertas del mismo paciente e ingreso.

              Cuando existen las estancias correspondientes a la
              cama origen y la cama destino, se activa CAMTRAMED
              en ambas camas para indicar que existe un traslado
              pendiente de materialización.


   REGLA 4  - CIERRE DE TRASLADO DE MEDICAMENTOS MATERIALIZADO

              Identifica traslados de medicamentos que permanecen
              en estado Enviado cuando el paciente ya no mantiene
              una estancia abierta en la cama origen y solamente
              existe una estancia activa asociada al ingreso.

              En este escenario, el traslado se considera
              materializado y ORDESTADO se actualiza de Enviado
              (1) a Aceptado (2).


   REGLA 5  - LIMPIEZA DE ALERTA DE DEVOLUCIÓN FINALIZADA

              Identifica camas con CAMDEVMED = 1 cuando no existen
              devoluciones pendientes y existe al menos una
              devolución finalizada.

              Además, valida que los detalles de devolución no
              presenten cantidades pendientes ni inconsistencias.

              Cuando se cumplen estas condiciones, se elimina la
              alerta estableciendo CAMDEVMED = 0.


   REGLA 6  - DETECCIÓN DE DOBLE ESTANCIA ACTIVA

              Identifica exactamente dos estancias abiertas para
              el mismo paciente e ingreso.

              Determina cuál corresponde a la estancia actual y
              cuál a la estancia anterior, tomando como referencia
              la fecha de inicio de la estancia.

              Se excluyen los escenarios que corresponden a
              traslados de medicamentos pendientes o transferencias
              de cama consideradas válidas.

              Esta regla únicamente detecta y evalúa el caso.
              El cierre de la estancia anterior se realiza en la
              REGLA 7.


   REGLA 7  - CIERRE DE ESTANCIA ANTERIOR POR DOBLE ESTANCIA

              Procesa los casos identificados por la REGLA 6.

              La estancia anterior se cierra utilizando como
              fecha final exactamente la fecha de inicio de la
              estancia más reciente.

              Además, la estancia anterior pasa a estado cerrado
              (REGESTADO = 2).


   REGLA 8  - NORMALIZACIÓN DE LA ESTANCIA VIGENTE

              Procesa la estancia más reciente identificada en
              un escenario de doble estancia.

              La estancia vigente queda normalizada como activa,
              estableciendo:

                  FECFINEST = 1900-01-01
                  REGESTADO = 1

              De esta forma, la estancia más reciente queda como
              la única estancia vigente del ingreso después de la
              reconciliación.


   REGLA 9  - LIMPIEZA FINAL DE ALERTA DE TRASLADO

              Realiza una segunda validación de CAMTRAMED después
              de ejecutar las reglas de reconciliación de traslados.

              Esta validación es necesaria porque la REGLA 4 puede
              cambiar un traslado de Enviado a Aceptado durante la
              misma ejecución.

              Si después de las reconciliaciones ya no existe un
              traslado Enviado, se elimina CAMTRAMED estableciendo
              su valor en 0.


   REGLA 10 - RECONCILIACIÓN DE CABECERA DE DEVOLUTIVO

              Identifica devolutivos cuya cabecera permanece en
              estado Pendiente (DEVESTADO = '1'), pero cuyos
              detalles ya no contienen cantidades pendientes
              válidas.

              Se valida que existan detalles, que no haya
              cantidades pendientes válidas o inconsistentes y
              que los detalles se encuentren en estados finales.

              Cuando se cumplen las condiciones, la cabecera del
              devolutivo se actualiza utilizando el estado final
              correspondiente de sus detalles.


   REGLA 10.1 - LIMPIEZA DE ALERTA DE DEVOLUTIVO EN CAMA

                Después de reconciliar la cabecera del devolutivo,
                valida nuevamente si existen cantidades pendientes
                válidas asociadas a la cama.

                Si ya no existen pendientes válidos, se elimina
                CAMDEVMED estableciendo su valor en 0.

                Esta regla únicamente elimina la alerta cuando la
                devolución ya fue finalizada. No activa CAMDEVMED
                para nuevos devolutivos pendientes.


   REGLA 11 - CIERRE DE ESTANCIA ACTIVA CON EGRESO REGISTRADO

              Identifica estancias que permanecen abiertas o
              activas en CHREGESTA cuando el ingreso ya cuenta
              con un egreso registrado en CHREGEGRE.

              La estancia se cierra utilizando la fecha real de
              egreso (FECEGRESO).

              Se actualiza:

                  FECFINEST = FECEGRESO
                  REGESTADO = 2

              Adicionalmente, si la cama asociada se encuentra
              ocupada (ESTADCAMA = 2), se libera estableciendo:

                  ESTADCAMA = 1


   REGLA 12 - LIBERACIÓN DE CAMA ASIGNADA SIN ESTANCIA ACTIVA

              Identifica camas que permanecen en estado Asignada
              (ESTADCAMA = 2), pero que no tienen una estancia
              abierta asociada en CHREGESTA.

              Esta situación representa una inconsistencia, ya
              que la cama aparece asignada en el aplicativo sin
              tener una estancia activa asociada.

              Para corregir la inconsistencia, la cama se libera
              y se limpian las configuraciones relacionadas con
              su asignación:

                  ESTADCAMA    = 1
                  CAMTRAMED    = 0
                  CAMDEVMED    = 0
                  BedType      = NULL
                  TypeTransfer = NULL

              De esta forma, la cama queda disponible para una
              nueva asignación y no conserva indicadores o
              configuraciones asociadas a una asignación anterior.

TRANSACCIONALIDAD:
----------------------------------------------------------------------------
Las operaciones de reconciliación se ejecutan dentro de una transacción,
permitiendo mantener la consistencia de la información durante el proceso.

Cuando @SoloSimular = 1, las modificaciones realizadas durante la ejecución
son revertidas al finalizar el proceso, permitiendo validar el
comportamiento del procedimiento sin afectar permanentemente los datos.


CONCURRENCIA:
----------------------------------------------------------------------------
Se utiliza sp_getapplock para controlar la ejecución concurrente del
procedimiento y evitar que múltiples ejecuciones simultáneas intenten
reconciliar los mismos registros.


PARÁMETRO:
----------------------------------------------------------------------------
    @SoloSimular = 1
        Ejecuta las validaciones y simula las correcciones sin conservar
        las modificaciones realizadas sobre la base de datos.

    @SoloSimular = 0
        Ejecuta las validaciones y confirma las correcciones permitidas.

ALCANCE:
----------------------------------------------------------------------------
El procedimiento contempla la reconciliación de información relacionada
con:

    - Estancias de hospitalización.
    - Estados de camas.
    - Traslados de medicamentos.
    - Devolutivos de medicamentos.
    - Indicadores asociados a camas.
    - Escenarios de doble estancia.
    - Casos que requieren revisión manual.

Las reglas implementadas buscan reducir bloqueos operativos derivados de
inconsistencias de información, manteniendo como prioridad la integridad
y trazabilidad de los datos.


AUTOR:
----------------------------------------------------------------------------
Johan Sebastian Zambrano Polanco - Senior Tech Service Engineer

============================================================================ */


CREATE OR ALTER PROCEDURE [beds].[usp_ReconcileHospitalization]
(
    @SoloSimular BIT = 1,
    @DateAt DATE = '20260101'

)
AS
BEGIN

    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ============================================================
       VARIABLES GENERALES
    ============================================================ */

    DECLARE @InicioEjecucion DATETIME;
    DECLARE @FinEjecucion DATETIME;
    DECLARE @FechaAuditoria DATETIME;

    DECLARE @LockResult INT;

    SET @InicioEjecucion = GETDATE();
    SET @FechaAuditoria = GETDATE();


    /* ============================================================
       VALIDACION PARAMETRO
    ============================================================ */

    IF @SoloSimular NOT IN (0, 1)
    BEGIN
        RAISERROR(
            '@SoloSimular solamente puede ser 0 o 1.',
            16,
            1
        );

        RETURN;
    END;

    IF @DateAt IS NULL
    BEGIN
        RAISERROR(
            '@DateAt no puede ser NULL.',
            16,
            1
        );

        RETURN;
    END;


    /* ============================================================
       AUDITORIA

       Las TABLE VARIABLES permiten conservar los resultados
       de auditoria incluso cuando la transaccion haga ROLLBACK.
    ============================================================ */

    DECLARE @Auditoria TABLE
    (
        IdAuditoria INT IDENTITY(1,1),

        Fecha DATETIME NOT NULL,

        Regla INT NOT NULL,

        ReglaDescripcion VARCHAR(500) NOT NULL,

        Accion VARCHAR(50) NOT NULL,

        IPCODPACI VARCHAR(25) NULL,

        NUMINGRES CHAR(10) NULL,

        CODICAMAS INT NULL,

        CODICAMAS_ANTERIOR INT NULL,

        CODICAMAS_NUEVA INT NULL,

        CODICAORI INT NULL,

        CODICADES INT NULL,

        CODCONCEC INT NULL,

        ValorAnterior VARCHAR(200) NULL,

        ValorNuevo VARCHAR(200) NULL,

        Detalle VARCHAR(2000) NULL
    );


    /* ============================================================
       TABLA DE TRABAJO - CAMAS
    ============================================================ */

    DECLARE @TrabajoCamas TABLE
    (
        IPCODPACI VARCHAR(25) NULL,

        NUMINGRES CHAR(10) NULL,

        CODICAMAS INT NOT NULL,

        EstadoAnterior INT NULL,

        EstadoNuevo INT NULL,

        CAMTRAMED_Anterior BIT NULL,

        CAMTRAMED_Nuevo BIT NULL,

        CAMDEVMED_Anterior BIT NULL,

        CAMDEVMED_Nuevo BIT NULL
    );


    /* ============================================================
       TABLA DE TRABAJO - TRASLADOS
    ============================================================ */

    DECLARE @TrabajoTraslados TABLE
    (
        CODCONCEC INT NOT NULL,

        IPCODPACI VARCHAR(25) NOT NULL,

        NUMINGRES CHAR(10) NOT NULL,

        CODICAORI INT NULL,

        CODICADES INT NULL,

        EstadoAnterior CHAR(1) NULL,

        EstadoNuevo CHAR(1) NULL
    );


    /* ============================================================
       TABLA DE TRABAJO - DOBLE ESTANCIA

       La estancia mas reciente se considera candidata a quedar
       activa.

       Old = estancia anterior
       Current = estancia mas reciente
    ============================================================ */

    DECLARE @DobleEstancia TABLE
    (
        IPCODPACI VARCHAR(25) NOT NULL,

        NUMINGRES CHAR(10) NOT NULL,

        OldID INT NOT NULL,

        OldCama INT NOT NULL,

        OldFechaInicio DATETIME NOT NULL,

        OldFechaFin DATETIME NOT NULL,

        OldRegEstado INT NOT NULL,

        CurrentID INT NOT NULL,

        CurrentCama INT NOT NULL,

        CurrentFechaInicio DATETIME NOT NULL,

        CurrentFechaFin DATETIME NOT NULL,

        CurrentRegEstado INT NOT NULL
    );


    /* ============================================================
       TABLA DE TRABAJO - ESTANCIAS
    ============================================================ */

    DECLARE @TrabajoEstancias TABLE
    (
        ID INT NOT NULL,

        IPCODPACI VARCHAR(25) NOT NULL,

        NUMINGRES CHAR(10) NOT NULL,

        CODICAMAS INT NOT NULL,

        FechaAnterior DATETIME NULL,

        FechaNueva DATETIME NULL,

        RegEstadoAnterior INT NULL,

        RegEstadoNuevo INT NULL
    );


    /* ============================================================
       TABLA DE TRABAJO - DEVOLUTIVOS
    ============================================================ */

    DECLARE @TrabajoDevolutivos TABLE
    (
        CODCONCEC INT NOT NULL,
        IPCODPACI VARCHAR(25) NOT NULL,
        NUMINGRES CHAR(10) NOT NULL,
        EstadoAnterior CHAR(1) NOT NULL,
        EstadoNuevo CHAR(1) NOT NULL
    );

    /* ============================================================
       TABLA DE TRABAJO - EGRESOS
    ============================================================ */

    DECLARE @TrabajoEgresos TABLE
    (
        ID INT,
        IPCODPACI VARCHAR(50),
        NUMINGRES VARCHAR(50),
        CODICAMAS VARCHAR(50),
        FechaAnterior DATETIME,
        FechaNueva DATETIME,
        FechaEgreso DATETIME,
        EstadoCamaAnterior VARCHAR(10),
        OrdenEstancia INT
    );

    /* ============================================================
       TABLA DE TRABAJO - CAMAS ASIGNADAS SIN ESTANCIA
    ============================================================ */

    DECLARE @TrabajoCamasSinEstancia TABLE
    (
        CODICAMAS VARCHAR(50),
        DESCCAMAS VARCHAR(50),
        UFUCODIGO VARCHAR(25),
        CODCENATE VARCHAR(25),
        ESTADCAMA VARCHAR(10),
        CAMTRAMED BIT NULL,
        CAMDEVMED BIT NULL,
        CODCONCEC INT NULL,
        BedType INT NULL,
        TypeTransfer INT NULL
    );

    BEGIN TRY

        /* ========================================================
           TRANSACCION
        ======================================================== */

        BEGIN TRANSACTION;


        /* ========================================================
           LOCK GLOBAL DEL PROCESO

           Impide dos ejecuciones simultaneas del procedimiento.
        ======================================================== */

        EXEC @LockResult = sp_getapplock
            @Resource = 'beds.usp_ReconcileHospitalization',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 0;


        IF @LockResult < 0
        BEGIN

            RAISERROR(
                'No fue posible obtener el bloqueo de reconciliacion. Existe otra ejecucion activa.',
                16,
                1
            );

            ROLLBACK TRANSACTION;

            RETURN;

        END;


        /* ========================================================
           ========================================================
           REGLA 1
           ========================================================

           Paciente con estancia activa:

               FECFINEST = 1900-01-01
               REGESTADO = 1

           Y cama:

               ESTADCAMA = 1

           Se corrige:

               ESTADCAMA = 2

           SOLO cuando la cama tiene una unica estancia activa.
        ======================================================== */

        DELETE FROM @TrabajoCamas;


        INSERT INTO @TrabajoCamas
        (
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            EstadoAnterior,
            EstadoNuevo
        )
        SELECT
            E.IPCODPACI,
            E.NUMINGRES,
            E.CODICAMAS,
            C.ESTADCAMA,
            2
        FROM dbo.CHREGESTA E
        INNER JOIN dbo.CHCAMASHO C
            ON C.CODICAMAS = E.CODICAMAS
        WHERE
            E.FECFINEST >= '1900-01-01 00:00:00.000' AND E.FECFINEST <= '1900-01-01 23:59:59.000'
             AND E.FECINIEST >= @DateAt
            AND C.ESTADCAMA = 1
            AND
            (
                SELECT COUNT(1)
                FROM dbo.CHREGESTA E2
                WHERE E2.CODICAMAS = E.CODICAMAS
                AND E2.FECFINEST >= '1900-01-01 00:00:00.000' AND E2.FECFINEST <= '1900-01-01 23:59:59.000'
                 AND E2.FECINIEST >= @DateAt
            ) = 1;


        UPDATE C
        SET C.ESTADCAMA = 2
        FROM dbo.CHCAMASHO C
        INNER JOIN @TrabajoCamas T
            ON T.CODICAMAS = C.CODICAMAS;


        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            CODICAMAS_ANTERIOR,
            CODICAMAS_NUEVA,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            1,
            'Estancia activa con cama en estado Libre',
            'UPDATE_CAMA',
            T.IPCODPACI,
            T.NUMINGRES,
            T.CODICAMAS,
            T.CODICAMAS,
            T.CODICAMAS,
            CONVERT(VARCHAR(50), T.EstadoAnterior),
            '2',
            'La estancia activa indica que el paciente permanece en la cama.'
        FROM @TrabajoCamas T;


        /* ========================================================
           REGLA 2
           ========================================================

           CAMTRAMED = 1

           pero no existe traslado pendiente:

               ORDESTADO = '1'

           Se limpia:

               CAMTRAMED = 0
        ======================================================== */

        DELETE FROM @TrabajoCamas;


        INSERT INTO @TrabajoCamas
        (
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            CAMTRAMED_Anterior,
            CAMTRAMED_Nuevo
        )
        SELECT DISTINCT
            E.IPCODPACI,
            E.NUMINGRES,
            C.CODICAMAS,
            C.CAMTRAMED,
            NULL
        FROM dbo.CHCAMASHO C
        INNER JOIN dbo.CHREGESTA E
            ON E.CODICAMAS = C.CODICAMAS
        WHERE E.FECFINEST >= '1900-01-01 00:00:00.000' AND E.FECFINEST <= '1900-01-01 23:59:59.000'
          AND E.FECINIEST >= @DateAt
          AND E.REGESTADO = 1
          AND C.CAMTRAMED = 1
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.CHTRAMEDC T
              WHERE T.IPCODPACI = E.IPCODPACI
                AND T.NUMINGRES = E.NUMINGRES
                AND T.ORDESTADO = '1'
          );


        UPDATE C
        SET C.CAMTRAMED = 0
        FROM dbo.CHCAMASHO C
        INNER JOIN @TrabajoCamas T
            ON T.CODICAMAS = C.CODICAMAS;


        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            2,
            'Cama con alerta de traslado pero sin traslado pendiente',
            'UPDATE_CAMA',
            T.IPCODPACI,
            T.NUMINGRES,
            T.CODICAMAS,
            'CAMTRAMED=1',
            'CAMTRAMED=NULL',
            'No existe CHTRAMEDC en estado Enviado.'
        FROM @TrabajoCamas T;


        /* ========================================================
           REGLA 3
           ========================================================

           Existe:

               ORDESTADO = '1'

           Y existen exactamente dos estancias activas.

           Las dos camas relacionadas con:

               CODICAORI
               CODICADES

           deben tener:

               CAMTRAMED = 1

           Esta regla representa un traslado pendiente real.
        ======================================================== */

        DELETE FROM @TrabajoCamas;


        INSERT INTO @TrabajoCamas
        (
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            CAMTRAMED_Anterior,
            CAMTRAMED_Nuevo
        )
        SELECT DISTINCT
            E.IPCODPACI,
            E.NUMINGRES,
            C.CODICAMAS,
            C.CAMTRAMED,
            1
        FROM dbo.CHTRAMEDC T
        INNER JOIN dbo.CHREGESTA E
            ON E.IPCODPACI = T.IPCODPACI
           AND E.NUMINGRES = T.NUMINGRES
           AND E.CODICAMAS IN
           (
               T.CODICAORI,
               T.CODICADES
           )
        INNER JOIN dbo.CHCAMASHO C
            ON C.CODICAMAS = E.CODICAMAS
        WHERE T.ORDESTADO = '1'

          /* EXACTAMENTE DOS ESTANCIAS ABIERTAS */
          AND
          (
              SELECT COUNT(1)
              FROM dbo.CHREGESTA E2
              WHERE E2.IPCODPACI = T.IPCODPACI
                AND E2.NUMINGRES = T.NUMINGRES
                AND E2.FECINIEST >= @DateAt
                AND E2.FECFINEST >= '1900-01-01 00:00:00.000' AND E2.FECFINEST <= '1900-01-01 23:59:59.000'
          ) = 2

          /* EXISTE ESTANCIA EN CAMA ORIGEN */
          AND EXISTS
          (
              SELECT 1
              FROM dbo.CHREGESTA EO
              WHERE EO.IPCODPACI = T.IPCODPACI
                AND EO.NUMINGRES = T.NUMINGRES
                AND EO.CODICAMAS = T.CODICAORI
                AND EO.FECINIEST >= @DateAt
                AND EO.FECFINEST >= '1900-01-01 00:00:00.000' AND EO.FECFINEST <= '1900-01-01 23:59:59.000'
          )

          /* EXISTE ESTANCIA EN CAMA DESTINO */
          AND EXISTS
          (
              SELECT 1
              FROM dbo.CHREGESTA ED
              WHERE ED.IPCODPACI = T.IPCODPACI
                AND ED.NUMINGRES = T.NUMINGRES
                AND ED.CODICAMAS = T.CODICADES
                AND ED.FECINIEST >= @DateAt
                AND ED.FECFINEST >= '1900-01-01 00:00:00.000' AND ED.FECFINEST <= '1900-01-01 23:59:59.000'
          )

          AND ISNULL(C.CAMTRAMED, 0) <> 1;


        UPDATE C
        SET C.CAMTRAMED = 1
        FROM dbo.CHCAMASHO C
        INNER JOIN @TrabajoCamas T
            ON T.CODICAMAS = C.CODICAMAS;


        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            3,
            'Traslado de medicamentos Enviado con doble estancia activa',
            'UPDATE_CAMA',
            T.IPCODPACI,
            T.NUMINGRES,
            T.CODICAMAS,
            CASE
                WHEN T.CAMTRAMED_Anterior IS NULL THEN 'NULL'
                ELSE CONVERT(VARCHAR(10), T.CAMTRAMED_Anterior)
            END,
            '1',
            'La cama origen y la cama destino mantienen alerta de traslado pendiente.'
        FROM @TrabajoCamas T;


        /* ========================================================
           REGLA 4
           ========================================================

           Traslado Enviado pero ya solo existe UNA estancia activa.

           Se considera que el traslado de cama ya se materializo
           en CHREGESTA y la orden quedo pegada.

           Validacion adicional:

               La estancia activa debe estar en CODICADES.

           Entonces:

               ORDESTADO = '2'
        ======================================================== */

        DELETE FROM @TrabajoTraslados;


        INSERT INTO @TrabajoTraslados
        (
            CODCONCEC,
            IPCODPACI,
            NUMINGRES,
            CODICAORI,
            CODICADES,
            EstadoAnterior,
            EstadoNuevo
        )
        SELECT
            T.CODCONCEC,
            T.IPCODPACI,
            T.NUMINGRES,
            T.CODICAORI,
            T.CODICADES,
            T.ORDESTADO,
            '2'
        FROM dbo.CHTRAMEDC T
        WHERE T.ORDESTADO = '1'

          /* SOLO UNA ESTANCIA ABIERTA */
          AND
          (
              SELECT COUNT(1)
              FROM dbo.CHREGESTA E
              WHERE E.IPCODPACI = T.IPCODPACI
                AND E.NUMINGRES = T.NUMINGRES
                AND E.FECINIEST >= @DateAt
                AND E.FECFINEST >= '1900-01-01 00:00:00.000' AND E.FECFINEST <= '1900-01-01 23:59:59.000'
          ) = 1

          /* LA ESTANCIA ACTUAL ES LA DESTINO */
          --AND EXISTS
          --(
          --    SELECT 1
          --    FROM dbo.CHREGESTA E
          --    WHERE E.IPCODPACI = T.IPCODPACI
          --      AND E.NUMINGRES = T.NUMINGRES
          --      AND E.CODICAMAS = T.CODICADES
          --      AND E.FECFINEST = CONVERT(DATETIME, '19000101', 112)
          --)

          /* NO EXISTE ESTANCIA ACTIVA EN ORIGEN */
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.CHREGESTA E
              WHERE E.IPCODPACI = T.IPCODPACI
                AND E.NUMINGRES = T.NUMINGRES
                AND E.CODICAMAS = T.CODICAORI
                AND E.FECINIEST >= @DateAt
                AND E.FECFINEST >= '1900-01-01 00:00:00.000' AND E.FECFINEST <= '1900-01-01 23:59:59.000'
          );


        UPDATE T
        SET T.ORDESTADO = '2'
        FROM dbo.CHTRAMEDC T
        INNER JOIN @TrabajoTraslados W
            ON W.CODCONCEC = T.CODCONCEC;


        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            CODICAORI,
            CODICADES,
            CODCONCEC,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            4,
            'Traslado de medicamentos pegado despues de materializarse el traslado',
            'UPDATE_TRASLADO',
            W.IPCODPACI,
            W.NUMINGRES,
            W.CODICADES,
            W.CODICAORI,
            W.CODICADES,
            W.CODCONCEC,
            '1 - Enviado',
            '2 - Aceptado',
            'Existe una sola estancia activa y esta corresponde a la cama destino.'
        FROM @TrabajoTraslados W;


        /* ========================================================
           REGLA 5
           ========================================================

           CAMDEVMED = 1

           No existe devolucion pendiente.

           Adicionalmente:

               DEVESTADO 2/3
               PROESTADO coincide
               CANPENDIE = 0

           Entonces:

               CAMDEVMED = 0
        ======================================================== */

        DELETE FROM @TrabajoCamas;


        INSERT INTO @TrabajoCamas
        (
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            CAMDEVMED_Anterior,
            CAMDEVMED_Nuevo
        )
        SELECT DISTINCT
            E.IPCODPACI,
            E.NUMINGRES,
            C.CODICAMAS,
            C.CAMDEVMED,
            0
        FROM dbo.CHCAMASHO C
        INNER JOIN dbo.CHREGESTA E
            ON E.CODICAMAS = C.CODICAMAS
        WHERE 
          E.FECFINEST >= '1900-01-01 00:00:00.000' AND E.FECFINEST <= '1900-01-01 23:59:59.000'
          AND E.FECINIEST >= @DateAt
          AND E.REGESTADO = 1
          AND C.CAMDEVMED = 1

          /* NO HAY DEVOLUCION PENDIENTE */
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.HCDEVMEDC D
              WHERE D.IPCODPACI = E.IPCODPACI
                AND D.NUMINGRES = E.NUMINGRES
                AND D.DEVESTADO = '1'
          )

          /* EXISTE DEVOLUCION CERRADA */
          AND EXISTS
          (
              SELECT 1
              FROM dbo.HCDEVMEDC D
              WHERE D.IPCODPACI = E.IPCODPACI
                AND D.NUMINGRES = E.NUMINGRES
                AND D.DEVESTADO IN ('2','3')
          )

          /* NO EXISTEN DETALLES INCONSISTENTES */
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.HCDEVMEDC D
              INNER JOIN dbo.HCDEVMEDD DD
                  ON DD.CODCONCEC = D.CODCONCEC
                 AND DD.IPCODPACI = D.IPCODPACI
                 AND DD.NUMINGRES = D.NUMINGRES
              WHERE D.IPCODPACI = E.IPCODPACI
                AND D.NUMINGRES = E.NUMINGRES
                AND D.DEVESTADO IN ('2','3')
                AND
                (
                    DD.PROESTADO IS NULL
                    OR DD.PROESTADO <> D.DEVESTADO
                    OR DD.CANPENDIE IS NULL
                    OR DD.CANPENDIE <> 0
                )
          );


        UPDATE C
        SET C.CAMDEVMED = 0
        FROM dbo.CHCAMASHO C
        INNER JOIN @TrabajoCamas T
            ON T.CODICAMAS = C.CODICAMAS;


        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            5,
            'Devolucion finalizada sin alerta pendiente en cama',
            'UPDATE_CAMA',
            T.IPCODPACI,
            T.NUMINGRES,
            T.CODICAMAS,
            'CAMDEVMED=1',
            'CAMDEVMED=0',
            'Las devoluciones no pendientes tienen detalle consistente y CANPENDIE=0.'
        FROM @TrabajoCamas T;


        /* ========================================================
           REGLA 6
           ========================================================

           DETECCION DE DOBLE ESTANCIA.

           Se consideran las estancias abiertas sin importar
           REGESTADO.

           Solo se procesan automaticamente grupos EXACTAMENTE
           de dos estancias.

           Si existe traslado pendiente, NO se corrige.
        ======================================================== */

        DELETE FROM @DobleEstancia;


        ;WITH Activas AS
        (
            SELECT
                E.ID,
                E.IPCODPACI,
                E.NUMINGRES,
                E.CODICAMAS,
                E.FECINIEST,
                E.FECFINEST,
                E.REGESTADO,

                ROW_NUMBER() OVER
                (
                    PARTITION BY E.IPCODPACI, E.NUMINGRES
                    ORDER BY
                        E.FECINIEST DESC,
                        E.ID DESC
                ) AS RN,

                COUNT(1) OVER
                (
                    PARTITION BY E.IPCODPACI, E.NUMINGRES
                ) AS Cantidad

            FROM dbo.CHREGESTA E
            WHERE 
                E.FECFINEST >= '1900-01-01 00:00:00.000' AND E.FECFINEST <= '1900-01-01 23:59:59.000'
                AND E.FECINIEST >= @DateAt
        ),
        DosEstancias AS
        (
            SELECT
                A1.IPCODPACI,
                A1.NUMINGRES,

                A2.ID AS OldID,
                A2.CODICAMAS AS OldCama,
                A2.FECINIEST AS OldFechaInicio,
                A2.FECFINEST AS OldFechaFin,
                A2.REGESTADO AS OldRegEstado,

                A1.ID AS CurrentID,
                A1.CODICAMAS AS CurrentCama,
                A1.FECINIEST AS CurrentFechaInicio,
                A1.FECFINEST AS CurrentFechaFin,
                A1.REGESTADO AS CurrentRegEstado

            FROM Activas A1
            INNER JOIN Activas A2
                ON A2.IPCODPACI = A1.IPCODPACI
               AND A2.NUMINGRES = A1.NUMINGRES
               AND A1.RN = 1
               AND A2.RN = 2

            WHERE A1.Cantidad = 2
              AND A2.Cantidad = 2
              AND A1.FECINIEST > A2.FECINIEST

              /* No debe ser la misma cama */
              --AND A1.CODICAMAS <> A2.CODICAMAS

              /*
                 VALIDACION OPERATIVA:
                 Si existe un traslado de medicamentos pendiente que
                 relaciona exactamente las dos camas, la doble estancia
                 es esperada y NO se debe reconciliar.
              */
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.CHTRAMEDC T
                  WHERE T.IPCODPACI = A1.IPCODPACI
                    AND T.NUMINGRES = A1.NUMINGRES
                    AND T.ORDESTADO = '1'
                    AND
                    (
                        (T.CODICAORI = A2.CODICAMAS AND T.CODICADES = A1.CODICAMAS)
                        OR
                        (T.CODICAORI = A1.CODICAMAS AND T.CODICADES = A2.CODICAMAS)
                    )
              )

              /*
                 VALIDACION OPERATIVA:
                 TypeTransfer=3 con una cama BedType=1 y otra BedType=2
                 representa el escenario de medicamentos identificado
                 en QA. Es una doble estancia esperada y NO se reconcilia.
              */
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.CHCAMASHO CB1
                  INNER JOIN dbo.CHCAMASHO CB2
                      ON CB2.CODICAMAS = A2.CODICAMAS
                  WHERE CB1.CODICAMAS = A1.CODICAMAS
                    AND CB1.TypeTransfer = 3
                    AND CB2.TypeTransfer = 3
                    AND
                    (
                        (CB1.BedType = 1 AND CB2.BedType = 2)
                        OR
                        (CB1.BedType = 2 AND CB2.BedType = 1)
                    )
              )

              /* La cama actual no puede estar ocupada por
                 otro paciente activo */
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.CHREGESTA EO
                  WHERE EO.CODICAMAS = A1.CODICAMAS
                    AND EO.FECINIEST >= @DateAt
                    AND EO.FECFINEST >= '1900-01-01 00:00:00.000' AND EO.FECFINEST <= '1900-01-01 23:59:59.000'
                    AND
                    (
                        EO.IPCODPACI <> A1.IPCODPACI
                        OR EO.NUMINGRES <> A1.NUMINGRES
                    )
              )

              /* La estancia antigua debe poder cerrarse.
                 No tocamos registros ya liquidados. */
              AND A2.REGESTADO IN (1,2)

              /* La estancia que quedara activa debe poder
                 normalizarse sin reactivar una liquidada. */
              AND A1.REGESTADO IN (1,2)
        )
        INSERT INTO @DobleEstancia
        (
            IPCODPACI,
            NUMINGRES,
            OldID,
            OldCama,
            OldFechaInicio,
            OldFechaFin,
            OldRegEstado,
            CurrentID,
            CurrentCama,
            CurrentFechaInicio,
            CurrentFechaFin,
            CurrentRegEstado
        )
        SELECT
            IPCODPACI,
            NUMINGRES,
            OldID,
            OldCama,
            OldFechaInicio,
            OldFechaFin,
            OldRegEstado,
            CurrentID,
            CurrentCama,
            CurrentFechaInicio,
            CurrentFechaFin,
            CurrentRegEstado
        FROM DosEstancias;


        /* Auditoria de deteccion */
        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            6,
            'Doble estancia activa elegible para reconciliacion',
            'DETECTADO',
            D.IPCODPACI,
            D.NUMINGRES,
            D.CurrentCama,
            'Estancia anterior ID='
            + CONVERT(VARCHAR(20), D.OldID)
            + ', cama='
            + CONVERT(VARCHAR(20), D.OldCama)
            + ', inicio='
            + CONVERT(VARCHAR(23), D.OldFechaInicio, 121)
            + '. Estancia actual ID='
            + CONVERT(VARCHAR(20), D.CurrentID)
            + ', cama='
            + CONVERT(VARCHAR(20), D.CurrentCama)
            + ', inicio='
            + CONVERT(VARCHAR(23), D.CurrentFechaInicio, 121)
        FROM @DobleEstancia D;


        /* ========================================================
           REGLA 7
           ========================================================

           Cierre de la estancia anterior.

           Ejemplo:

           07:12 -> 1900
           10:10 -> 1900

           Se transforma en:

           07:12 -> 10:10
           10:10 -> 1900
        ======================================================== */

        DELETE FROM @TrabajoEstancias;


        INSERT INTO @TrabajoEstancias
        (
            ID,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            FechaAnterior,
            FechaNueva,
            RegEstadoAnterior,
            RegEstadoNuevo
        )
        SELECT
            D.OldID,
            D.IPCODPACI,
            D.NUMINGRES,
            D.OldCama,
            D.OldFechaFin,
            D.CurrentFechaInicio,
            D.OldRegEstado,
            CASE
                WHEN D.OldRegEstado IN (1,2)
                    THEN 2
                ELSE D.OldRegEstado
            END
        FROM @DobleEstancia D;


        UPDATE E
        SET
            E.FECFINEST = T.FechaNueva,
            E.REGESTADO = T.RegEstadoNuevo
        FROM dbo.CHREGESTA E
        INNER JOIN @TrabajoEstancias T
            ON T.ID = E.ID;


        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            7,
            'Cierre de estancia anterior por doble estancia',
            'UPDATE_ESTANCIA',
            T.IPCODPACI,
            T.NUMINGRES,
            T.CODICAMAS,
            CONVERT(VARCHAR(23), T.FechaAnterior, 121)
            + ' / REGESTADO='
            + CONVERT(VARCHAR(10), T.RegEstadoAnterior),
            CONVERT(VARCHAR(23), T.FechaNueva, 121)
            + ' / REGESTADO='
            + CONVERT(VARCHAR(10), T.RegEstadoNuevo),
            'La fecha final de la estancia anterior pasa a ser exactamente la fecha inicial de la estancia siguiente.'
        FROM @TrabajoEstancias T;


        /* ========================================================
           REGLA 8
           ========================================================

           La estancia actual queda:

               FECFINEST = 1900-01-01
               REGESTADO = 1
        ======================================================== */

        DELETE FROM @TrabajoEstancias;


        INSERT INTO @TrabajoEstancias
        (
            ID,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            FechaAnterior,
            FechaNueva,
            RegEstadoAnterior,
            RegEstadoNuevo
        )
        SELECT
            E.ID,
            E.IPCODPACI,
            E.NUMINGRES,
            E.CODICAMAS,
            E.FECFINEST,
            CONVERT(DATETIME, '19000101', 112),
            E.REGESTADO,
            1
        FROM dbo.CHREGESTA E
        INNER JOIN @DobleEstancia D
            ON D.CurrentID = E.ID
        WHERE
            E.FECFINEST <>
                CONVERT(DATETIME, '19000101', 112)
            OR E.REGESTADO <> 1;


        UPDATE E
        SET
            E.FECFINEST = T.FechaNueva,
            E.REGESTADO = T.RegEstadoNuevo
        FROM dbo.CHREGESTA E
        INNER JOIN @TrabajoEstancias T
            ON T.ID = E.ID;


        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            8,
            'Normalizacion de estancia vigente',
            'UPDATE_ESTANCIA',
            T.IPCODPACI,
            T.NUMINGRES,
            T.CODICAMAS,
            'FECFINEST='
            + CONVERT(VARCHAR(23), T.FechaAnterior, 121)
            + ' / REGESTADO='
            + CONVERT(VARCHAR(10), T.RegEstadoAnterior),
            'FECFINEST=1900-01-01 / REGESTADO=1',
            'La estancia mas reciente queda como estancia activa.'
        FROM @TrabajoEstancias T;


        /* ========================================================
           REGLA 9
           ========================================================

           Limpieza final de CAMTRAMED.

           Esta regla es necesaria porque la REGLA 4 pudo cambiar
           ORDESTADO de 1 a 2 durante esta misma ejecucion.

           Por lo tanto la REGLA 2 no pudo haberla detectado
           anteriormente.
        ======================================================== */

        DELETE FROM @TrabajoCamas;


        INSERT INTO @TrabajoCamas
        (
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            CAMTRAMED_Anterior,
            CAMTRAMED_Nuevo
        )
        SELECT DISTINCT
            E.IPCODPACI,
            E.NUMINGRES,
            C.CODICAMAS,
            C.CAMTRAMED,
            NULL
        FROM dbo.CHCAMASHO C
        INNER JOIN dbo.CHREGESTA E
            ON E.CODICAMAS = C.CODICAMAS
        WHERE E.FECFINEST >= '1900-01-01 00:00:00.000' AND E.FECFINEST <= '1900-01-01 23:59:59.000'
          AND E.FECINIEST >= @DateAt
          AND E.REGESTADO = 1
          AND C.CAMTRAMED = 1
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.CHTRAMEDC T
              WHERE T.IPCODPACI = E.IPCODPACI
                AND T.NUMINGRES = E.NUMINGRES
                AND T.ORDESTADO = '1'
          );


        UPDATE C
        SET C.CAMTRAMED = 0
        FROM dbo.CHCAMASHO C
        INNER JOIN @TrabajoCamas T
            ON T.CODICAMAS = C.CODICAMAS;


        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            9,
            'Limpieza final de alerta de traslado',
            'UPDATE_CAMA',
            T.IPCODPACI,
            T.NUMINGRES,
            T.CODICAMAS,
            'CAMTRAMED=1',
            'CAMTRAMED=0',
            'Despues de reconciliar los traslados ya no existe una orden Enviada.'
        FROM @TrabajoCamas T;


        /* ========================================================
           REGLA 10 - CABECERA DE DEVOLUTIVO PENDIENTE SIN DETALLES PENDIENTES
           ========================================================

           Si DEVESTADO=1 pero ninguno de sus detalles tiene
           cantidades pendientes validas, la cabecera se reconcilia
           con el estado de su primer detalle.

           Solo se procesa cuando todos los detalles se encuentran
           en estados finales 2 o 3 y CANPENDIE=0.
        ======================================================== */

        DELETE FROM @TrabajoDevolutivos;

        INSERT INTO @TrabajoDevolutivos
        (
            CODCONCEC,
            IPCODPACI,
            NUMINGRES,
            EstadoAnterior,
            EstadoNuevo
        )
        SELECT
            D.CODCONCEC,
            D.IPCODPACI,
            D.NUMINGRES,
            D.DEVESTADO,
            CONVERT(CHAR(1), F.PROESTADO)
        FROM dbo.HCDEVMEDC D
        CROSS APPLY
        (
            SELECT TOP (1)
                DD.PROESTADO
            FROM dbo.HCDEVMEDD DD
            WHERE DD.CODCONCEC = D.CODCONCEC
              AND DD.IPCODPACI = D.IPCODPACI
              AND DD.NUMINGRES = D.NUMINGRES
            ORDER BY DD.Id
        ) F
        WHERE D.DEVESTADO = '1'
          AND EXISTS
          (
              SELECT 1
              FROM dbo.HCDEVMEDD DD
              WHERE DD.CODCONCEC = D.CODCONCEC
                AND DD.IPCODPACI = D.IPCODPACI
                AND DD.NUMINGRES = D.NUMINGRES
          )
          AND NOT EXISTS
          (
              /* No existe detalle pendiente valido. */
              SELECT 1
              FROM dbo.HCDEVMEDD DD
              WHERE DD.CODCONCEC = D.CODCONCEC
                AND DD.IPCODPACI = D.IPCODPACI
                AND DD.NUMINGRES = D.NUMINGRES
                AND DD.PROESTADO = '1'
                AND DD.CANPENDIE IS NOT NULL
                AND DD.CANDEVOLV IS NOT NULL
                AND DD.CANPENDIE > 0
                AND DD.CANPENDIE <= DD.CANDEVOLV
          )
          AND NOT EXISTS
          (
              /* No existen detalles pendientes con cantidades invalidas. */
              SELECT 1
              FROM dbo.HCDEVMEDD DD
              WHERE DD.CODCONCEC = D.CODCONCEC
                AND DD.IPCODPACI = D.IPCODPACI
                AND DD.NUMINGRES = D.NUMINGRES
                AND DD.PROESTADO = '1'
                AND
                (
                    DD.CANPENDIE IS NULL
                    OR DD.CANDEVOLV IS NULL
                    OR DD.CANPENDIE <= 0
                    OR DD.CANPENDIE > DD.CANDEVOLV
                )
          )
          AND NOT EXISTS
          (
              /* Todos los detalles deben estar en estado final 2 o 3. */
              SELECT 1
              FROM dbo.HCDEVMEDD DD
              WHERE DD.CODCONCEC = D.CODCONCEC
                AND DD.IPCODPACI = D.IPCODPACI
                AND DD.NUMINGRES = D.NUMINGRES
                AND (DD.PROESTADO IS NULL OR DD.PROESTADO NOT IN ('2','3'))
          )
          AND NOT EXISTS
          (
              /* No deben quedar cantidades pendientes. */
              SELECT 1
              FROM dbo.HCDEVMEDD DD
              WHERE DD.CODCONCEC = D.CODCONCEC
                AND DD.IPCODPACI = D.IPCODPACI
                AND DD.NUMINGRES = D.NUMINGRES
                AND (DD.CANPENDIE IS NULL OR DD.CANPENDIE <> 0)
          )
          AND F.PROESTADO IN (2,3);


        UPDATE D
        SET D.DEVESTADO = T.EstadoNuevo
        FROM dbo.HCDEVMEDC D
        INNER JOIN @TrabajoDevolutivos T
            ON T.CODCONCEC = D.CODCONCEC
           AND T.IPCODPACI = D.IPCODPACI
           AND T.NUMINGRES = D.NUMINGRES;


        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODCONCEC,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            10,
            'Cabecera de devolutivo pendiente reconciliada con el estado de sus detalles',
            'UPDATE_DEVOLUTIVO',
            T.IPCODPACI,
            T.NUMINGRES,
            T.CODCONCEC,
            'DEVESTADO=' + T.EstadoAnterior,
            'DEVESTADO=' + T.EstadoNuevo,
            'No existen detalles pendientes validos. Se utiliza el estado del primer detalle como estado final de la cabecera.'
        FROM @TrabajoDevolutivos T;


        /* --------------------------------------------------------
           REGLA 10.1 - LIMPIEZA DE ALERTA DE DEVOLUTIVO EN CAMA

           Solo se elimina CAMDEVMED cuando la devolucion ya no
           tiene cantidades pendientes validas.

           Esta regla NO activa CAMDEVMED para devoluciones pendientes.
        -------------------------------------------------------- */

        DELETE FROM @TrabajoCamas;

        INSERT INTO @TrabajoCamas
        (
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            CAMDEVMED_Anterior,
            CAMDEVMED_Nuevo
        )
        SELECT DISTINCT
            E.IPCODPACI,
            E.NUMINGRES,
            C.CODICAMAS,
            C.CAMDEVMED,
            0
        FROM dbo.CHREGESTA E
        INNER JOIN dbo.CHCAMASHO C
            ON C.CODICAMAS = E.CODICAMAS
        INNER JOIN @TrabajoDevolutivos T
            ON T.IPCODPACI = E.IPCODPACI
           AND T.NUMINGRES = E.NUMINGRES
        WHERE E.FECFINEST >= '1900-01-01 00:00:00.000' AND E.FECFINEST <= '1900-01-01 23:59:59.000'
          AND E.FECINIEST >= @DateAt
          AND E.REGESTADO = 1
          AND C.CAMDEVMED = 1
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.HCDEVMEDC D
              INNER JOIN dbo.HCDEVMEDD DD
                  ON DD.CODCONCEC = D.CODCONCEC
                 AND DD.IPCODPACI = D.IPCODPACI
                 AND DD.NUMINGRES = D.NUMINGRES
              WHERE D.IPCODPACI = E.IPCODPACI
                AND D.NUMINGRES = E.NUMINGRES
                AND D.DEVESTADO = '1'
                AND DD.PROESTADO = '1'
                AND DD.CANPENDIE IS NOT NULL
                AND DD.CANDEVOLV IS NOT NULL
                AND DD.CANPENDIE > 0
                AND DD.CANPENDIE <= DD.CANDEVOLV
          );

        UPDATE C
        SET C.CAMDEVMED = 0
        FROM dbo.CHCAMASHO C
        INNER JOIN @TrabajoCamas T
            ON T.CODICAMAS = C.CODICAMAS;

        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            10,
            'Alerta de devolutivo eliminada despues de finalizar la devolucion',
            'UPDATE_CAMA',
            T.IPCODPACI,
            T.NUMINGRES,
            T.CODICAMAS,
            'CAMDEVMED=1',
            'CAMDEVMED=0',
            'La cabecera fue reconciliada y no existen cantidades pendientes validas en los detalles.'
        FROM @TrabajoCamas T;

        /* ============================================================
           REGLA 11 - CIERRE DE ESTANCIAS ACTIVAS CON EGRESO REGISTRADO
           ============================================================

           OBJETIVO
           ----------------------------------------------------------------
           Cuando un ingreso tiene un egreso registrado en CHREGEGRE y
           existen múltiples estancias activas en CHREGESTA:

           1. Las estancias se ordenan cronológicamente por FECINIEST.
           2. Cada estancia se cierra con la fecha de inicio de la
              siguiente estancia.
           3. La última estancia se cierra con FECEGRESO.
           4. Todas las estancias pasan de REGESTADO = 1 a REGESTADO = 2.
           5. Las camas asociadas se liberan.

           EJEMPLO:

               Estancia 1: 03:47 -> 16:15
               Estancia 2: 16:15 -> 17:11
               Estancia 3: 17:11 -> 12:47
               Estancia 4: 12:47 -> 12:47
               ...
               Última:     12:42 -> FECEGRESO

           IMPORTANTE
           ----------------------------------------------------------------
           Se utiliza LEAD() para obtener la siguiente FECINIEST dentro
           del mismo NUMINGRES.
        ============================================================ */


        /* ============================================================
           LIMPIAR TABLA DE TRABAJO
        ============================================================ */

        DELETE FROM @TrabajoEgresos;


        /* ============================================================
           CARGAR ESTANCIAS Y DETERMINAR FECHA DE CIERRE
        ============================================================ */

        ;WITH Estancias AS
        (
            SELECT
                E.ID,
                E.IPCODPACI,
                E.NUMINGRES,
                E.CODICAMAS,
                E.FECFINEST AS FechaAnterior,
                E.FECINIEST,
                E.REGESTADO,
                C.ESTADCAMA AS EstadoCamaAnterior,
                G.FECEGRESO AS FechaEgreso,

                LEAD(E.FECINIEST) OVER
                (
                    PARTITION BY E.NUMINGRES
                    ORDER BY
                        E.FECINIEST,
                        E.ID
                ) AS SiguienteFechaInicio

            FROM dbo.CHREGESTA E

            INNER JOIN dbo.CHREGEGRE G
                ON G.NUMINGRES = E.NUMINGRES

            INNER JOIN dbo.CHCAMASHO C
                ON C.CODICAMAS = E.CODICAMAS

            WHERE
                E.FECFINEST >= '1900-01-01 00:00:00.000' AND E.FECFINEST <= '1900-01-01 23:59:59.000'
                AND E.FECINIEST >= @DateAt
                AND E.REGESTADO = 1
        )
        INSERT INTO @TrabajoEgresos
        (
            ID,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            FechaAnterior,
            FechaNueva,
            FechaEgreso,
            EstadoCamaAnterior,
            OrdenEstancia
        )
        SELECT
            ID,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            FechaAnterior,

            CASE
                WHEN SiguienteFechaInicio IS NOT NULL
                    THEN SiguienteFechaInicio
                ELSE FechaEgreso
            END AS FechaNueva,

            FechaEgreso,
            EstadoCamaAnterior,

            ROW_NUMBER() OVER
            (
                PARTITION BY NUMINGRES
                ORDER BY
                    FECINIEST,
                    ID
            ) AS OrdenEstancia

        FROM Estancias;

        /* ============================================================
           ACTUALIZAR ESTANCIAS
        ============================================================ */

        UPDATE E
        SET
            E.FECFINEST = T.FechaNueva,
            E.REGESTADO = 2
        FROM dbo.CHREGESTA E
        INNER JOIN @TrabajoEgresos T
            ON T.ID = E.ID;


        /* ============================================================
           LIBERAR CAMAS
        ============================================================ */

        UPDATE C
        SET
            C.ESTADCAMA = 1
        FROM dbo.CHCAMASHO C
        INNER JOIN @TrabajoEgresos T
            ON T.CODICAMAS = C.CODICAMAS
        WHERE
            C.ESTADCAMA = 2;


        /* ============================================================
           AUDITORÍA
        ============================================================ */

        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            11,
            'Cierre de estancias activas con egreso registrado',
            'UPDATE_ESTANCIA_CAMA',
            T.IPCODPACI,
            T.NUMINGRES,
            T.CODICAMAS,

            CONVERT(VARCHAR(23), T.FechaAnterior, 121)
                + ' / REGESTADO=1 / ESTADCAMA='
                + T.EstadoCamaAnterior,

            CONVERT(VARCHAR(23), T.FechaNueva, 121)
                + ' / REGESTADO=2 / ESTADCAMA=1',

            'La estancia activa fue cerrada utilizando como fecha final '
                + CASE
                    WHEN T.FechaNueva = T.FechaEgreso
                        THEN 'la fecha de egreso registrada.'
                    ELSE 'la fecha de inicio de la siguiente estancia.'
                  END
                + ' Orden de estancia: '
                + CONVERT(VARCHAR(10), T.OrdenEstancia)
                + '.'
        FROM @TrabajoEgresos T;

      /*============================================================
        REGLA 12 - LIBERACIÓN DE CAMA ASIGNADA SIN ESTANCIA ACTIVA
        ============================================================
        Si una cama se encuentra en estado ESTADCAMA=2 (Asignada),
        pero no existe una estancia activa asociada a dicha cama
        en CHREGESTA, se considera una inconsistencia de
        información, ya que la cama aparece asignada en el
        aplicativo sin tener un paciente asociado.

        Para corregir la inconsistencia, la cama se libera
        estableciendo ESTADCAMA=1 (Libre) y se limpian las
        configuraciones o alertas asociadas a la asignación:

            CAMTRAMED   = 0
            CAMDEVMED   = 0
            BedType     = NULL
            TypeTransfer = NULL

        De esta forma, la cama queda disponible para una nueva
        asignación y se evita que permanezca registrada como
        ocupada o asignada sin una estancia activa asociada.
        
        ============================================================*/

        DELETE FROM @TrabajoCamasSinEstancia;

        INSERT INTO @TrabajoCamasSinEstancia
        (
            CODICAMAS,
            DESCCAMAS,
            UFUCODIGO,
            CODCENATE,
            ESTADCAMA,
            CAMTRAMED,
            CAMDEVMED,
            CODCONCEC,
            BedType,
            TypeTransfer
        )
        SELECT
            A.CODICAMAS,
            A.DESCCAMAS,
            A.UFUCODIGO,
            A.CODCENATE,
            A.ESTADCAMA,
            A.CAMTRAMED,
            A.CAMDEVMED,
            A.CODCONCEC,
            A.BedType,
            A.TypeTransfer
        FROM dbo.CHCAMASHO AS A
        WHERE
            A.ESTADCAMA = 2
          AND NOT EXISTS (
              SELECT 1
              FROM dbo.CHREGESTA AS C
              WHERE C.CODICAMAS = A.CODICAMAS
                AND C.FECINIEST >= @DateAt
                AND C.FECFINEST >= '1900-01-01 00:00:00.000' AND C.FECFINEST <= '1900-01-01 23:59:59.000'
                AND C.REGESTADO = 1
          );

        UPDATE C
            SET C.ESTADCAMA = 1,
                C.CAMTRAMED = 0,
                C.CAMDEVMED = 0,
                C.BedType = NULL,
                C.TypeTransfer = NULL
        FROM
            dbo.CHCAMASHO C
        INNER JOIN @TrabajoCamasSinEstancia AS T
            ON T.CODICAMAS = C.CODICAMAS

        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            ValorAnterior,
            ValorNuevo,
            Detalle
        )
        SELECT
            @FechaAuditoria,
            12,
            'Cama asignada sin estancia activa asociada. Se libera la cama y se limpian las configuraciones de asignación.',
            'UPDATE_CAMA',
            '--',
            '--',
            T.CODICAMAS,
            CONCAT(
                'ESTADCAMA = ', COALESCE(CONVERT(VARCHAR(20), T.ESTADCAMA), 'NULL'),
                ' / CAMTRAMED = ', COALESCE(CONVERT(VARCHAR(5), T.CAMTRAMED), 'NULL'),
                ' / CAMDEVMED = ', COALESCE(CONVERT(VARCHAR(5), T.CAMDEVMED), 'NULL'),
                ' / BedType = ', COALESCE(CONVERT(VARCHAR(20), T.BedType), 'NULL'),
                ' / TypeTransfer = ', COALESCE(CONVERT(VARCHAR(20), T.TypeTransfer), 'NULL')
            ),
            'ESTADCAMA = 1 / CAMTRAMED = 0 / CAMDEVMED = 0 / BedType = NULL / TypeTransfer = NULL',
            'La cama se encontraba en estado Asignada (ESTADCAMA=2) sin una estancia activa asociada en CHREGESTA. Se actualiza a Libre (ESTADCAMA=1) y se limpian CAMTRAMED, CAMDEVMED, BedType y TypeTransfer.'
        FROM @TrabajoCamasSinEstancia AS T;

        /* ========================================================
           FECHA FINAL
        ======================================================== */

        SET @FinEjecucion = GETDATE();


        /* ========================================================
           SIMULACION / COMMIT
        ======================================================== */

        IF @SoloSimular = 1
        BEGIN

            /*
                IMPORTANTE:

                Las TABLE VARIABLES conservan la auditoria aunque
                hagamos ROLLBACK.
            */

            ROLLBACK TRANSACTION;

        END
        ELSE
        BEGIN

            COMMIT TRANSACTION;

            /* ========================================================
               GUARDAR RESULTADO DETALLADO DE AUDITORIA
            ======================================================== */
            INSERT INTO [beds].[HospitalizationReconciliationAudit]
            (
                [Container],
                [CreatedAt],
                [StartExecution],
                [EndExecution],
                [Rule],
                [RuleDescription],
                [Action],
                [IPCODPACI],
                [NUMINGRES],
                [CODICAMAS],
                [CODICAMAS_PREVIOUSLY],
                [CODICAMAS_AFTER],
                [CODICAORI],
                [CODICADES],
                [CODCONCEC],
                [PreviousValue],
                [NewValue],
                [Detail],
                [NewRelicStatus],
                [NewRelicAttempts],
                [NewRelicProcessingAt],
                [NewRelicSentAt],
                [NewRelicResponse]
            )
            SELECT
                DB_NAME(),
                A.Fecha,
                @InicioEjecucion,
                @FinEjecucion,
                Regla,
                ReglaDescripcion,
                Accion,
                IPCODPACI,
                NUMINGRES,
                CODICAMAS,
                CODICAMAS_ANTERIOR,
                CODICAMAS_NUEVA,
                CODICAORI,
                CODICADES,
                CODCONCEC,
                ValorAnterior,
                ValorNuevo,
                Detalle,
                NULL,
                0,
                NULL,
                NULL,
                NULL
            FROM @Auditoria AS A;
        END;

        /* ========================================================
           RESUMEN
        ======================================================== */

        SELECT
            @InicioEjecucion AS InicioEjecucion,
            @FinEjecucion AS FinEjecucion,
            @SoloSimular AS SoloSimular,

            CASE
                WHEN @SoloSimular = 1
                    THEN 'SIMULACION - ROLLBACK'
                ELSE 'EJECUTADO - COMMIT'   
            END AS ResultadoEjecucion,

            COUNT(1) AS TotalRegistrosAuditoria,

            SUM
            (
                CASE
                    WHEN Accion LIKE 'UPDATE%'
                        THEN 1
                    ELSE 0
                END
            ) AS TotalCambios,

            SUM
            (
                CASE
                    WHEN Accion = 'NO_CORREGIDO'
                        THEN 1
                    ELSE 0
                END
            ) AS TotalNoCorregidos,

            SUM
            (
                CASE
                    WHEN Accion = 'DETECTADO'
                        THEN 1
                    ELSE 0
                END
            ) AS TotalDetectados

        FROM @Auditoria;


    END TRY

    BEGIN CATCH

        /* ========================================================
           ROLLBACK
        ======================================================== */

        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;


        /* ========================================================
           VARIABLES DEL ERROR
        ======================================================== */

        DECLARE @ErrorNumber INT;
        DECLARE @ErrorSeverity INT;
        DECLARE @ErrorState INT;
        DECLARE @ErrorLine INT;
        DECLARE @ErrorProcedure VARCHAR(200);
        DECLARE @ErrorMessage VARCHAR(4000);


        SELECT
            @ErrorNumber = ERROR_NUMBER(),
            @ErrorSeverity = ERROR_SEVERITY(),
            @ErrorState = ERROR_STATE(),
            @ErrorLine = ERROR_LINE(),
            @ErrorProcedure =
                ISNULL
                (
                    ERROR_PROCEDURE(),
                    'beds.usp_ReconcileHospitalization'
                ),
            @ErrorMessage = ERROR_MESSAGE();


        /* ========================================================
           REGISTRAR ERROR EN AUDITORIA TEMPORAL
        ======================================================== */

        INSERT INTO @Auditoria
        (
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            Detalle
        )
        VALUES
        (
            GETDATE(),
            999,
            'Error durante la reconciliacion',
            'ERROR',
            'Numero='
            + CONVERT(VARCHAR(20), @ErrorNumber)
            + '; Severidad='
            + CONVERT(VARCHAR(20), @ErrorSeverity)
            + '; Estado='
            + CONVERT(VARCHAR(20), @ErrorState)
            + '; Procedimiento='
            + ISNULL(@ErrorProcedure, '')
            + '; Linea='
            + CONVERT(VARCHAR(20), @ErrorLine)
            + '; Mensaje='
            + ISNULL(@ErrorMessage, '')
        );


        /* ========================================================
           DEVOLVER AUDITORIA DISPONIBLE
        ======================================================== */

        SELECT
            IdAuditoria,
            Fecha,
            Regla,
            ReglaDescripcion,
            Accion,
            IPCODPACI,
            NUMINGRES,
            CODICAMAS,
            CODICAMAS_ANTERIOR,
            CODICAMAS_NUEVA,
            CODICAORI,
            CODICADES,
            CODCONCEC,
            ValorAnterior,
            ValorNuevo,
            Detalle
        FROM @Auditoria
        ORDER BY
            IdAuditoria;


        /* ========================================================
           DEVOLVER ERROR AL CLIENTE / ELASTIC JOB AGENT
        ======================================================== */

        RAISERROR
        (
            'Error en beds.usp_ReconcileHospitalization. Numero=%d. Linea=%d. Mensaje=%s',
            16,
            1,
            @ErrorNumber,
            @ErrorLine,
            @ErrorMessage
        );

        RETURN;

    END CATCH;

END;

GO