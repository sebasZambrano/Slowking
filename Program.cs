using HospitalizationReconciliationNewRelic.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices(services =>
    {
        services.AddSingleton<HospitalizationAuditService>();

        services.AddHttpClient();
    })
    .Build();

host.Run();