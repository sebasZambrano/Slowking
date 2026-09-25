CREATE OR ALTER PROCEDURE beds.usp_ClaimHospitalizationAuditForNewRelic
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2 = SYSUTCDATETIME();

    BEGIN TRANSACTION;

    /*
        Recover records abandoned by a previous execution.

        A record remaining in PROCESSING for more than 15 minutes
        is considered abandoned and becomes eligible for retry.
    */
    UPDATE beds.HospitalizationReconciliationAudit
    SET
        NewRelicStatus = 'ERROR',
        NewRelicProcessingAt = NULL,
        NewRelicResponse = 'Recovered from PROCESSING timeout'
    WHERE
        NewRelicStatus = 'PROCESSING'
        AND NewRelicProcessingAt < DATEADD(MINUTE, -15, @Now);

    ;WITH Pending AS
    (
        SELECT TOP (100)
            Id
        FROM beds.HospitalizationReconciliationAudit WITH
        (
            UPDLOCK,
            READPAST,
            ROWLOCK
        )
        WHERE
            (
                NewRelicStatus IS NULL
                OR NewRelicStatus = 'PENDING'
                OR
                (
                    NewRelicStatus = 'ERROR'
                    AND NewRelicAttempts < 5
                )
            )
        ORDER BY Id
    )
    UPDATE A
    SET
        NewRelicStatus = 'PROCESSING',
        NewRelicProcessingAt = @Now,
        NewRelicResponse = NULL,
        NewRelicAttempts = NewRelicAttempts + 1
    OUTPUT
        inserted.Id,
        inserted.CreatedAt,
        inserted.StartExecution,
        inserted.EndExecution,
        inserted.[Rule],
        inserted.RuleDescription,
        inserted.[Action],
        inserted.IPCODPACI,
        inserted.NUMINGRES,
        inserted.CODICAMAS,
        inserted.CODICAMAS_PREVIOUSLY,
        inserted.CODICAMAS_AFTER,
        inserted.CODICAORI,
        inserted.CODICADES,
        inserted.CODCONCEC,
        inserted.PreviousValue,
        inserted.NewValue,
        inserted.Detail
    FROM beds.HospitalizationReconciliationAudit A
    INNER JOIN Pending P
        ON P.Id = A.Id;

    COMMIT TRANSACTION;
END;
GO