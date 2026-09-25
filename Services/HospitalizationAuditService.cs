using HospitalizationReconciliationNewRelic.Models;
using Microsoft.Data.SqlClient;
using System.Data;
using Microsoft.Extensions.Configuration;

namespace HospitalizationReconciliationNewRelic.Services;

public sealed class HospitalizationAuditService
{
    private readonly string _connectionString;

    public HospitalizationAuditService(IConfiguration configuration)
    {
        _connectionString =
            configuration["SQL_CONNECTION_STRING"]
            ?? throw new InvalidOperationException(
                "SQL_CONNECTION_STRING is not configured.");
    }

    public async Task<List<HospitalizationAuditEvent>> ClaimPendingAsync(
        CancellationToken cancellationToken)
    {
        var events = new List<HospitalizationAuditEvent>();

        await using var connection = new SqlConnection(_connectionString);

        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand(
            "beds.usp_ClaimHospitalizationAuditForNewRelic",
            connection)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 60
        };

        await using var reader =
            await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            events.Add(new HospitalizationAuditEvent
            {
                AuditId = reader.GetInt32(reader.GetOrdinal("Id")),

                CreatedAt = reader.GetDateTime(
                    reader.GetOrdinal("CreatedAt")),

                StartExecution = GetNullableDateTime(
                    reader,
                    "StartExecution"),

                EndExecution = GetNullableDateTime(
                    reader,
                    "EndExecution"),

                Rule = GetNullableString(reader, "Rule"),

                RuleDescription = GetNullableString(
                    reader,
                    "RuleDescription"),

                Action = GetNullableString(reader, "Action"),

                AdmissionNumber = GetNullableString(
                    reader,
                    "NUMINGRES"),

                Bed = GetNullableString(
                    reader,
                    "CODICAMAS"),

                PreviousBed = GetNullableString(
                    reader,
                    "CODICAMAS_PREVIOUSLY"),

                NewBed = GetNullableString(
                    reader,
                    "CODICAMAS_AFTER"),

                OriginBed = GetNullableString(
                    reader,
                    "CODICAORI"),

                DestinationBed = GetNullableString(
                    reader,
                    "CODICADES"),

                TransferConsecutive = GetNullableString(
                    reader,
                    "CODCONCEC"),

                PreviousValue = GetNullableString(
                    reader,
                    "PreviousValue"),

                NewValue = GetNullableString(
                    reader,
                    "NewValue"),

                Detail = GetNullableString(
                    reader,
                    "Detail")
            });
        }

        return events;
    }

    public async Task MarkSentAsync(
        int id,
        string? response,
        CancellationToken cancellationToken)
    {
        await ExecuteStatusProcedureAsync(
            "beds.usp_MarkHospitalizationAuditSent",
            id,
            response,
            cancellationToken);
    }

    public async Task MarkErrorAsync(
        int id,
        string? response,
        CancellationToken cancellationToken)
    {
        await ExecuteStatusProcedureAsync(
            "beds.usp_MarkHospitalizationAuditError",
            id,
            response,
            cancellationToken);
    }

    private async Task ExecuteStatusProcedureAsync(
        string procedureName,
        int id,
        string? response,
        CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(_connectionString);

        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand(
            procedureName,
            connection)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 30
        };

        command.Parameters.Add(
            new SqlParameter("@Id", SqlDbType.Int)
            {
                Value = id
            });

        command.Parameters.Add(
            new SqlParameter("@Response", SqlDbType.VarChar, 4000)
            {
                Value = (object?)response ?? DBNull.Value
            });

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static string? GetNullableString(
        SqlDataReader reader,
        string column)
    {
        var ordinal = reader.GetOrdinal(column);

        return reader.IsDBNull(ordinal)
            ? null
            : reader.GetString(ordinal);
    }

    private static DateTime? GetNullableDateTime(
        SqlDataReader reader,
        string column)
    {
        var ordinal = reader.GetOrdinal(column);

        return reader.IsDBNull(ordinal)
            ? null
            : reader.GetDateTime(ordinal);
    }
}