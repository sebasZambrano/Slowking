using System.Net;
using System.Net.Http.Json;
using HospitalizationReconciliationNewRelic.Models;
using HospitalizationReconciliationNewRelic.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace HospitalizationReconciliationNewRelic.Functions;

public sealed class ProcessHospitalizationAudit
{
    private readonly ILogger<ProcessHospitalizationAudit> _logger;
    private readonly HospitalizationAuditService _auditService;
    private readonly HttpClient _httpClient;
    private readonly string _apimUrl;

    public ProcessHospitalizationAudit(
        ILogger<ProcessHospitalizationAudit> logger,
        HospitalizationAuditService auditService,
        IHttpClientFactory httpClientFactory,
        IConfiguration configuration)
    {
        _logger = logger;
        _auditService = auditService;
        _httpClient = httpClientFactory.CreateClient();

        _apimUrl =
            configuration["APIM_HOSPITALIZATION_AUDIT_URL"]
            ?? throw new InvalidOperationException(
                "APIM_HOSPITALIZATION_AUDIT_URL is not configured.");

        _httpClient.Timeout = TimeSpan.FromSeconds(30);
    }

    [Function("ProcessHospitalizationAudit")]
    public async Task Run(
        [TimerTrigger("0 2/5 * * * *")] TimerInfo timer,
        CancellationToken cancellationToken)
    {
        _logger.LogInformation(
            "Hospitalization reconciliation New Relic process started at {Time}.",
            DateTime.UtcNow);

        List<HospitalizationAuditEvent> events;

        try
        {
            events = await _auditService.ClaimPendingAsync(
                cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Error claiming hospitalization audit records.");

            throw;
        }

        if (events.Count == 0)
        {
            _logger.LogInformation(
                "No pending hospitalization audit records found.");

            return;
        }

        _logger.LogInformation(
            "Claimed {Count} hospitalization audit records.",
            events.Count);

        foreach (var auditEvent in events)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                break;
            }

            await ProcessEventAsync(
                auditEvent,
                cancellationToken);
        }

        _logger.LogInformation(
            "Hospitalization reconciliation New Relic process finished.");
    }

    private async Task ProcessEventAsync(
        HospitalizationAuditEvent auditEvent,
        CancellationToken cancellationToken)
    {
        try
        {
            var payload = new[]
            {
                new
                {
                    eventType = "HospitalizationReconciliation",
                    auditId = auditEvent.AuditId,
                    createdAt = auditEvent.CreatedAt,
                    startExecution = auditEvent.StartExecution,
                    endExecution = auditEvent.EndExecution,
                    rule = auditEvent.Rule,
                    ruleDescription = auditEvent.RuleDescription,
                    action = auditEvent.Action,
                    admissionNumber = auditEvent.AdmissionNumber,
                    bed = auditEvent.Bed,
                    previousBed = auditEvent.PreviousBed,
                    newBed = auditEvent.NewBed,
                    originBed = auditEvent.OriginBed,
                    destinationBed = auditEvent.DestinationBed,
                    transferConsecutive = auditEvent.TransferConsecutive,
                    previousValue = auditEvent.PreviousValue,
                    newValue = auditEvent.NewValue,
                    detail = auditEvent.Detail
                }
            };

            using var response = await _httpClient.PostAsJsonAsync(
                _apimUrl,
                payload,
                cancellationToken);

            var responseBody =
                await response.Content.ReadAsStringAsync(
                    cancellationToken);

            if (response.IsSuccessStatusCode)
            {
                await _auditService.MarkSentAsync(
                    auditEvent.AuditId,
                    $"HTTP {(int)response.StatusCode} - {responseBody}",
                    cancellationToken);

                _logger.LogInformation(
                    "Audit {AuditId} sent successfully to New Relic through APIM.",
                    auditEvent.AuditId);

                return;
            }

            await _auditService.MarkErrorAsync(
                auditEvent.AuditId,
                $"HTTP {(int)response.StatusCode} - {responseBody}",
                cancellationToken);

            _logger.LogError(
                "APIM returned HTTP {StatusCode} for audit {AuditId}.",
                response.StatusCode,
                auditEvent.AuditId);
        }
        catch (Exception ex)
        {
            var error = ex.Message;

            try
            {
                await _auditService.MarkErrorAsync(
                    auditEvent.AuditId,
                    error,
                    cancellationToken);
            }
            catch (Exception statusException)
            {
                _logger.LogError(
                    statusException,
                    "Could not mark audit {AuditId} as ERROR.",
                    auditEvent.AuditId);
            }

            _logger.LogError(
                ex,
                "Error sending audit {AuditId} to APIM.",
                auditEvent.AuditId);
        }
    }
}