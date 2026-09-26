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
    private readonly string _apimSubscriptionKey;
    private readonly string[] _databases;

    public ProcessHospitalizationAudit(
        ILogger<ProcessHospitalizationAudit> logger,
        HospitalizationAuditService auditService,
        IHttpClientFactory httpClientFactory,
        IConfiguration configuration)
    {
        var databasesConfiguration =
            configuration["SQL_DATABASES"]
            ?? throw new InvalidOperationException(
                "SQL_DATABASES is not configured.");

        _databases = databasesConfiguration
            .Split(
                ',',
                StringSplitOptions.RemoveEmptyEntries |
                StringSplitOptions.TrimEntries);

        if (_databases.Length == 0)
        {
            throw new InvalidOperationException(
                "SQL_DATABASES does not contain any database.");
        }

        _logger = logger;
        _auditService = auditService;
        _httpClient = httpClientFactory.CreateClient();

        _apimUrl =
            configuration["APIM_HOSPITALIZATION_AUDIT_URL"]
            ?? throw new InvalidOperationException(
                "APIM_HOSPITALIZATION_AUDIT_URL is not configured.");

        _apimSubscriptionKey =
            configuration["APIM_SUBSCRIPTION_KEY"]
            ?? throw new InvalidOperationException(
                "APIM_SUBSCRIPTION_KEY is not configured.");

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

        _logger.LogInformation(
            "Configured databases: {Count}.",
            _databases.Length);

        foreach (var database in _databases)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                break;
            }

            await ProcessDatabaseAsync(
                database,
                cancellationToken);
        }

        _logger.LogInformation(
            "Hospitalization reconciliation New Relic process finished.");
    }

    private async Task ProcessEventAsync(
        string database,
        HospitalizationAuditEvent auditEvent,
        CancellationToken cancellationToken)
    {
        _logger.LogInformation(
            "Starting processing for AuditId {AuditId}.",
            auditEvent.AuditId);

        try
        {
            var payload = new[]
            {
                new
                {
                    eventType = "HospitalizationReconciliation",
                    auditId = auditEvent.AuditId,
                    container = database,
                    createdAt = auditEvent.CreatedAt,
                    startExecution = auditEvent.StartExecution,
                    endExecution = auditEvent.EndExecution,
                    rule = auditEvent.Rule,
                    ruleDescription = auditEvent.RuleDescription,
                    action = auditEvent.Action,
                    identificationNumber = auditEvent.IdentificationNumber,
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

            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                _apimUrl)
            {
                Content = JsonContent.Create(payload)
            };

            request.Headers.Add(
                "Ocp-Apim-Subscription-Key",
                _apimSubscriptionKey);

            _logger.LogInformation(
                "Sending AuditId {AuditId} to APIM.",
                auditEvent.AuditId);

            using var response = await _httpClient.SendAsync(
                request,
                cancellationToken);

            var responseBody =
                await response.Content.ReadAsStringAsync(
                    cancellationToken);

            _logger.LogInformation(
                "APIM response for AuditId {AuditId}: HTTP {StatusCode}. Body: {ResponseBody}",
                auditEvent.AuditId,
                (int)response.StatusCode,
                responseBody);

            if (response.IsSuccessStatusCode)
            {
                await _auditService.MarkSentAsync(
                    database,
                    auditEvent.AuditId,
                    $"HTTP {(int)response.StatusCode} - {responseBody}",
                    cancellationToken);

                _logger.LogInformation(
                    "AuditId {AuditId} marked as SENT.",
                    auditEvent.AuditId);

                return;
            }

            await _auditService.MarkErrorAsync(
                database,
                auditEvent.AuditId,
                $"HTTP {(int)response.StatusCode} - {responseBody}",
                cancellationToken);

            _logger.LogWarning(
                "AuditId {AuditId} marked as ERROR because APIM returned HTTP {StatusCode}.",
                auditEvent.AuditId,
                (int)response.StatusCode);
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Exception processing AuditId {AuditId}. Type={ExceptionType}, Message={Message}",
                auditEvent.AuditId,
                ex.GetType().FullName,
                ex.Message);

            try
            {
                await _auditService.MarkErrorAsync(
                    database,
                    auditEvent.AuditId,
                    ex.ToString(),
                    cancellationToken);

                _logger.LogInformation(
                    "AuditId {AuditId} marked as ERROR after exception.",
                    auditEvent.AuditId);
            }
            catch (Exception statusException)
            {
                _logger.LogError(
                    statusException,
                    "Could not mark AuditId {AuditId} as ERROR. Type={ExceptionType}, Message={Message}",
                    auditEvent.AuditId,
                    statusException.GetType().FullName,
                    statusException.Message);
            }
        }
    }

    private async Task ProcessDatabaseAsync(
    string database,
    CancellationToken cancellationToken)
    {
        _logger.LogInformation(
            "[{Database}] Starting hospitalization audit processing.",
            database);

        try
        {
            var events = await _auditService.ClaimPendingAsync(
                database,
                cancellationToken);

            _logger.LogInformation(
                "[{Database}] ClaimPendingAsync returned {Count} records.",
                database,
                events.Count);

            if (events.Count == 0)
            {
                _logger.LogInformation(
                    "[{Database}] No pending hospitalization audit records found.",
                    database);

                return;
            }

            foreach (var auditEvent in events)
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    break;
                }

                await ProcessEventAsync(
                    database,
                    auditEvent,
                    cancellationToken);
            }

            _logger.LogInformation(
                "[{Database}] Finished processing {Count} records.",
                database,
                events.Count);
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "[{Database}] Error processing hospitalization audit.",
                database);
        }
    }
}