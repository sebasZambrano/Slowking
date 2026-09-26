using HospitalizationReconciliationNewRelic.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using System.Data;

namespace HospitalizationReconciliationNewRelic.Services;

public sealed class HospitalizationAuditService
{
    private readonly string _server;
    private readonly string _userId;
    private readonly string _password;

    public HospitalizationAuditService(IConfiguration configuration)
    {
        _server = configuration["SQL_SERVER"] ?? throw new InvalidOperationException("SQL_SERVER is not configured.");
        _userId = configuration["USER_ID"] ?? throw new InvalidOperationException("USER_ID is not configured.");
        _password = configuration["PASSWORD"] ?? throw new InvalidOperationException("PASSWORD is not configured.");
    }

    public async Task<List<HospitalizationAuditEvent>> ClaimPendingAsync( string database, CancellationToken cancellationToken)
    {
        var events = new List<HospitalizationAuditEvent>();

        await using var connection = new SqlConnection(
            BuildConnectionString(database));

        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand(
            "Beds.usp_ClaimHospitalizationAuditForNewRelic",
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
                AuditId = reader.GetInt64(
                    reader.GetOrdinal("Id")),

                Container = GetNullableString(
                    reader,
                    "Container"),

                CreatedAt = reader.GetDateTime(
                    reader.GetOrdinal("CreatedAt")),

                StartExecution = GetNullableDateTime(
                    reader,
                    "StartExecution"),

                EndExecution = GetNullableDateTime(
                    reader,
                    "EndExecution"),

                Rule = GetNullableInt32(
                    reader,
                    "Rule"),

                RuleDescription = GetNullableString(
                    reader,
                    "RuleDescription"),

                Action = GetNullableString(
                    reader,
                    "Action"),

                IdentificationNumber = GetNullableString(
                    reader,
                    "IPCODPACI"),

                AdmissionNumber = GetNullableString(
                    reader,
                    "NUMINGRES"),

                Bed = GetNullableInt32(
                    reader,
                    "CODICAMAS"),

                PreviousBed = GetNullableInt32(
                    reader,
                    "CODICAMAS_PREVIOUSLY"),

                NewBed = GetNullableInt32(
                    reader,
                    "CODICAMAS_AFTER"),

                OriginBed = GetNullableInt32(
                    reader,
                    "CODICAORI"),

                DestinationBed = GetNullableInt32(
                    reader,
                    "CODICADES"),

                TransferConsecutive = GetNullableInt32(
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

    public async Task MarkSentAsync( string database, long id, string? response, CancellationToken cancellationToken)
    {
        await ExecuteStatusProcedureAsync(
            database,
            "Beds.usp_MarkHospitalizationAuditSent",
            id,
            response,
            cancellationToken);
    }

    public async Task MarkErrorAsync( string database, long id, string? response, CancellationToken cancellationToken)
    {
        await ExecuteStatusProcedureAsync(
            database,
            "Beds.usp_MarkHospitalizationAuditError",
            id,
            response,
            cancellationToken);
    }

    private async Task ExecuteStatusProcedureAsync( string database, string procedureName, long id, string? response, CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(
            BuildConnectionString(database));

        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand(
            procedureName,
            connection)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 30
        };

        command.Parameters.Add(
            new SqlParameter("@Id", SqlDbType.BigInt)
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

    private string BuildConnectionString(string database)
    {
        return
            $"Server={_server};" +
            $"Initial Catalog={database};" +
            $"User Id={_userId};" +
            $"Password={_password};" +
            "Connection Timeout=30;";
    }

    private static string? GetNullableString( SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);

        return reader.IsDBNull(ordinal)
            ? null
            : reader.GetString(ordinal);
    }

    private static int? GetNullableInt32( SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);

        return reader.IsDBNull(ordinal)
            ? null
            : reader.GetInt32(ordinal);
    }

    private static DateTime? GetNullableDateTime( SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);

        return reader.IsDBNull(ordinal)
            ? null
            : reader.GetDateTime(ordinal);
    }
}