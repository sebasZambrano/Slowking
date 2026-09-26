namespace Slowking.Entities;

public sealed class HospitalizationReconciliationAudit
{
    public long Id { get; set; }

    public string Container { get; set; } = null!;

    public DateTime CreatedAt { get; set; }

    public DateTime StartExecution { get; set; }

    public DateTime? EndExecution { get; set; }

    public int Rule { get; set; }

    public string RuleDescription { get; set; } = null!;

    public string Action { get; set; } = null!;

    public string? IPCODPACI { get; set; }

    public string? NUMINGRES { get; set; }

    public int? CODICAMAS { get; set; }

    public int? CODICAMAS_PREVIOUSLY { get; set; }

    public int? CODICAMAS_AFTER { get; set; }

    public int? CODICAORI { get; set; }

    public int? CODICADES { get; set; }

    public int? CODCONCEC { get; set; }

    public string? PreviousValue { get; set; }

    public string? NewValue { get; set; }

    public string? Detail { get; set; }

    public string? NewRelicStatus { get; set; }

    public int? NewRelicAttempts { get; set; }

    public DateTime? NewRelicProcessingAt { get; set; }

    public DateTime? NewRelicSentAt { get; set; }

    public string? NewRelicResponse { get; set; }
}