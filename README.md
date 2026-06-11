# AX Hub Ruby SDK

AX Hub Ruby SDK for `https://api.axhub.ai`. It gives agents a dependency-light client, generated backend route metadata, bounded-context operation clients, typed error metadata, conformance tests, and a live-testable app/data workflow.

## Install

```bash
gem install axhub-sdk -v 0.3.1
```

Local development:

```bash
bundle install
ruby -Ilib test/client_test.rb
```

## Required environment for agent work

```bash
export AXHUB_TOKEN="<short-lived PAT>"
export AXHUB_TENANT_ID="cc1e58f1-8e46-4ac7-96c1-190c4cdd5b70"   # test tenant
export AXHUB_TENANT_SLUG="test"
```

PAT mode is explicit: `token_type: :pat` sends `X-Api-Key`. JWT mode is `token_type: :jwt` and sends `Authorization: Bearer`.

## Agent quickstart: create a disposable app and table

```ruby
require 'axhub_sdk'

client = AxHub::Client.new(
  base_url: 'https://api.axhub.ai',
  token: ENV.fetch('AXHUB_TOKEN'),
  token_type: :pat,
  default_tenant_id: ENV.fetch('AXHUB_TENANT_ID'),
  default_tenant_slug: ENV.fetch('AXHUB_TENANT_SLUG', 'test')
)

me = client.request('authGetApiV1Me')
user_id = me['userId'] || (me['user'] || {})['id']
raise 'authGetApiV1Me did not return a user id' if user_id.nil? || user_id.empty?

suffix = (Time.now.to_f * 1000).to_i.to_s[-8, 8]
slug = "agent-rb-#{suffix}"
table = "items#{suffix[-6, 6]}"

app = client.apps.create(
  slug: slug,
  name: 'Agent Ruby README QA',
  visibility: 'private',
  auth_mode: 'anonymous',
  resource_preset: 'S',
  deploy_method: 'docker',
  subdomain: slug
)
app_id = app['id']

client.request(
  'schemaPostApiV1AppsByAppIDTables',
  path_params: { appID: app_id },
  body: {
    table_name: table,
    owner_column: 'owner_id',
    columns: [
      { name: 'owner_id', type: 'uuid', nullable: false },
      { name: 'title', type: 'text', nullable: false },
      { name: 'status', type: 'text', nullable: false }
    ]
  }
)

row = client.request(
  'schemaPostDataByTenantSlugByAppSlugByTable',
  path_params: { tenantSlug: 'test', appSlug: slug, table: table },
  body: { owner_id: user_id, title: 'hello', status: 'new' }
)
puts "created #{app_id} #{table} #{row['id']}"
```

## How to call the full API surface

- High-level app create: `client.apps.create(**body)` uses `default_tenant_id`.
- Any route by operation id: `client.request(operation_id, path_params: {}, query: {}, body: nil)`.
- Generated facade: `client.data.schema_post_data_by_tenant_slug_by_app_slug_by_table(path_params: {}, body: {...})`.
- Route inventory: `AxHub::ROUTES`, `AxHub::CONTEXT_ROUTES`, `AxHub::ERROR_CODES`, and `AxHub::OPERATION_METHODS`.
- Errors: catch `AxHub::Error` and branch on `code`, `category`, `status`, and `retryable`.

## Dynamic app, schema, and data operations

Use the high-level `apps.create` helper for the first app, then use generated operation IDs for every backend route. Request bodies use backend wire keys, usually `snake_case`. Responses are normalized to camelCase in this SDK family, so read `tableName`, `requestId`, `revokedAt`, and similar keys from responses.

