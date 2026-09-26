using System.Data;
using System.Data.Common;
using Slowking.Data;
using Slowking.Models;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;
using Microsoft.Extensions.Configuration;

namespace Slowking.Services;

public sealed class HospitalizationAuditService
{
    private const int BatchSize = 100;
    private const int ProcessingTimeoutMinutes = 15;
    private const int MaxAttempts = 5;

    private readonly string _server;
    private readonly string _userId;
    private readonly string _password;

    public HospitalizationAuditService(IConfiguration configuration)
    {
        _server = configuration["SQL_SERVER"] ?? throw new InvalidOperationException("SQL_SERVER is not configured.");
        _userId = configuration["USER_ID"] ?? throw new InvalidOperationException("USER_ID is not configured.");
        _password = configuration["PASSWORD"] ?? throw new InvalidOperationException("PASSWORD is not configured.");
    }

    public async Task<List<HospitalizationAuditEvent>> ClaimPendingAsync(
        string database,
        CancellationToken cancellationToken)
    {
        var options = BuildDbContextOptions(database);

        // Create a temporary context only to obtain the configured execution strategy.
        await using var strategyContext =
            new HospitalizationDbContext(options);

        var strategy =
            strategyContext.Database.CreateExecutionStrategy();

        return await strategy.ExecuteAsync(
            async () =>
            {
                await using var db =
                    new HospitalizationDbContext(options);

                await using var transaction =
                    await db.Database.BeginTransactionAsync(
                        IsolationLevel.ReadCommitted,
                        cancellationToken);

                var now = DateTime.UtcNow;

                await RecoverStaleProcessingAsync(
                    db,
                    now,
                    cancellationToken);

                var sql = """
                    ;WITH Pending AS
                    (
                        SELECT TOP (@BatchSize)
                            Id
                        FROM Beds.HospitalizationReconciliationAudit WITH
                        (
                            UPDLOCK,
                            READPAST,
                            ROWLOCK
                        )
                        WHERE
                            (
                                NewRelicStatus IS NULL
                                OR NewRelicStatus = 'PENDING'
                                OR
                                (
                                    NewRelicStatus = 'ERROR'
                                    AND ISNULL(NewRelicAttempts, 0) < @MaxAttempts
                                )
                            )
                        ORDER BY Id
                    )
                    UPDATE A
                    SET
                        NewRelicStatus = 'PROCESSING',
                        NewRelicProcessingAt = @Now,
                        NewRelicResponse = NULL,
                        NewRelicAttempts = ISNULL(NewRelicAttempts, 0) + 1
                    OUTPUT
                        inserted.Id,
                        inserted.Container,
                        inserted.CreatedAt,
                        inserted.StartExecution,
                        inserted.EndExecution,
                        inserted.[Rule],
                        inserted.RuleDescription,
                        inserted.[Action],
                        inserted.IPCODPACI,
                        inserted.NUMINGRES,
                        inserted.CODICAMAS,
                        inserted.CODICAMAS_PREVIOUSLY,
                        inserted.CODICAMAS_AFTER,
                        inserted.CODICAORI,
                        inserted.CODICADES,
                        inserted.CODCONCEC,
                        inserted.PreviousValue,
                        inserted.NewValue,
                        inserted.Detail
                    FROM Beds.HospitalizationReconciliationAudit A
                    INNER JOIN Pending P
                        ON P.Id = A.Id;
                    """;

                var events =
                    new List<HospitalizationAuditEvent>();

                var connection =
                    db.Database.GetDbConnection();

                await using var command =
                    connection.CreateCommand();

                var currentTransaction =
                    db.Database.CurrentTransaction;

                if (currentTransaction is not null)
                {
                    command.Transaction =
                        currentTransaction.GetDbTransaction();
                }

                command.CommandText = sql;

                var batchSizeParameter =
                    command.CreateParameter();

                batchSizeParameter.ParameterName =
                    "@BatchSize";

                batchSizeParameter.DbType =
                    DbType.Int32;

                batchSizeParameter.Value =
                    BatchSize;

                command.Parameters.Add(
                    batchSizeParameter);

                var maxAttemptsParameter =
                    command.CreateParameter();

                maxAttemptsParameter.ParameterName =
                    "@MaxAttempts";

                maxAttemptsParameter.DbType =
                    DbType.Int32;

                maxAttemptsParameter.Value =
                    MaxAttempts;

                command.Parameters.Add(
                    maxAttemptsParameter);

                var nowParameter =
                    command.CreateParameter();

                nowParameter.ParameterName =
                    "@Now";

                nowParameter.DbType =
                    DbType.DateTime2;

                nowParameter.Value =
                    now;

                command.Parameters.Add(
                    nowParameter);

                if (connection.State != ConnectionState.Open)
                {
                    await connection.OpenAsync(
                        cancellationToken);
                }

                await using (var reader =
                    await command.ExecuteReaderAsync(
                        cancellationToken))
                {
                    while (await reader.ReadAsync(
                            cancellationToken))
                    {
                        events.Add(
                            new HospitalizationAuditEvent
                            {
                                AuditId =
                                    reader.GetInt64(
                                        reader.GetOrdinal("Id")),

                                Container =
                                    GetNullableString(
                                        reader,
                                        "Container"),

                                CreatedAt =
                                    reader.GetDateTime(
                                        reader.GetOrdinal("CreatedAt")),

                                StartExecution =
                                    GetNullableDateTime(
                                        reader,
                                        "StartExecution"),

                                EndExecution =
                                    GetNullableDateTime(
                                        reader,
                                        "EndExecution"),

                                Rule =
                                    GetNullableInt32(
                                        reader,
                                        "Rule"),

                                RuleDescription =
                                    GetNullableString(
                                        reader,
                                        "RuleDescription"),

                                Action =
                                    GetNullableString(
                                        reader,
                                        "Action"),

                                IdentificationNumber =
                                    GetNullableString(
                                        reader,
                                        "IPCODPACI"),

                                AdmissionNumber =
                                    GetNullableString(
                                        reader,
                                        "NUMINGRES"),

                                Bed =
                                    GetNullableInt32(
                                        reader,
                                        "CODICAMAS"),

                                PreviousBed =
                                    GetNullableInt32(
                                        reader,
                                        "CODICAMAS_PREVIOUSLY"),

                                NewBed =
                                    GetNullableInt32(
                                        reader,
                                        "CODICAMAS_AFTER"),

                                OriginBed =
                                    GetNullableInt32(
                                        reader,
                                        "CODICAORI"),

                                DestinationBed =
                                    GetNullableInt32(
                                        reader,
                                        "CODICADES"),

                                TransferConsecutive =
                                    GetNullableInt32(
                                        reader,
                                        "CODCONCEC"),

                                PreviousValue =
                                    GetNullableString(
                                        reader,
                                        "PreviousValue"),

                                NewValue =
                                    GetNullableString(
                                        reader,
                                        "NewValue"),

                                Detail =
                                    GetNullableString(
                                        reader,
                                        "Detail")
                            });
                    }
                }

                // The DataReader must be completely disposed before committing.
                await transaction.CommitAsync(
                    cancellationToken);

                return events;
            });
    }

