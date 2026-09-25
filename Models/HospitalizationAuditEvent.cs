namespace HospitalizationReconciliationNewRelic.Models;

public sealed class HospitalizationAuditEvent
{
    public int AuditId { get; set; }

    public DateTime CreatedAt { get; set; }

    public DateTime? StartExecution { get; set; }

    public DateTime? EndExecution { get; set; }

    public string? Rule { get; set; }

    public string? RuleDescription { get; set; }

    public string? Action { get; set; }

    public string? AdmissionNumber { get; set; }

    public string? Bed { get; set; }

    public string? PreviousBed { get; set; }

    public string? NewBed { get; set; }

    public string? OriginBed { get; set; }

    public string? DestinationBed { get; set; }

    public string? TransferConsecutive { get; set; }

    public string? PreviousValue { get; set; }

    public string? NewValue { get; set; }

    public string? Detail { get; set; }
}