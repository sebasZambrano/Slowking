CREATE OR ALTER PROCEDURE beds.usp_MarkHospitalizationAuditSent
    @Id BIGINT,
    @Response VARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE beds.HospitalizationReconciliationAudit
    SET
        NewRelicStatus = 'SENT',
        NewRelicSentAt = SYSUTCDATETIME(),
        NewRelicProcessingAt = NULL,
        NewRelicResponse = @Response
    WHERE
        Id = @Id
        AND NewRelicStatus = 'PROCESSING';
END;
GO