    public async Task MarkSentAsync(
        string database,
        long id,
        string? response,
        CancellationToken cancellationToken)
    {
        var options =
            BuildDbContextOptions(database);

        await using var db =
            new HospitalizationDbContext(options);

        var affected =
            await db.HospitalizationReconciliationAudit
                .Where(x =>
                    x.Id == id &&
                    x.NewRelicStatus == "PROCESSING")
                .ExecuteUpdateAsync(
                    setters => setters
                        .SetProperty(
                            x => x.NewRelicStatus,
                            "SENT")
                        .SetProperty(
                            x => x.NewRelicSentAt,
                            DateTime.UtcNow)
                        .SetProperty(
                            x => x.NewRelicProcessingAt,
                            (DateTime?)null)
                        .SetProperty(
                            x => x.NewRelicResponse,
                            TruncateResponse(response)),
                    cancellationToken);

        if (affected == 0)
        {
            throw new InvalidOperationException(
                $"Audit record {id} could not be marked as SENT because it is no longer in PROCESSING state.");
        }
    }

    public async Task MarkErrorAsync(
        string database,
        long id,
        string? response,
        CancellationToken cancellationToken)
    {
        var options =
            BuildDbContextOptions(database);

        await using var db =
            new HospitalizationDbContext(options);

        var affected =
            await db.HospitalizationReconciliationAudit
                .Where(x =>
                    x.Id == id &&
                    x.NewRelicStatus == "PROCESSING")
                .ExecuteUpdateAsync(
                    setters => setters
                        .SetProperty(
                            x => x.NewRelicStatus,
                            "ERROR")
                        .SetProperty(
                            x => x.NewRelicProcessingAt,
                            (DateTime?)null)
                        .SetProperty(
                            x => x.NewRelicResponse,
                            TruncateResponse(response)),
                    cancellationToken);

        if (affected == 0)
        {
            throw new InvalidOperationException(
                $"Audit record {id} could not be marked as ERROR because it is no longer in PROCESSING state.");
        }
    }

