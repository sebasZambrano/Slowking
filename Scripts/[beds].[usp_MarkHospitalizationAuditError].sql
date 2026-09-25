CREATE OR ALTER PROCEDURE beds.usp_MarkHospitalizationAuditError
    @Id INT,
    @Response VARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE beds.HospitalizationReconciliationAudit
    SET
        NewRelicStatus = 'ERROR',
        NewRelicProcessingAt = NULL,
        NewRelicResponse = @Response
    WHERE
        Id = @Id
        AND NewRelicStatus = 'PROCESSING';
END;
GO