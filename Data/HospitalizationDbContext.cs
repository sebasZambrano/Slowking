using Slowking.Entities;
using Microsoft.EntityFrameworkCore;

namespace Slowking.Data;

public sealed class HospitalizationDbContext : DbContext
{
    public HospitalizationDbContext(
        DbContextOptions<HospitalizationDbContext> options)
        : base(options)
    {
    }

    public DbSet<HospitalizationReconciliationAudit>
        HospitalizationReconciliationAudit
        => Set<HospitalizationReconciliationAudit>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        var entity =
            modelBuilder.Entity<HospitalizationReconciliationAudit>();

        entity.ToTable(
            "HospitalizationReconciliationAudit",
            "Beds");

        entity.HasKey(x => x.Id);

        entity.Property(x => x.Id)
            .HasColumnName("Id")
            .ValueGeneratedOnAdd();

        entity.Property(x => x.Container)
            .HasColumnName("Container")
            .HasMaxLength(50)
            .IsRequired();

        entity.Property(x => x.CreatedAt)
            .HasColumnName("CreatedAt")
            .HasColumnType("datetime")
            .IsRequired();

        entity.Property(x => x.StartExecution)
            .HasColumnName("StartExecution")
            .HasColumnType("datetime")
            .IsRequired();

        entity.Property(x => x.EndExecution)
            .HasColumnName("EndExecution")
            .HasColumnType("datetime");

        entity.Property(x => x.Rule)
            .HasColumnName("Rule")
            .IsRequired();

        entity.Property(x => x.RuleDescription)
            .HasColumnName("RuleDescription")
            .HasMaxLength(255)
            .IsRequired();

        entity.Property(x => x.Action)
            .HasColumnName("Action")
            .HasMaxLength(50)
            .IsRequired();

        entity.Property(x => x.IPCODPACI)
            .HasColumnName("IPCODPACI")
            .HasMaxLength(25);

        entity.Property(x => x.NUMINGRES)
            .HasColumnName("NUMINGRES")
            .HasColumnType("char(10)");

        entity.Property(x => x.CODICAMAS)
            .HasColumnName("CODICAMAS");

        entity.Property(x => x.CODICAMAS_PREVIOUSLY)
            .HasColumnName("CODICAMAS_PREVIOUSLY");

        entity.Property(x => x.CODICAMAS_AFTER)
            .HasColumnName("CODICAMAS_AFTER");

        entity.Property(x => x.CODICAORI)
            .HasColumnName("CODICAORI");

        entity.Property(x => x.CODICADES)
            .HasColumnName("CODICADES");

        entity.Property(x => x.CODCONCEC)
            .HasColumnName("CODCONCEC");

        entity.Property(x => x.PreviousValue)
            .HasColumnName("PreviousValue")
            .HasMaxLength(255);

        entity.Property(x => x.NewValue)
            .HasColumnName("NewValue")
            .HasMaxLength(255);

        entity.Property(x => x.Detail)
            .HasColumnName("Detail")
            .HasMaxLength(255);

        entity.Property(x => x.NewRelicStatus)
            .HasColumnName("NewRelicStatus")
            .HasMaxLength(50);

        entity.Property(x => x.NewRelicAttempts)
            .HasColumnName("NewRelicAttempts");

        entity.Property(x => x.NewRelicProcessingAt)
            .HasColumnName("NewRelicProcessingAt")
            .HasColumnType("datetime");

        entity.Property(x => x.NewRelicSentAt)
            .HasColumnName("NewRelicSentAt")
            .HasColumnType("datetime");

        entity.Property(x => x.NewRelicResponse)
            .HasColumnName("NewRelicResponse")
            .HasMaxLength(100);
    }
}