    private async Task RecoverStaleProcessingAsync(
        HospitalizationDbContext db,
        DateTime now,
        CancellationToken cancellationToken)
    {
        var timeout =
            now.AddMinutes(
                -ProcessingTimeoutMinutes);

        await db.HospitalizationReconciliationAudit
            .Where(x =>
                x.NewRelicStatus == "PROCESSING" &&
                x.NewRelicProcessingAt != null &&
                x.NewRelicProcessingAt < timeout)
            .ExecuteUpdateAsync(
                setters => setters
                    .SetProperty(
                        x => x.NewRelicStatus,
                        "ERROR")
                    .SetProperty(
                        x => x.NewRelicProcessingAt,
                        (DateTime?)null)
                    .SetProperty(
                        x => x.NewRelicResponse,
                        "Recovered from PROCESSING timeout"),
                cancellationToken);
    }

    private DbContextOptions<HospitalizationDbContext>
        BuildDbContextOptions(
            string database)
    {
        var connectionString =
            BuildConnectionString(database);

        return new DbContextOptionsBuilder<
            HospitalizationDbContext>()
            .UseSqlServer(
                connectionString,
                sqlServerOptions =>
                {
                    sqlServerOptions.CommandTimeout(60);

                    sqlServerOptions.EnableRetryOnFailure(
                        maxRetryCount: 3,
                        maxRetryDelay:
                            TimeSpan.FromSeconds(5),
                        errorNumbersToAdd: null);
                })
            .Options;
    }

    private string BuildConnectionString(
        string database)
    {
        var builder =
            new SqlConnectionStringBuilder
            {
                DataSource = _server,
                InitialCatalog = database,
                UserID = _userId,
                Password = _password,
                ConnectTimeout = 30
            };

        return builder.ConnectionString;
    }

    private static string? GetNullableString(
        DbDataReader reader,
        string column)
    {
        var ordinal =
            reader.GetOrdinal(column);

        return reader.IsDBNull(ordinal)
            ? null
            : reader.GetString(ordinal);
    }

    private static int? GetNullableInt32(
        DbDataReader reader,
        string column)
    {
        var ordinal =
            reader.GetOrdinal(column);

        return reader.IsDBNull(ordinal)
            ? null
            : reader.GetInt32(ordinal);
    }

    private static DateTime? GetNullableDateTime(
        DbDataReader reader,
        string column)
    {
        var ordinal =
            reader.GetOrdinal(column);

        return reader.IsDBNull(ordinal)
            ? null
            : reader.GetDateTime(ordinal);
    }

    private static string? TruncateResponse(
        string? response)
    {
        if (string.IsNullOrEmpty(response))
        {
            return response;
        }

        return response.Length <= 4000
            ? response
            : response[..4000];
    }
}