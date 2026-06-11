# frozen_string_literal: true
require 'json'
require 'net/http'
require 'securerandom'
require 'time'
require 'uri'
require_relative 'axhub_sdk/version'

module AxHub
  DEFAULT_BASE_URL = 'https://api.axhub.ai'
  ErrorInfo = Struct.new(:category, :status, :retryable, keyword_init: false)
  class Error < StandardError
    attr_reader :category, :code, :status, :retryable, :request_id
    def initialize(category:, code:, message: nil, status: 0, retryable: false, request_id: nil)
      super(message || code); @category = category; @code = code; @status = status; @retryable = retryable; @request_id = request_id
    end
  end
  ROUTES = [
    { 'method' => "GET", 'path' => "/.well-known/jwks.json", 'tag' => "Auth", 'operationId' => "authGetWellKnownJwksJson" },
    { 'method' => "GET", 'path' => "/.well-known/oauth-authorization-server", 'tag' => "Auth", 'operationId' => "authGetWellKnownOauthAuthorizationServer" },
    { 'method' => "GET", 'path' => "/.well-known/openid-configuration", 'tag' => "Auth", 'operationId' => "authGetWellKnownOpenidConfiguration" },
    { 'method' => "GET", 'path' => "/api/v1/admin/templates", 'tag' => "Apps", 'operationId' => "appsGetApiV1AdminTemplates" },
    { 'method' => "POST", 'path' => "/api/v1/admin/templates", 'tag' => "Apps", 'operationId' => "appsPostApiV1AdminTemplates" },
    { 'method' => "GET", 'path' => "/api/v1/admin/templates/{templateID}", 'tag' => "Apps", 'operationId' => "appsGetApiV1AdminTemplatesByTemplateID" },
    { 'method' => "PATCH", 'path' => "/api/v1/admin/templates/{templateID}", 'tag' => "Apps", 'operationId' => "appsPatchApiV1AdminTemplatesByTemplateID" },
    { 'method' => "POST", 'path' => "/api/v1/admin/users/{uid}/revoke-all", 'tag' => "Auth", 'operationId' => "authPostApiV1AdminUsersByUidRevokeAll" },
    { 'method' => "DELETE", 'path' => "/api/v1/apps/{appID}", 'tag' => "Apps", 'operationId' => "appsDeleteApiV1AppsByAppID" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}", 'tag' => "Apps", 'operationId' => "appsGetApiV1AppsByAppID" },
    { 'method' => "PATCH", 'path' => "/api/v1/apps/{appID}", 'tag' => "Apps", 'operationId' => "appsPatchApiV1AppsByAppID" },
    { 'method' => "DELETE", 'path' => "/api/v1/apps/{appID}/access", 'tag' => "Apps", 'operationId' => "appsDeleteApiV1AppsByAppIDAccess" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/access", 'tag' => "Apps", 'operationId' => "appsPostApiV1AppsByAppIDAccess" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/access/me", 'tag' => "Apps", 'operationId' => "appsGetApiV1AppsByAppIDAccessMe" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/comments", 'tag' => "Apps", 'operationId' => "appsGetApiV1AppsByAppIDComments" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/comments", 'tag' => "Apps", 'operationId' => "appsPostApiV1AppsByAppIDComments" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/deployments", 'tag' => "Deploy", 'operationId' => "deployGetApiV1AppsByAppIDDeployments" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/deployments", 'tag' => "Deploy", 'operationId' => "deployPostApiV1AppsByAppIDDeployments" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/deployments/{did}", 'tag' => "Deploy", 'operationId' => "deployGetApiV1AppsByAppIDDeploymentsByDid" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/deployments/{did}/cancel", 'tag' => "Deploy", 'operationId' => "deployPostApiV1AppsByAppIDDeploymentsByDidCancel" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/deployments/{did}/rollback", 'tag' => "Deploy", 'operationId' => "deployPostApiV1AppsByAppIDDeploymentsByDidRollback" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/env-vars", 'tag' => "Apps", 'operationId' => "appsGetApiV1AppsByAppIDEnvVars" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/env-vars", 'tag' => "Apps", 'operationId' => "appsPostApiV1AppsByAppIDEnvVars" },
    { 'method' => "DELETE", 'path' => "/api/v1/apps/{appID}/env-vars/{key}", 'tag' => "Apps", 'operationId' => "appsDeleteApiV1AppsByAppIDEnvVarsByKey" },
    { 'method' => "DELETE", 'path' => "/api/v1/apps/{appID}/git-connection", 'tag' => "Deploy", 'operationId' => "deployDeleteApiV1AppsByAppIDGitConnection" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/git-connection", 'tag' => "Deploy", 'operationId' => "deployGetApiV1AppsByAppIDGitConnection" },
    { 'method' => "PATCH", 'path' => "/api/v1/apps/{appID}/git-connection", 'tag' => "Deploy", 'operationId' => "deployPatchApiV1AppsByAppIDGitConnection" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/git-connection", 'tag' => "Deploy", 'operationId' => "deployPostApiV1AppsByAppIDGitConnection" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/git/github/install/start", 'tag' => "Deploy", 'operationId' => "deployGetApiV1AppsByAppIDGitGithubInstallStart" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/icon-dark/upload-url", 'tag' => "Apps", 'operationId' => "appsPostApiV1AppsByAppIDIconDarkUploadUrl" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/icon/upload-url", 'tag' => "Apps", 'operationId' => "appsPostApiV1AppsByAppIDIconUploadUrl" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/invitations", 'tag' => "Apps", 'operationId' => "appsPostApiV1AppsByAppIDInvitations" },
    { 'method' => "DELETE", 'path' => "/api/v1/apps/{appID}/invitations/{userID}", 'tag' => "Apps", 'operationId' => "appsDeleteApiV1AppsByAppIDInvitationsByUserID" },
    { 'method' => "DELETE", 'path' => "/api/v1/apps/{appID}/likes", 'tag' => "Apps", 'operationId' => "appsDeleteApiV1AppsByAppIDLikes" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/likes", 'tag' => "Apps", 'operationId' => "appsPostApiV1AppsByAppIDLikes" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/likes/me", 'tag' => "Apps", 'operationId' => "appsGetApiV1AppsByAppIDLikesMe" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/logs", 'tag' => "Deploy", 'operationId' => "deployGetApiV1AppsByAppIDLogs" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/members", 'tag' => "Apps", 'operationId' => "appsGetApiV1AppsByAppIDMembers" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/oauth-clients", 'tag' => "Auth", 'operationId' => "authPostApiV1AppsByAppIDOauthClients" },
    { 'method' => "DELETE", 'path' => "/api/v1/apps/{appID}/permanent", 'tag' => "Apps", 'operationId' => "appsDeleteApiV1AppsByAppIDPermanent" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/resume", 'tag' => "Apps", 'operationId' => "appsPostApiV1AppsByAppIDResume" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/review-requests", 'tag' => "Apps", 'operationId' => "appsGetApiV1AppsByAppIDReviewRequests" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/review-requests", 'tag' => "Apps", 'operationId' => "appsPostApiV1AppsByAppIDReviewRequests" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/suspend", 'tag' => "Apps", 'operationId' => "appsPostApiV1AppsByAppIDSuspend" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/tables", 'tag' => "Schema", 'operationId' => "schemaGetApiV1AppsByAppIDTables" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/tables", 'tag' => "Schema", 'operationId' => "schemaPostApiV1AppsByAppIDTables" },
    { 'method' => "DELETE", 'path' => "/api/v1/apps/{appID}/tables/{tableName}", 'tag' => "Schema", 'operationId' => "schemaDeleteApiV1AppsByAppIDTablesByTableName" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/tables/{tableName}", 'tag' => "Schema", 'operationId' => "schemaGetApiV1AppsByAppIDTablesByTableName" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/tables/{tableName}/columns", 'tag' => "Schema", 'operationId' => "schemaPostApiV1AppsByAppIDTablesByTableNameColumns" },
    { 'method' => "DELETE", 'path' => "/api/v1/apps/{appID}/tables/{tableName}/columns/{columnName}", 'tag' => "Schema", 'operationId' => "schemaDeleteApiV1AppsByAppIDTablesByTableNameColumnsByColumnName" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/tables/{tableName}/grants", 'tag' => "Schema", 'operationId' => "schemaGetApiV1AppsByAppIDTablesByTableNameGrants" },
    { 'method' => "POST", 'path' => "/api/v1/apps/{appID}/tables/{tableName}/grants", 'tag' => "Schema", 'operationId' => "schemaPostApiV1AppsByAppIDTablesByTableNameGrants" },
    { 'method' => "DELETE", 'path' => "/api/v1/apps/{appID}/tables/{tableName}/grants/{grantID}", 'tag' => "Schema", 'operationId' => "schemaDeleteApiV1AppsByAppIDTablesByTableNameGrantsByGrantID" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/tables/{tableName}/rows", 'tag' => "Schema", 'operationId' => "schemaGetApiV1AppsByAppIDTablesByTableNameRows" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/tables/check-availability", 'tag' => "Schema", 'operationId' => "schemaGetApiV1AppsByAppIDTablesCheckAvailability" },
    { 'method' => "GET", 'path' => "/api/v1/apps/{appID}/tables/column-types", 'tag' => "Schema", 'operationId' => "schemaGetApiV1AppsByAppIDTablesColumnTypes" },
    { 'method' => "GET", 'path' => "/api/v1/apps/discover", 'tag' => "Apps", 'operationId' => "appsGetApiV1AppsDiscover" },
    { 'method' => "GET", 'path' => "/api/v1/apps/search", 'tag' => "Apps", 'operationId' => "appsGetApiV1AppsSearch" },
    { 'method' => "DELETE", 'path' => "/api/v1/comments/{commentID}", 'tag' => "Apps", 'operationId' => "appsDeleteApiV1CommentsByCommentID" },
    { 'method' => "GET", 'path' => "/api/v1/github/accounts", 'tag' => "deploy", 'operationId' => "deployGetApiV1GithubAccounts" },
    { 'method' => "GET", 'path' => "/api/v1/github/installations/{installationID}/repositories", 'tag' => "deploy", 'operationId' => "deployGetApiV1GithubInstallationsByInstallationIDRepositories" },
    { 'method' => "GET", 'path' => "/api/v1/invite-links/{token}", 'tag' => "Tenants", 'operationId' => "tenantsGetApiV1InviteLinksByToken" },
    { 'method' => "POST", 'path' => "/api/v1/invite-links/{token}/accept", 'tag' => "Tenants", 'operationId' => "tenantsPostApiV1InviteLinksByTokenAccept" },
    { 'method' => "GET", 'path' => "/api/v1/me", 'tag' => "Auth", 'operationId' => "authGetApiV1Me" },
    { 'method' => "GET", 'path' => "/api/v1/me/apps/owned", 'tag' => "Apps", 'operationId' => "appsGetApiV1MeAppsOwned" },
    { 'method' => "GET", 'path' => "/api/v1/me/apps/received", 'tag' => "Apps", 'operationId' => "appsGetApiV1MeAppsReceived" },
    { 'method' => "GET", 'path' => "/api/v1/me/apps/workspace", 'tag' => "Apps", 'operationId' => "appsGetApiV1MeAppsWorkspace" },
    { 'method' => "POST", 'path' => "/api/v1/me/invitations/{invitationID}/accept", 'tag' => "Auth", 'operationId' => "authPostApiV1MeInvitationsByInvitationIDAccept" },
    { 'method' => "GET", 'path' => "/api/v1/me/personal-access-tokens", 'tag' => "Schema", 'operationId' => "schemaGetApiV1MePersonalAccessTokens" },
    { 'method' => "POST", 'path' => "/api/v1/me/personal-access-tokens", 'tag' => "Schema", 'operationId' => "schemaPostApiV1MePersonalAccessTokens" },
    { 'method' => "DELETE", 'path' => "/api/v1/me/personal-access-tokens/{patID}", 'tag' => "Schema", 'operationId' => "schemaDeleteApiV1MePersonalAccessTokensByPatID" },
    { 'method' => "GET", 'path' => "/api/v1/oauth-clients/{clientID}", 'tag' => "Auth", 'operationId' => "authGetApiV1OauthClientsByClientID" },
    { 'method' => "DELETE", 'path' => "/api/v1/oauth/clients/{clientID}/grants/me", 'tag' => "Auth", 'operationId' => "authDeleteApiV1OauthClientsByClientIDGrantsMe" },
    { 'method' => "GET", 'path' => "/api/v1/resource-presets", 'tag' => "Apps", 'operationId' => "appsGetApiV1ResourcePresets" },
    { 'method' => "GET", 'path' => "/api/v1/review-requests/{rrID}", 'tag' => "Apps", 'operationId' => "appsGetApiV1ReviewRequestsByRrID" },
    { 'method' => "POST", 'path' => "/api/v1/review-requests/{rrID}/approve", 'tag' => "Apps", 'operationId' => "appsPostApiV1ReviewRequestsByRrIDApprove" },
    { 'method' => "POST", 'path' => "/api/v1/review-requests/{rrID}/reject", 'tag' => "Apps", 'operationId' => "appsPostApiV1ReviewRequestsByRrIDReject" },
    { 'method' => "GET", 'path' => "/api/v1/review-requests/history", 'tag' => "Apps", 'operationId' => "appsGetApiV1ReviewRequestsHistory" },
    { 'method' => "GET", 'path' => "/api/v1/review-requests/pending", 'tag' => "Apps", 'operationId' => "appsGetApiV1ReviewRequestsPending" },
    { 'method' => "GET", 'path' => "/api/v1/templates", 'tag' => "Apps", 'operationId' => "appsGetApiV1Templates" },
    { 'method' => "GET", 'path' => "/api/v1/tenants", 'tag' => "Tenants", 'operationId' => "tenantsGetApiV1Tenants" },
    { 'method' => "POST", 'path' => "/api/v1/tenants", 'tag' => "Tenants", 'operationId' => "tenantsPostApiV1Tenants" },
    { 'method' => "DELETE", 'path' => "/api/v1/tenants/{tenantID}", 'tag' => "Tenants", 'operationId' => "tenantsDeleteApiV1TenantsByTenantID" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}", 'tag' => "Tenants", 'operationId' => "tenantsGetApiV1TenantsByTenantID" },
    { 'method' => "PATCH", 'path' => "/api/v1/tenants/{tenantID}", 'tag' => "Tenants", 'operationId' => "tenantsPatchApiV1TenantsByTenantID" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/app-bootstraps", 'tag' => "Deploy", 'operationId' => "deployPostApiV1TenantsByTenantIDAppBootstraps" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/app-bootstraps/{bootstrapID}", 'tag' => "Deploy", 'operationId' => "deployGetApiV1TenantsByTenantIDAppBootstrapsByBootstrapID" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/apps", 'tag' => "Apps", 'operationId' => "appsGetApiV1TenantsByTenantIDApps" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/apps", 'tag' => "Apps", 'operationId' => "appsPostApiV1TenantsByTenantIDApps" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/apps/check-availability", 'tag' => "Apps", 'operationId' => "appsGetApiV1TenantsByTenantIDAppsCheckAvailability" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/apps/icon/upload-url", 'tag' => "Apps", 'operationId' => "appsPostApiV1TenantsByTenantIDAppsIconUploadUrl" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/audit-events", 'tag' => "Audit", 'operationId' => "auditGetApiV1TenantsByTenantIDAuditEvents" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/audit-events/{eventID}", 'tag' => "Audit", 'operationId' => "auditGetApiV1TenantsByTenantIDAuditEventsByEventID" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/audit-events/anonymize", 'tag' => "Audit", 'operationId' => "auditPostApiV1TenantsByTenantIDAuditEventsAnonymize" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/audit-events/integrity-check", 'tag' => "Audit", 'operationId' => "auditGetApiV1TenantsByTenantIDAuditEventsIntegrityCheck" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/categories", 'tag' => "Apps", 'operationId' => "appsGetApiV1TenantsByTenantIDCategories" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/categories", 'tag' => "Apps", 'operationId' => "appsPostApiV1TenantsByTenantIDCategories" },
    { 'method' => "DELETE", 'path' => "/api/v1/tenants/{tenantID}/categories/{categoryID}", 'tag' => "Apps", 'operationId' => "appsDeleteApiV1TenantsByTenantIDCategoriesByCategoryID" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/categories/{categoryID}", 'tag' => "Apps", 'operationId' => "appsGetApiV1TenantsByTenantIDCategoriesByCategoryID" },
    { 'method' => "PATCH", 'path' => "/api/v1/tenants/{tenantID}/categories/{categoryID}", 'tag' => "Apps", 'operationId' => "appsPatchApiV1TenantsByTenantIDCategoriesByCategoryID" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/connectors", 'tag' => "Gateway", 'operationId' => "gatewayGetApiV1TenantsByTenantIDConnectors" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/connectors", 'tag' => "Gateway", 'operationId' => "gatewayPostApiV1TenantsByTenantIDConnectors" },
    { 'method' => "DELETE", 'path' => "/api/v1/tenants/{tenantID}/connectors/{connectorID}", 'tag' => "Gateway", 'operationId' => "gatewayDeleteApiV1TenantsByTenantIDConnectorsByConnectorID" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/connectors/{connectorID}", 'tag' => "Gateway", 'operationId' => "gatewayGetApiV1TenantsByTenantIDConnectorsByConnectorID" },
    { 'method' => "PATCH", 'path' => "/api/v1/tenants/{tenantID}/connectors/{connectorID}", 'tag' => "Gateway", 'operationId' => "gatewayPatchApiV1TenantsByTenantIDConnectorsByConnectorID" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/connectors/{connectorID}/test-connection", 'tag' => "Gateway", 'operationId' => "gatewayPostApiV1TenantsByTenantIDConnectorsByConnectorIDTestConnection" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/cost/by-app", 'tag' => "Cost", 'operationId' => "costGetApiV1TenantsByTenantIDCostByApp" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/cost/by-cost-center", 'tag' => "Cost", 'operationId' => "costGetApiV1TenantsByTenantIDCostByCostCenter" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/cost/export", 'tag' => "Cost", 'operationId' => "costGetApiV1TenantsByTenantIDCostExport" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/cost/months", 'tag' => "Cost", 'operationId' => "costGetApiV1TenantsByTenantIDCostMonths" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/cost/summary", 'tag' => "Cost", 'operationId' => "costGetApiV1TenantsByTenantIDCostSummary" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/cost/timeseries", 'tag' => "Cost", 'operationId' => "costGetApiV1TenantsByTenantIDCostTimeseries" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/deployments", 'tag' => "Deploy", 'operationId' => "deployGetApiV1TenantsByTenantIDDeployments" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/discover/apps", 'tag' => "Apps", 'operationId' => "appsGetApiV1TenantsByTenantIDDiscoverApps" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/email-domains", 'tag' => "Tenants", 'operationId' => "tenantsGetApiV1TenantsByTenantIDEmailDomains" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/email-domains", 'tag' => "Tenants", 'operationId' => "tenantsPostApiV1TenantsByTenantIDEmailDomains" },
    { 'method' => "DELETE", 'path' => "/api/v1/tenants/{tenantID}/email-domains/{domain}", 'tag' => "Tenants", 'operationId' => "tenantsDeleteApiV1TenantsByTenantIDEmailDomainsByDomain" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/gateway/invoke", 'tag' => "Gateway", 'operationId' => "gatewayPostApiV1TenantsByTenantIDGatewayInvoke" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/gateway/query", 'tag' => "Gateway", 'operationId' => "gatewayPostApiV1TenantsByTenantIDGatewayQuery" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/gateway/sessions", 'tag' => "Gateway", 'operationId' => "gatewayPostApiV1TenantsByTenantIDGatewaySessions" },
    { 'method' => "DELETE", 'path' => "/api/v1/tenants/{tenantID}/gateway/sessions/{sessionID}", 'tag' => "Gateway", 'operationId' => "gatewayDeleteApiV1TenantsByTenantIDGatewaySessionsBySessionID" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/grants", 'tag' => "Authorization", 'operationId' => "authorizationGetApiV1TenantsByTenantIDGrants" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/grants", 'tag' => "Authorization", 'operationId' => "authorizationPostApiV1TenantsByTenantIDGrants" },
    { 'method' => "DELETE", 'path' => "/api/v1/tenants/{tenantID}/grants/{grantID}", 'tag' => "Authorization", 'operationId' => "authorizationDeleteApiV1TenantsByTenantIDGrantsByGrantID" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/grants/{grantID}", 'tag' => "Authorization", 'operationId' => "authorizationGetApiV1TenantsByTenantIDGrantsByGrantID" },
    { 'method' => "DELETE", 'path' => "/api/v1/tenants/{tenantID}/icon", 'tag' => "Tenants", 'operationId' => "tenantsDeleteApiV1TenantsByTenantIDIcon" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/icon/upload-url", 'tag' => "Tenants", 'operationId' => "tenantsPostApiV1TenantsByTenantIDIconUploadUrl" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/identity-providers", 'tag' => "Auth", 'operationId' => "authGetApiV1TenantsByTenantIDIdentityProviders" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/identity-providers", 'tag' => "Auth", 'operationId' => "authPostApiV1TenantsByTenantIDIdentityProviders" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/identity-providers/{providerID}/disable", 'tag' => "Auth", 'operationId' => "authPostApiV1TenantsByTenantIDIdentityProvidersByProviderIDDisable" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/identity-providers/{providerID}/enable", 'tag' => "Auth", 'operationId' => "authPostApiV1TenantsByTenantIDIdentityProvidersByProviderIDEnable" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/infra/apps/{appID}/usage-series", 'tag' => "Cost", 'operationId' => "costGetApiV1TenantsByTenantIDInfraAppsByAppIDUsageSeries" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/infra/usage", 'tag' => "Cost", 'operationId' => "costGetApiV1TenantsByTenantIDInfraUsage" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/invitations", 'tag' => "Tenants", 'operationId' => "tenantsGetApiV1TenantsByTenantIDInvitations" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/invitations", 'tag' => "Tenants", 'operationId' => "tenantsPostApiV1TenantsByTenantIDInvitations" },
    { 'method' => "DELETE", 'path' => "/api/v1/tenants/{tenantID}/invitations/{invitationID}", 'tag' => "Tenants", 'operationId' => "tenantsDeleteApiV1TenantsByTenantIDInvitationsByInvitationID" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/invitations/bulk", 'tag' => "Tenants", 'operationId' => "tenantsPostApiV1TenantsByTenantIDInvitationsBulk" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/invite-links", 'tag' => "Tenants", 'operationId' => "tenantsGetApiV1TenantsByTenantIDInviteLinks" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/invite-links", 'tag' => "Tenants", 'operationId' => "tenantsPostApiV1TenantsByTenantIDInviteLinks" },
    { 'method' => "DELETE", 'path' => "/api/v1/tenants/{tenantID}/invite-links/{linkID}", 'tag' => "Tenants", 'operationId' => "tenantsDeleteApiV1TenantsByTenantIDInviteLinksByLinkID" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/me/connectors", 'tag' => "Gateway", 'operationId' => "gatewayGetApiV1TenantsByTenantIDMeConnectors" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/me/connectors/{connectorID}/resources", 'tag' => "Gateway", 'operationId' => "gatewayGetApiV1TenantsByTenantIDMeConnectorsByConnectorIDResources" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/me/grants", 'tag' => "Authorization", 'operationId' => "authorizationGetApiV1TenantsByTenantIDMeGrants" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/members", 'tag' => "Tenants", 'operationId' => "tenantsGetApiV1TenantsByTenantIDMembers" },
    { 'method' => "PATCH", 'path' => "/api/v1/tenants/{tenantID}/members/{membershipID}", 'tag' => "Tenants", 'operationId' => "tenantsPatchApiV1TenantsByTenantIDMembersByMembershipID" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/members/{membershipID}/deactivate", 'tag' => "Tenants", 'operationId' => "tenantsPostApiV1TenantsByTenantIDMembersByMembershipIDDeactivate" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/members/{membershipID}/reactivate", 'tag' => "Tenants", 'operationId' => "tenantsPostApiV1TenantsByTenantIDMembersByMembershipIDReactivate" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/presets", 'tag' => "Authorization", 'operationId' => "authorizationGetApiV1TenantsByTenantIDPresets" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/presets", 'tag' => "Authorization", 'operationId' => "authorizationPostApiV1TenantsByTenantIDPresets" },
    { 'method' => "DELETE", 'path' => "/api/v1/tenants/{tenantID}/presets/{presetID}", 'tag' => "Authorization", 'operationId' => "authorizationDeleteApiV1TenantsByTenantIDPresetsByPresetID" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/presets/{presetID}", 'tag' => "Authorization", 'operationId' => "authorizationGetApiV1TenantsByTenantIDPresetsByPresetID" },
    { 'method' => "PATCH", 'path' => "/api/v1/tenants/{tenantID}/presets/{presetID}", 'tag' => "Authorization", 'operationId' => "authorizationPatchApiV1TenantsByTenantIDPresetsByPresetID" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/subjects", 'tag' => "Authorization", 'operationId' => "authorizationGetApiV1TenantsByTenantIDSubjects" },
    { 'method' => "POST", 'path' => "/api/v1/tenants/{tenantID}/subjects", 'tag' => "Authorization", 'operationId' => "authorizationPostApiV1TenantsByTenantIDSubjects" },
    { 'method' => "GET", 'path' => "/api/v1/tenants/{tenantID}/subjects/{subjectID}", 'tag' => "Authorization", 'operationId' => "authorizationGetApiV1TenantsByTenantIDSubjectsBySubjectID" },
    { 'method' => "GET", 'path' => "/api/v1/users/me/apps", 'tag' => "Apps", 'operationId' => "appsGetApiV1UsersMeApps" },
    { 'method' => "GET", 'path' => "/auth/{providerID}/start", 'tag' => "Auth", 'operationId' => "authGetAuthByProviderIDStart" },
    { 'method' => "GET", 'path' => "/auth/github", 'tag' => "identity", 'operationId' => "identityGetAuthGithub" },
    { 'method' => "GET", 'path' => "/auth/github/callback", 'tag' => "identity", 'operationId' => "identityGetAuthGithubCallback" },
    { 'method' => "GET", 'path' => "/auth/google_oauth2/callback", 'tag' => "Auth", 'operationId' => "authGetAuthGoogleOauth2Callback" },
    { 'method' => "GET", 'path' => "/auth/google_oauth2/start", 'tag' => "Auth", 'operationId' => "authGetAuthGoogleOauth2Start" },
    { 'method' => "POST", 'path' => "/auth/logout", 'tag' => "Auth", 'operationId' => "authPostAuthLogout" },
    { 'method' => "GET", 'path' => "/auth/oidc/callback", 'tag' => "Auth", 'operationId' => "authGetAuthOidcCallback" },
    { 'method' => "GET", 'path' => "/auth/providers", 'tag' => "Auth", 'operationId' => "authGetAuthProviders" },
    { 'method' => "POST", 'path' => "/auth/refresh", 'tag' => "Auth", 'operationId' => "authPostAuthRefresh" },
    { 'method' => "GET", 'path' => "/auth/silent/callback", 'tag' => "Auth", 'operationId' => "authGetAuthSilentCallback" },
    { 'method' => "GET", 'path' => "/auth/silent/start", 'tag' => "Auth", 'operationId' => "authGetAuthSilentStart" },
    { 'method' => "GET", 'path' => "/config/public", 'tag' => "Config", 'operationId' => "configGetConfigPublic" },
    { 'method' => "GET", 'path' => "/data/{tenantSlug}/{appSlug}/{table}", 'tag' => "Schema", 'operationId' => "schemaGetDataByTenantSlugByAppSlugByTable" },
    { 'method' => "POST", 'path' => "/data/{tenantSlug}/{appSlug}/{table}", 'tag' => "Schema", 'operationId' => "schemaPostDataByTenantSlugByAppSlugByTable" },
    { 'method' => "GET", 'path' => "/data/{tenantSlug}/{appSlug}/{table}/_count", 'tag' => "Schema", 'operationId' => "schemaGetDataByTenantSlugByAppSlugByTableCount" },
    { 'method' => "DELETE", 'path' => "/data/{tenantSlug}/{appSlug}/{table}/{id}", 'tag' => "Schema", 'operationId' => "schemaDeleteDataByTenantSlugByAppSlugByTableById" },
    { 'method' => "GET", 'path' => "/data/{tenantSlug}/{appSlug}/{table}/{id}", 'tag' => "Schema", 'operationId' => "schemaGetDataByTenantSlugByAppSlugByTableById" },
    { 'method' => "PATCH", 'path' => "/data/{tenantSlug}/{appSlug}/{table}/{id}", 'tag' => "Schema", 'operationId' => "schemaPatchDataByTenantSlugByAppSlugByTableById" },
    { 'method' => "GET", 'path' => "/internal/app-access", 'tag' => "Apps", 'operationId' => "appsGetInternalAppAccess" },
    { 'method' => "GET", 'path' => "/oauth/authorize", 'tag' => "Auth", 'operationId' => "authGetOauthAuthorize" },
    { 'method' => "POST", 'path' => "/oauth/authorize/tenant", 'tag' => "Auth", 'operationId' => "authPostOauthAuthorizeTenant" },
    { 'method' => "POST", 'path' => "/oauth/device_authorization", 'tag' => "Auth", 'operationId' => "authPostOauthDeviceAuthorization" },
    { 'method' => "POST", 'path' => "/oauth/device/authorize", 'tag' => "Auth", 'operationId' => "authPostOauthDeviceAuthorize" },
    { 'method' => "GET", 'path' => "/oauth/device/lookup", 'tag' => "Auth", 'operationId' => "authGetOauthDeviceLookup" },
    { 'method' => "POST", 'path' => "/oauth/register", 'tag' => "Auth", 'operationId' => "authPostOauthRegister" },
    { 'method' => "POST", 'path' => "/oauth/revoke", 'tag' => "Auth", 'operationId' => "authPostOauthRevoke" },
    { 'method' => "POST", 'path' => "/oauth/token", 'tag' => "Auth", 'operationId' => "authPostOauthToken" },
    { 'method' => "GET", 'path' => "/oauth/userinfo", 'tag' => "Auth", 'operationId' => "authGetOauthUserinfo" },
    { 'method' => "POST", 'path' => "/webhooks/github", 'tag' => "Deploy", 'operationId' => "deployPostWebhooksGithub" },
  ].freeze

  ERROR_CODES = {
    "action_denied" => ErrorInfo.new("permission_denied", 403, false),
    "action_invalid" => ErrorInfo.new("validation", 400, false),
    "already_accessed" => ErrorInfo.new("conflict", 409, false),
    "already_active" => ErrorInfo.new("conflict", 409, false),
    "already_deleted" => ErrorInfo.new("conflict", 409, false),
    "already_exists" => ErrorInfo.new("conflict", 409, false),
    "already_inactive" => ErrorInfo.new("conflict", 409, false),
    "already_member" => ErrorInfo.new("conflict", 409, false),
    "already_revoked" => ErrorInfo.new("conflict", 409, false),
    "already_settled" => ErrorInfo.new("conflict", 409, false),
    "already_suspended" => ErrorInfo.new("conflict", 409, false),
    "already_terminal" => ErrorInfo.new("conflict", 409, false),
    "app_unavailable" => ErrorInfo.new("conflict", 409, false),
    "bad_request" => ErrorInfo.new("validation", 400, false),
    "cannot_reactivate" => ErrorInfo.new("conflict", 409, false),
    "conflict" => ErrorInfo.new("conflict", 409, false),
    "connector_inactive" => ErrorInfo.new("permission_denied", 403, false),
    "cross_tenant" => ErrorInfo.new("validation", 400, false),
    "domain_blocked" => ErrorInfo.new("precondition_failed", 422, false),
    "domain_taken" => ErrorInfo.new("conflict", 409, false),
    "duplicate" => ErrorInfo.new("validation", 400, false),
    "empty" => ErrorInfo.new("validation", 400, false),
    "expiry_in_past" => ErrorInfo.new("validation", 400, false),
    "forbidden" => ErrorInfo.new("permission_denied", 403, false),
    "grant_already_terminal" => ErrorInfo.new("conflict", 409, false),
    "grant_conflict" => ErrorInfo.new("conflict", 409, false),
    "grant_expired" => ErrorInfo.new("permission_denied", 403, false),
    "grant_revoked" => ErrorInfo.new("permission_denied", 403, false),
    "internal_error" => ErrorInfo.new("internal", 500, false),
    "invalid_expiry" => ErrorInfo.new("validation", 400, false),
    "invalid_format" => ErrorInfo.new("validation", 400, false),
    "invalid_state_transition" => ErrorInfo.new("conflict", 409, false),
    "invalid_value" => ErrorInfo.new("validation", 400, false),
    "invitation_expired" => ErrorInfo.new("not_found", 410, false),
    "kind_engine_mismatch" => ErrorInfo.new("validation", 400, false),
    "last_admin" => ErrorInfo.new("conflict", 409, false),
    "link_invalid" => ErrorInfo.new("not_found", 404, false),
    "no_active_grant" => ErrorInfo.new("not_found", 404, false),
    "not_admin" => ErrorInfo.new("permission_denied", 403, false),
    "not_allowed" => ErrorInfo.new("validation", 400, false),
    "not_deleted" => ErrorInfo.new("conflict", 409, false),
    "not_found" => ErrorInfo.new("not_found", 404, false),
    "not_member" => ErrorInfo.new("permission_denied", 403, false),
    "not_suspended" => ErrorInfo.new("conflict", 409, false),
    "pending_exists" => ErrorInfo.new("conflict", 409, false),
    "permanently_deleted" => ErrorInfo.new("not_found", 410, false),
    "precondition_failed" => ErrorInfo.new("precondition_failed", 412, false),
    "preset_mismatch" => ErrorInfo.new("validation", 400, false),
    "required" => ErrorInfo.new("validation", 400, false),
    "schema_name_taken" => ErrorInfo.new("conflict", 409, false),
    "session_ended" => ErrorInfo.new("unauthenticated", 401, true),
    "session_expired" => ErrorInfo.new("unauthenticated", 401, true),
    "slug_taken" => ErrorInfo.new("conflict", 409, false),
    "temporarily_unavailable" => ErrorInfo.new("unavailable", 429, true),
    "token_expired" => ErrorInfo.new("unauthenticated", 401, true),
    "token_invalid" => ErrorInfo.new("unauthenticated", 401, true),
    "token_missing" => ErrorInfo.new("unauthenticated", 401, true),
    "too_long" => ErrorInfo.new("validation", 400, false),
  }.freeze

  ROUTE_BY_OP = ROUTES.map { |r| [r['operationId'], r] }.to_h
  def self.camel(key)
    parts = key.to_s.split('_'); parts.first + parts.drop(1).map { |p| p[0].upcase + p[1..-1].to_s }.join
  end
  def self.camelize(value)
    case value
    when Hash then value.map { |k, v| [camel(k), camelize(v)] }.to_h
    when Array then value.map { |v| camelize(v) }
    else value
    end
  end
  FORM_ENCODED_OPERATIONS = %w[
    authPostOauthDeviceAuthorization
    authPostOauthRevoke
    authPostOauthToken
  ].freeze
  class Client
    attr_reader :base_url, :apps
    def initialize(base_url: DEFAULT_BASE_URL, token: nil, token_type: nil, default_tenant_id: nil, default_tenant_slug: nil, timeout_seconds: 30)
      @base_url = base_url.sub(%r{/$}, ''); @token = token; @token_type = token_type&.to_sym; @default_tenant_id = default_tenant_id; @default_tenant_slug = default_tenant_slug; @timeout_seconds = timeout_seconds; @apps = AppsClient.new(self)
    end
    def redacted_token
      @token.nil? || @token.empty? ? '' : '***REDACTED***'
    end
    def request(operation_id, path_params: {}, query: {}, body: nil)
      route = ROUTE_BY_OP.fetch(operation_id); path = route['path'].dup; path_params.each { |k, v| path.gsub!("{#{k}}", URI.encode_www_form_component(v.to_s)) }; raise Error.new(category: 'validation', code: 'required', message: 'missing path parameter') if path.include?(123.chr) || path.include?(125.chr)
      uri = URI(@base_url + path); uri.query = URI.encode_www_form(query) unless query.empty?
      req_class = Net::HTTP.const_get(route['method'].capitalize); req = req_class.new(uri); req['X-Request-ID'] = request_id
      if body
        if FORM_ENCODED_OPERATIONS.include?(operation_id)
          req['Content-Type'] = 'application/x-www-form-urlencoded'
          req.body = URI.encode_www_form(body.transform_keys(&:to_s).transform_values { |v| v.nil? ? '' : v.to_s })
        else
          req['Content-Type'] = 'application/json'
          req.body = JSON.generate(body)
        end
      end
      _send(req, uri, camelize: true)
    end

    # Raw-path transport for endpoints with no generated operation-id facade
    # (the ergonomic data ring: dynamic CRUD + runtime schema discover). `path`
    # is already fully substituted; `query` keys may be array-valued so repeated
    # filter params (e.g. `tag=eq.a&tag=eq.b`) serialize via URI.encode_www_form.
    # Defaults to `camelize: false` to mirror the node data transport: row bodies
    # and list envelopes (`has_more`/`per_page`) are returned verbatim.
    def request_raw(method, path, query: {}, body: nil, camelize: false)
      uri = URI(@base_url + path); uri.query = URI.encode_www_form(query) unless query.nil? || query.empty?
      req_class = Net::HTTP.const_get(method.to_s.capitalize); req = req_class.new(uri); req['X-Request-ID'] = request_id
      unless body.nil?
        req['Content-Type'] = 'application/json'; req.body = JSON.generate(body)
      end
      _send(req, uri, camelize: camelize)
    end

    private

    # Shared auth + send + redirect policy + response/error normalization tail.
    # `camelize: true` mirrors the operation-id `request` path (snake->camel
    # rewriting); `camelize: false` returns parsed JSON verbatim (data ring).
    def _send(req, uri, camelize:)
      if @token
        case @token_type
        when :pat then req['X-Api-Key'] = @token
        when :jwt then req['Authorization'] = "Bearer #{@token}"
        else raise Error.new(category: 'validation', code: 'required', message: 'tokenType must be explicit')
        end
      end
      begin
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', open_timeout: @timeout_seconds, read_timeout: @timeout_seconds) { |http| http.request(req) }
      rescue Timeout::Error, IOError, SocketError, SystemCallError => e
        raise Error.new(category: 'network', code: 'network_error', message: e.message, retryable: true)
      end
      return { 'status' => res.code.to_i, 'location' => res['location'] } if res.code.to_i >= 300 && res.code.to_i < 400
      parsed = if res.body && !res.body.empty?
                 begin
                   JSON.parse(res.body)
                 rescue JSON::ParserError
                   { 'raw' => res.body }
                 end
               else
                 {}
               end
      if res.code.to_i >= 400
        err = parsed.is_a?(Hash) ? (parsed['error'] || parsed) : {}
        err = {} unless err.is_a?(Hash)
        info = ERROR_CODES[err['code']]
        retryable = err.key?('retryable') ? !!err['retryable'] : !!info&.retryable
        raise Error.new(category: err['category'] || info&.category || 'unknown', code: err['code'] || "http_#{res.code}", message: err['message'], status: res.code.to_i, retryable: retryable, request_id: err['request_id'] || err['requestId'])
      end
      camelize ? AxHub.camelize(parsed) : parsed
    end

    def request_id
      (Time.now.to_i.to_s + SecureRandom.hex(16))[0, 26]
    end
  end
  class AppsClient
    def initialize(client)
      @client = client
    end
    def create(**body)
      tenant = @client.instance_variable_get(:@default_tenant_id); raise Error.new(category: 'tenant_id_required', code: 'tenant_id_required', message: 'default tenant id is required') if tenant.nil? || tenant.empty?
      @client.request('appsPostApiV1TenantsByTenantIDApps', path_params: { tenantID: tenant }, body: body)
    end
  end
  def self.context_name(route)
    tag = route['tag']
    return 'apps' if tag == 'Apps'
    return 'identity' if ['Auth', 'identity'].include?(tag)
    return 'tenants' if tag == 'Tenants'
    return 'authz' if tag == 'Authorization'
    return 'audit' if tag == 'Audit'
    return 'gateway' if ['Gateway', 'Config'].include?(tag)
    return 'cost' if tag == 'Cost'
    return 'data' if tag == 'Schema'
    return 'deployments' if ['Deploy', 'deploy'].include?(tag)
    raise ArgumentError, "unmapped route tag: #{tag}"
  end
  CONTEXT_ROUTES = %w[apps identity tenants authz audit gateway cost data deployments].map { |name| [name, ROUTES.select { |route| context_name(route) == name }] }.to_h
end

require_relative 'axhub_sdk/operations'
require_relative 'axhub_sdk/data'
