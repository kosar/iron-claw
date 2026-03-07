# Engineering Hand-off: Shopify Nexus + Chatsi Integration

**To:** Chatsi AI Engineering Leader
**From:** IronClaw / OpenClaw Integration Team
**Date:** 2026-02-14
**Re:** Completing the Genius API integration — what we need from your side

---

Hey,

The Shopify Nexus skill is built, tested against live MCP endpoints, and deployed. The Shopify-side pipeline (MCP discovery, catalog search, policy lookup, domain resolution, fallback to products.json, persistent learning) is fully operational and running in production on our IronClaw gateway.

The Chatsi Genius integration is wired up end-to-end — auth flow, payload construction, response parsing, graceful degradation — but it's currently running in **offline fallback mode** because we're missing the credentials to actually hit your API. The skill handles this cleanly (the agent does its own product analysis when Genius is unavailable), but we obviously want the real thing.

## What We Need

Here are the specific placeholders that need to be filled. Everything is configured via environment variables in our `.env` file:

### Required (minimum to get Genius working)

| Variable | What it is | Current state |
|----------|-----------|---------------|
| `CHATSI_MERCHANT_ID` | Our merchant/tenant identifier in your system | **Empty** — we need you to provision this |
| `CHATSI_API_KEY` | API key for authenticating requests to Genius | **Empty** — or provide OAuth2 credentials instead (see below) |
| `CHATSI_SUBSCRIPTION_KEY` | Azure APIM subscription key (if your API is fronted by Azure API Management) | **Empty** — may not be needed depending on your setup |

### Alternative: OAuth2 Authentication

If you use OAuth2 client credentials instead of a static API key, we support that too. We'd need:

| Variable | What it is |
|----------|-----------|
| `CHATSI_ACCESS_TOKEN_URL` | Token endpoint URL (e.g., `https://login.chatsi.ai/oauth2/token`) |
| `CHATSI_API_CLIENT_ID` | OAuth2 client ID |
| `CHATSI_API_CLIENT_SECRET` | OAuth2 client secret |
| `CHATSI_API_CLIENT_SCOPE` | Required scope(s) for the Genius API |

Either auth path works — our script (`chatsi-genius.sh`) auto-detects which credentials are present and uses the appropriate flow. OAuth2 takes precedence if both are configured.

### Already Configured

| Variable | Status |
|----------|--------|
| `CHATSI_API_URL` | Set to `https://api.chatsi.ai` — let us know if this base URL is wrong or if there's a staging endpoint we should hit first |

## How the Credentials Get Used

Once populated, here's the flow:

1. **Auth** — The script either uses the API key directly (`ApiKey: {key}` header) or performs an OAuth2 client_credentials grant to get a bearer token.
2. **Request** — A POST to `{CHATSI_API_URL}/genius/chat?merchantId={CHATSI_MERCHANT_ID}` with a JSON payload containing the user query, top product context from Shopify MCP, and session metadata.
3. **Response** — We parse the `response` (analysis text), `followup_question` (suggested next questions), and `products` (any Genius-curated product list) from your JSON response.
4. **Fallback** — If auth fails, the endpoint is unreachable, or the response is non-JSON, we gracefully degrade to agent-only analysis. No user-facing errors, no retries hammering your API.

## What We Can't Fully Test Until We Have Credentials

- **Response format validation** — We built our parser against your documented schema (`response`, `followup_question`, `products` fields). If the actual response structure differs, we'll need to adjust.
- **Rate limits and quotas** — We don't know your rate limit policy. Our skill logs every Genius call, so we can throttle on our side if needed. Let us know if there are limits we should respect.
- **Merchant-specific behavior** — If Genius tailors responses based on merchant configuration (product catalog scope, tone, branding), we won't see that behavior until we have a real merchant ID.
- **OAuth2 token lifecycle** — If using OAuth2, we currently fetch a fresh token per request. If tokens are long-lived and you'd prefer we cache them, let us know the TTL.

## Next Steps

1. You provision a merchant ID and auth credentials for us (sandbox/staging is fine to start).
2. We plug them in, run the full pipeline against a few known Shopify stores, and verify end-to-end.
3. We share the structured logs from those test runs so you can validate the payloads and responses look right on your end.
4. Once confirmed, we flip to production credentials and it's live.

The integration code is solid — it's really just a credentials handshake away from being fully operational. Happy to jump on a call or async in whatever channel works for you.

Cheers.
