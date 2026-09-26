using System.Net;
using System.Net.Http.Json;
using Slowking.Models;
using Slowking.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace Slowking.Functions;

public sealed class ProcessHospitalizationAudit
{
    private readonly ILogger<ProcessHospitalizationAudit> _logger;

    private readonly HospitalizationAuditService _auditService;

    private readonly HttpClient _httpClient;

    private readonly string[] _databases;

    private readonly string _apimUrl;

    private readonly string _apimSubscriptionKey;

    public ProcessHospitalizationAudit(
        ILogger<ProcessHospitalizationAudit> logger,
        HospitalizationAuditService auditService,
        IHttpClientFactory httpClientFactory,
        IConfiguration configuration)
    {
        _logger = logger;

        _auditService = auditService;

        _httpClient =
            httpClientFactory.CreateClient();

        var databasesConfiguration =
            configuration["SQL_DATABASES"]
            ?? throw new InvalidOperationException(
                "SQL_DATABASES is not configured.");

        _databases =
            databasesConfiguration
                .Split(
                    ',',
                    StringSplitOptions.RemoveEmptyEntries |
                    StringSplitOptions.TrimEntries);

        if (_databases.Length == 0)
        {
            throw new InvalidOperationException(
                "SQL_DATABASES does not contain any database.");
        }

        _apimUrl =
            configuration["APIM_HOSPITALIZATION_AUDIT_URL"]
            ?? throw new InvalidOperationException(
                "APIM_HOSPITALIZATION_AUDIT_URL is not configured.");

        _apimSubscriptionKey =
            configuration["APIM_SUBSCRIPTION_KEY"]
            ?? throw new InvalidOperationException(
                "APIM_SUBSCRIPTION_KEY is not configured.");
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
                _logger.LogWarning(
                    "Cancellation requested. Stopping database processing.");

                break;
            }

            await ProcessDatabaseAsync(
                database,
                cancellationToken);
        }

        _logger.LogInformation(
            "Hospitalization reconciliation New Relic process finished at {Time}.",
            DateTime.UtcNow);
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
            var events =
                await _auditService.ClaimPendingAsync(
                    database,
                    cancellationToken);

            _logger.LogInformation(
                "[{Database}] Claimed {Count} hospitalization audit records.",
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
                    _logger.LogWarning(
                        "[{Database}] Cancellation requested while processing records.",
                        database);

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
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
            _logger.LogWarning(
                "[{Database}] Processing was cancelled.",
                database);
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "[{Database}] Error processing hospitalization audit.",
                database);
        }
    }

    private async Task ProcessEventAsync(
        string database,
        HospitalizationAuditEvent auditEvent,
        CancellationToken cancellationToken)
    {
        try
        {
            var payload = new
            {
                eventType = "HospitalizationReconciliation",

                container = database,

                auditId = auditEvent.AuditId,

                createdAt = auditEvent.CreatedAt,

                startExecution = auditEvent.StartExecution,

                endExecution = auditEvent.EndExecution,

                rule = auditEvent.Rule,

                ruleDescription =
                    auditEvent.RuleDescription,

                action = auditEvent.Action,

                identificationNumber =
                    auditEvent.IdentificationNumber,

                admissionNumber =
                    auditEvent.AdmissionNumber,

                bed = auditEvent.Bed,

                previousBed =
                    auditEvent.PreviousBed,

                newBed =
                    auditEvent.NewBed,

                originBed =
                    auditEvent.OriginBed,

                destinationBed =
                    auditEvent.DestinationBed,

                transferConsecutive =
                    auditEvent.TransferConsecutive,

                previousValue =
                    auditEvent.PreviousValue,

                newValue =
                    auditEvent.NewValue,

                detail =
                    auditEvent.Detail
            };

            using var request =
                new HttpRequestMessage(
                    HttpMethod.Post,
                    _apimUrl)
                {
                    Content =
                        JsonContent.Create(payload)
                };

            request.Headers.Add(
                "Ocp-Apim-Subscription-Key",
                _apimSubscriptionKey);

            _logger.LogInformation(
                "[{Database}] Sending audit {AuditId} to New Relic through APIM.",
                database,
                auditEvent.AuditId);

            using var response =
                await _httpClient.SendAsync(
                    request,
                    cancellationToken);

            var responseBody =
                await response.Content.ReadAsStringAsync(
                    cancellationToken);

            _logger.LogInformation(
                "[{Database}] APIM response for audit {AuditId}: {StatusCode}.",
                database,
                auditEvent.AuditId,
                (int)response.StatusCode);

            if (response.IsSuccessStatusCode)
            {
                await _auditService.MarkSentAsync(
                    database,
                    auditEvent.AuditId,
                    responseBody,
                    cancellationToken);

                _logger.LogInformation(
                    "[{Database}] Audit {AuditId} marked as SENT.",
                    database,
                    auditEvent.AuditId);

                return;
            }

            await _auditService.MarkErrorAsync(
                database,
                auditEvent.AuditId,
                BuildErrorResponse(
                    response.StatusCode,
                    responseBody),
                cancellationToken);

            _logger.LogWarning(
                "[{Database}] Audit {AuditId} marked as ERROR. APIM returned {StatusCode}.",
                database,
                auditEvent.AuditId,
                (int)response.StatusCode);
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "[{Database}] Error sending audit {AuditId} to New Relic.",
                database,
                auditEvent.AuditId);

            try
            {
                await _auditService.MarkErrorAsync(
                    database,
                    auditEvent.AuditId,
                    ex.ToString(),
                    cancellationToken);
            }
            catch (Exception markErrorException)
            {
                _logger.LogError(
                    markErrorException,
                    "[{Database}] Failed to mark audit {AuditId} as ERROR.",
                    database,
                    auditEvent.AuditId);
            }
        }
    }

    private static string BuildErrorResponse(
        HttpStatusCode statusCode,
        string responseBody)
    {
        var response =
            $"HTTP {(int)statusCode}: {responseBody}";

        return response.Length <= 4000
            ? response
            : response[..4000];
    }
}