| Task | Operation ID | Required path params | Success assertion |
|------|--------------|----------------------|-------------------|
| Create env var | `appsPostApiV1AppsByAppIDEnvVars` | `appID` | `env.list` includes `key` |
| Delete env var | `appsDeleteApiV1AppsByAppIDEnvVarsByKey` | `appID`, `key` | `env.list` no longer includes `key` |
| Create table | `schemaPostApiV1AppsByAppIDTables` | `appID` | response `tableName` equals requested name |
| Inspect table | `schemaGetApiV1AppsByAppIDTablesByTableName` | `appID`, `tableName` | response `id` and `tableName` match |
| Add column | `schemaPostApiV1AppsByAppIDTablesByTableNameColumns` | `appID`, `tableName` | inspect contains column name |
| Drop column | `schemaDeleteApiV1AppsByAppIDTablesByTableNameColumnsByColumnName` | `appID`, `tableName`, `columnName` | inspect no longer contains column name |
| Add table grant | `schemaPostApiV1AppsByAppIDTablesByTableNameGrants` | `appID`, `tableName` | response has grant `id` |
| List grants | `schemaGetApiV1AppsByAppIDTablesByTableNameGrants` | `appID`, `tableName` | list contains grant `id` |
| Revoke/delete grant | `schemaDeleteApiV1AppsByAppIDTablesByTableNameGrantsByGrantID` | `appID`, `tableName`, `grantID` | list still contains grant with `revokedAt` set |
| Insert row | `schemaPostDataByTenantSlugByAppSlugByTable` | `tenantSlug`, `appSlug`, `table` | response has row `id` and submitted fields |
| Get row | `schemaGetDataByTenantSlugByAppSlugByTableById` | `tenantSlug`, `appSlug`, `table`, `id` | response row `id` matches |
| Update row | `schemaPatchDataByTenantSlugByAppSlugByTableById` | `tenantSlug`, `appSlug`, `table`, `id` | response contains patched fields |
| List rows | `schemaGetDataByTenantSlugByAppSlugByTable` | `tenantSlug`, `appSlug`, `table` | `items` contains row `id` |
| Count rows | `schemaGetDataByTenantSlugByAppSlugByTableCount` | `tenantSlug`, `appSlug`, `table` | `count` matches expected fixture count |
| Browse admin rows | `schemaGetApiV1AppsByAppIDTablesByTableNameRows` | `appID`, `tableName` | response has `rows` and `columns` arrays |
| Delete row | `schemaDeleteDataByTenantSlugByAppSlugByTableById` | `tenantSlug`, `appSlug`, `table`, `id` | follow-up get returns `404` or `410` |
| Delete table | `schemaDeleteApiV1AppsByAppIDTablesByTableName` | `appID`, `tableName` | follow-up inspect returns `404` or `410` |
| Delete app | `appsDeleteApiV1AppsByAppID`, then `appsDeleteApiV1AppsByAppIDPermanent` | `appID` | app is soft-deleted, then permanently deleted |

Important semantics from live QA:

- Row delete is hard enough for client assertions: a follow-up row get returns `404 not_found` or `410`.
- Table delete is hard enough for client assertions: a follow-up table inspect returns `404 not_found` or `410`.
- Table grant delete is a soft revoke: the grant can remain in `listGrants`, but the same grant id must have `revokedAt` set. Do not assert disappearance.
- Deployment creation without a connected git/bootstrap source can return a precondition-style 4xx. That verifies SDK error handling, not a deploy bug.


## Live QA evidence agents can trust

The SDK behavior documented here reflects live production QA against the AX Hub `test` tenant on 2026-06-08.

- Tenant used for destructive QA: slug `test`, id `cc1e58f1-8e46-4ac7-96c1-190c4cdd5b70`.
- Go, Java, Kotlin, Python, and Ruby each ran the generated all-operation sweep against 189 backend routes: SDK exceptions `0`, backend 5xx `0`.
- Go, Java, Kotlin, Python, and Ruby each passed strict destructive DB QA: 22 live steps, 17 assertions, 7 cleanup calls. The flow created an app, env var, table, column, table grant, row, then updated, listed, counted, browsed, deleted, and re-read to prove deletion semantics.
- Node ran the full production mutation suite and a real app bootstrap/deploy wait. Deployment id `d3a48ce3-0f9c-4bab-aa07-863c31c44460` finished `succeeded`, then the app was deleted permanently.

Do not print tokens. Use short-lived PATs for agent QA and revoke them after the run.


## Verification commands

Use local tests for every docs/code change. Run live tests only when you intentionally want destructive QA against `test`.


```bash
ruby -Ilib test/client_test.rb

# Destructive live all-operation sweep, only with a disposable PAT.
AXHUB_LIVE_ALL_METHODS=1 \
AXHUB_TOKEN="$AXHUB_TOKEN" \
AXHUB_LIVE_TENANT_ID="$AXHUB_TENANT_ID" \
AXHUB_LIVE_TENANT_SLUG="$AXHUB_TENANT_SLUG" \
ruby test/live_all_operations_e2e_test.rb
```

## Troubleshooting for agents

- `tenant_id_required`: pass `defaultTenantId` / `AXHUB_TENANT_ID` before calling `apps.create`.
- `tokenType must be explicit`: set PAT mode when using a PAT. PATs are sent as `X-Api-Key`; JWTs are sent as `Authorization: Bearer`.
- `slug_taken` or `schema_name_taken`: append a timestamp suffix and retry. Never reuse fixture names in live destructive QA.
- `permission_denied` / `not_admin`: the SDK is working. The token lacks the role for that route.
- `precondition_failed` on deploy: connect git or use the app bootstrap flow first.
- 4xx responses are expected for negative assertions. SDK bugs are unexpected exceptions, response decode failures, or backend 5xx during a valid call.


## Release

See `RELEASE.md` for tag order, environment approvals, registry prerequisites, and smoke-test handling.

## License

Apache-2.0.
