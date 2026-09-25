namespace HospitalizationReconciliationNewRelic.Models;

public sealed class HospitalizationAuditEvent
{
    public long AuditId { get; set; }

    public string? Container { get; set; }

    public DateTime CreatedAt { get; set; }

    public DateTime? StartExecution { get; set; }

    public DateTime? EndExecution { get; set; }

    public int? Rule { get; set; }

    public string? RuleDescription { get; set; }

    public string? Action { get; set; }

    public string? IdentificationNumber { get; set; }

    public string? AdmissionNumber { get; set; }

    public int? Bed { get; set; }

    public int? PreviousBed { get; set; }

    public int? NewBed { get; set; }

    public int? OriginBed { get; set; }

    public int? DestinationBed { get; set; }

    public int? TransferConsecutive { get; set; }

    public string? PreviousValue { get; set; }

    public string? NewValue { get; set; }

    public string? Detail { get; set; }
}