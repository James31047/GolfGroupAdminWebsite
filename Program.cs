
WebApplicationBuilder builder = WebApplication.CreateBuilder(args);

builder.CreateUmbracoBuilder()
    .AddBackOffice()
    .AddWebsite()
    .AddComposers()
    .Build();

// HTTPS is terminated by IIS on 443 in production. Stating the port explicitly
// avoids the "Failed to determine the https port for redirect" warning, which
// otherwise makes UseHttpsRedirection silently do nothing.
if (builder.Environment.IsProduction())
{
    builder.Services.AddHttpsRedirection(options =>
    {
        options.HttpsPort = 443;
        // 301 rather than the default 307. A temporary redirect tells search
        // engines to keep indexing the http URLs; a permanent one consolidates
        // ranking signals onto https.
        options.RedirectStatusCode = StatusCodes.Status301MovedPermanently;
    });
    builder.Services.AddHsts(options =>
    {
        // Deliberately conservative to start. HSTS is sticky - browsers cache it -
        // so a short max-age limits the blast radius if a renewal ever fails.
        // Raise to 365 days once renewals have proven themselves.
        options.MaxAge = TimeSpan.FromDays(30);
        options.IncludeSubDomains = false;
        options.Preload = false;
    });
}

WebApplication app = builder.Build();

await app.BootUmbracoAsync();

// Production only, so local development over http://localhost keeps working.
// This lives in code rather than a web.config rewrite rule because the deploy
// regenerates web.config on every publish and would wipe the rule.
if (app.Environment.IsProduction())
{
    app.UseHsts();
    app.UseHttpsRedirection();
}

app.UseUmbraco()
    .WithMiddleware(u =>
    {
        u.UseBackOffice();
        u.UseWebsite();
    })
    .WithEndpoints(u =>
    {
        u.UseBackOfficeEndpoints();
        u.UseWebsiteEndpoints();
    });

await app.RunAsync();
