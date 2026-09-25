/* ============================================================================
TABLA FISICA DE AUDITORIA
beds.HospitalizationReconciliationAudit

Una fila representa un evento/regla dentro de una ejecución del SP.

AUTOR:
----------------------------------------------------------------------------
Johan Sebastian Zambrano Polanco - Senior Tech Service Engineer

============================================================================ */
IF OBJECT_ID('beds.HospitalizationReconciliationAudit', 'U') IS NULL
BEGIN
    CREATE TABLE beds.HospitalizationReconciliationAudit
    (
        [Id] BIGINT IDENTITY(1,1) NOT NULL,
        [Container] NVARCHAR(50) NOT NULL,
        [CreatedAt] DATETIME NOT NULL,
        [StartExecution] DATETIME NOT NULL,
        [EndExecution] DATETIME NULL,
        [Rule] INT NOT NULL,
        [RuleDescription] VARCHAR(255) NOT NULL,
        [Action] VARCHAR(50) NOT NULL,
        [IPCODPACI] VARCHAR(25) NULL,
        [NUMINGRES] CHAR(10) NULL,
        [CODICAMAS] INT NULL,
        [CODICAMAS_PREVIOUSLY] INT NULL,
        [CODICAMAS_AFTER] INT NULL,
        [CODICAORI] INT NULL,
        [CODICADES] INT NULL,
        [CODCONCEC] INT NULL,
        [PreviousValue] VARCHAR(255) NULL,
        [NewValue] VARCHAR(255) NULL,
        [Detail] VARCHAR(255) NULL,
        [NewRelicStatus] VARCHAR(50) NULL,
        [NewRelicAttempts] INT NULL,
        [NewRelicProcessingAt] DATETIME NULL,
        [NewRelicSentAt] DATETIME NULL,
        [NewRelicResponse] VARCHAR(100) NULL,
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID('beds.HospitalizationReconciliationAudit')
      AND name = 'IX_HospitalizationReconciliationAudit_CreatedAt'
)
BEGIN
    CREATE INDEX IX_HospitalizationReconciliationAudit_CreatedAt
        ON beds.HospitalizationReconciliationAudit (CreatedAt DESC);
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID('beds.HospitalizationReconciliationAudit')
      AND name = 'IX_HospitalizationReconciliationAudit_PatientAdmission'
)
BEGIN
    CREATE INDEX IX_HospitalizationReconciliationAudit_PatientAdmission
        ON beds.HospitalizationReconciliationAudit
        (
            IPCODPACI,
            NUMINGRES
        );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID('beds.HospitalizationReconciliationAudit')
      AND name = 'IX_HospitalizationReconciliationAudit_RuleDate'
)
BEGIN
    CREATE INDEX IX_HospitalizationReconciliationAudit_RuleDate
        ON beds.HospitalizationReconciliationAudit
        (
            [Rule],
            CreatedAt DESC
        );
END;
GO