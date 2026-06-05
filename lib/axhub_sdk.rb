# frozen_string_literal: true
require 'json'
require 'net/http'
require 'securerandom'
require 'time'
require 'uri'

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
    {"method"=>"GET", "path"=>"/.well-known/jwks.json", "tag"=>"Auth", "operationId"=>"authGetWellKnownJwksJson"},
    {"method"=>"GET", "path"=>"/.well-known/openid-configuration", "tag"=>"Auth", "operationId"=>"authGetWellKnownOpenidConfiguration"},
    {"method"=>"GET", "path"=>"/api/v1/admin/templates", "tag"=>"Apps", "operationId"=>"appsGetApiV1AdminTemplates"},
    {"method"=>"POST", "path"=>"/api/v1/admin/templates", "tag"=>"Apps", "operationId"=>"appsPostApiV1AdminTemplates"},
    {"method"=>"GET", "path"=>"/api/v1/admin/templates/{templateID}", "tag"=>"Apps", "operationId"=>"appsGetApiV1AdminTemplatesByTemplateID"},
    {"method"=>"PATCH", "path"=>"/api/v1/admin/templates/{templateID}", "tag"=>"Apps", "operationId"=>"appsPatchApiV1AdminTemplatesByTemplateID"},
    {"method"=>"POST", "path"=>"/api/v1/admin/users/{uid}/revoke-all", "tag"=>"Auth", "operationId"=>"authPostApiV1AdminUsersByUidRevokeAll"},
    {"method"=>"DELETE", "path"=>"/api/v1/apps/{appID}", "tag"=>"Apps", "operationId"=>"appsDeleteApiV1AppsByAppID"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}", "tag"=>"Apps", "operationId"=>"appsGetApiV1AppsByAppID"},
    {"method"=>"PATCH", "path"=>"/api/v1/apps/{appID}", "tag"=>"Apps", "operationId"=>"appsPatchApiV1AppsByAppID"},
    {"method"=>"DELETE", "path"=>"/api/v1/apps/{appID}/access", "tag"=>"Apps", "operationId"=>"appsDeleteApiV1AppsByAppIDAccess"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/access", "tag"=>"Apps", "operationId"=>"appsPostApiV1AppsByAppIDAccess"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/access/me", "tag"=>"Apps", "operationId"=>"appsGetApiV1AppsByAppIDAccessMe"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/comments", "tag"=>"Apps", "operationId"=>"appsGetApiV1AppsByAppIDComments"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/comments", "tag"=>"Apps", "operationId"=>"appsPostApiV1AppsByAppIDComments"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/deployments", "tag"=>"Deploy", "operationId"=>"deployGetApiV1AppsByAppIDDeployments"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/deployments", "tag"=>"Deploy", "operationId"=>"deployPostApiV1AppsByAppIDDeployments"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/deployments/{did}", "tag"=>"Deploy", "operationId"=>"deployGetApiV1AppsByAppIDDeploymentsByDid"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/deployments/{did}/cancel", "tag"=>"Deploy", "operationId"=>"deployPostApiV1AppsByAppIDDeploymentsByDidCancel"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/deployments/{did}/rollback", "tag"=>"Deploy", "operationId"=>"deployPostApiV1AppsByAppIDDeploymentsByDidRollback"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/env-vars", "tag"=>"Apps", "operationId"=>"appsGetApiV1AppsByAppIDEnvVars"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/env-vars", "tag"=>"Apps", "operationId"=>"appsPostApiV1AppsByAppIDEnvVars"},
    {"method"=>"DELETE", "path"=>"/api/v1/apps/{appID}/env-vars/{key}", "tag"=>"Apps", "operationId"=>"appsDeleteApiV1AppsByAppIDEnvVarsByKey"},
    {"method"=>"DELETE", "path"=>"/api/v1/apps/{appID}/git-connection", "tag"=>"Deploy", "operationId"=>"deployDeleteApiV1AppsByAppIDGitConnection"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/git-connection", "tag"=>"Deploy", "operationId"=>"deployGetApiV1AppsByAppIDGitConnection"},
    {"method"=>"PATCH", "path"=>"/api/v1/apps/{appID}/git-connection", "tag"=>"Deploy", "operationId"=>"deployPatchApiV1AppsByAppIDGitConnection"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/git-connection", "tag"=>"Deploy", "operationId"=>"deployPostApiV1AppsByAppIDGitConnection"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/git/github/install/start", "tag"=>"Deploy", "operationId"=>"deployGetApiV1AppsByAppIDGitGithubInstallStart"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/icon-dark/upload-url", "tag"=>"Apps", "operationId"=>"appsPostApiV1AppsByAppIDIconDarkUploadUrl"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/icon/upload-url", "tag"=>"Apps", "operationId"=>"appsPostApiV1AppsByAppIDIconUploadUrl"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/invitations", "tag"=>"Apps", "operationId"=>"appsPostApiV1AppsByAppIDInvitations"},
    {"method"=>"DELETE", "path"=>"/api/v1/apps/{appID}/invitations/{userID}", "tag"=>"Apps", "operationId"=>"appsDeleteApiV1AppsByAppIDInvitationsByUserID"},
    {"method"=>"DELETE", "path"=>"/api/v1/apps/{appID}/likes", "tag"=>"Apps", "operationId"=>"appsDeleteApiV1AppsByAppIDLikes"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/likes", "tag"=>"Apps", "operationId"=>"appsPostApiV1AppsByAppIDLikes"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/likes/me", "tag"=>"Apps", "operationId"=>"appsGetApiV1AppsByAppIDLikesMe"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/logs", "tag"=>"Deploy", "operationId"=>"deployGetApiV1AppsByAppIDLogs"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/members", "tag"=>"Apps", "operationId"=>"appsGetApiV1AppsByAppIDMembers"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/oauth-clients", "tag"=>"Auth", "operationId"=>"authPostApiV1AppsByAppIDOauthClients"},
    {"method"=>"DELETE", "path"=>"/api/v1/apps/{appID}/permanent", "tag"=>"Apps", "operationId"=>"appsDeleteApiV1AppsByAppIDPermanent"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/resume", "tag"=>"Apps", "operationId"=>"appsPostApiV1AppsByAppIDResume"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/review-requests", "tag"=>"Apps", "operationId"=>"appsGetApiV1AppsByAppIDReviewRequests"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/review-requests", "tag"=>"Apps", "operationId"=>"appsPostApiV1AppsByAppIDReviewRequests"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/suspend", "tag"=>"Apps", "operationId"=>"appsPostApiV1AppsByAppIDSuspend"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/tables", "tag"=>"Schema", "operationId"=>"schemaGetApiV1AppsByAppIDTables"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/tables", "tag"=>"Schema", "operationId"=>"schemaPostApiV1AppsByAppIDTables"},
    {"method"=>"DELETE", "path"=>"/api/v1/apps/{appID}/tables/{tableName}", "tag"=>"Schema", "operationId"=>"schemaDeleteApiV1AppsByAppIDTablesByTableName"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/tables/{tableName}", "tag"=>"Schema", "operationId"=>"schemaGetApiV1AppsByAppIDTablesByTableName"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/tables/{tableName}/columns", "tag"=>"Schema", "operationId"=>"schemaPostApiV1AppsByAppIDTablesByTableNameColumns"},
    {"method"=>"DELETE", "path"=>"/api/v1/apps/{appID}/tables/{tableName}/columns/{columnName}", "tag"=>"Schema", "operationId"=>"schemaDeleteApiV1AppsByAppIDTablesByTableNameColumnsByColumnName"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/tables/{tableName}/grants", "tag"=>"Schema", "operationId"=>"schemaGetApiV1AppsByAppIDTablesByTableNameGrants"},
    {"method"=>"POST", "path"=>"/api/v1/apps/{appID}/tables/{tableName}/grants", "tag"=>"Schema", "operationId"=>"schemaPostApiV1AppsByAppIDTablesByTableNameGrants"},
    {"method"=>"DELETE", "path"=>"/api/v1/apps/{appID}/tables/{tableName}/grants/{grantID}", "tag"=>"Schema", "operationId"=>"schemaDeleteApiV1AppsByAppIDTablesByTableNameGrantsByGrantID"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/tables/{tableName}/rows", "tag"=>"Schema", "operationId"=>"schemaGetApiV1AppsByAppIDTablesByTableNameRows"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/tables/check-availability", "tag"=>"Schema", "operationId"=>"schemaGetApiV1AppsByAppIDTablesCheckAvailability"},
    {"method"=>"GET", "path"=>"/api/v1/apps/{appID}/tables/column-types", "tag"=>"Schema", "operationId"=>"schemaGetApiV1AppsByAppIDTablesColumnTypes"},
    {"method"=>"GET", "path"=>"/api/v1/apps/discover", "tag"=>"Apps", "operationId"=>"appsGetApiV1AppsDiscover"},
    {"method"=>"GET", "path"=>"/api/v1/apps/search", "tag"=>"Apps", "operationId"=>"appsGetApiV1AppsSearch"},
    {"method"=>"GET", "path"=>"/api/v1/catalog/kinds", "tag"=>"Gateway", "operationId"=>"gatewayGetApiV1CatalogKinds"},
    {"method"=>"DELETE", "path"=>"/api/v1/comments/{commentID}", "tag"=>"Apps", "operationId"=>"appsDeleteApiV1CommentsByCommentID"},
    {"method"=>"GET", "path"=>"/api/v1/engines", "tag"=>"Gateway", "operationId"=>"gatewayGetApiV1Engines"},
    {"method"=>"GET", "path"=>"/api/v1/github/accounts", "tag"=>"deploy", "operationId"=>"deployGetApiV1GithubAccounts"},
    {"method"=>"GET", "path"=>"/api/v1/github/installations/{installationID}/repositories", "tag"=>"deploy", "operationId"=>"deployGetApiV1GithubInstallationsByInstallationIDRepositories"},
    {"method"=>"GET", "path"=>"/api/v1/me", "tag"=>"Auth", "operationId"=>"authGetApiV1Me"},
    {"method"=>"GET", "path"=>"/api/v1/me/apps/owned", "tag"=>"Apps", "operationId"=>"appsGetApiV1MeAppsOwned"},
    {"method"=>"GET", "path"=>"/api/v1/me/apps/received", "tag"=>"Apps", "operationId"=>"appsGetApiV1MeAppsReceived"},
    {"method"=>"GET", "path"=>"/api/v1/me/apps/workspace", "tag"=>"Apps", "operationId"=>"appsGetApiV1MeAppsWorkspace"},
    {"method"=>"GET", "path"=>"/api/v1/me/personal-access-tokens", "tag"=>"Schema", "operationId"=>"schemaGetApiV1MePersonalAccessTokens"},
    {"method"=>"POST", "path"=>"/api/v1/me/personal-access-tokens", "tag"=>"Schema", "operationId"=>"schemaPostApiV1MePersonalAccessTokens"},
    {"method"=>"DELETE", "path"=>"/api/v1/me/personal-access-tokens/{patID}", "tag"=>"Schema", "operationId"=>"schemaDeleteApiV1MePersonalAccessTokensByPatID"},
    {"method"=>"GET", "path"=>"/api/v1/oauth-clients/{clientID}", "tag"=>"Auth", "operationId"=>"authGetApiV1OauthClientsByClientID"},
    {"method"=>"DELETE", "path"=>"/api/v1/oauth/clients/{clientID}/grants/me", "tag"=>"Auth", "operationId"=>"authDeleteApiV1OauthClientsByClientIDGrantsMe"},
    {"method"=>"GET", "path"=>"/api/v1/review-requests/{rrID}", "tag"=>"Apps", "operationId"=>"appsGetApiV1ReviewRequestsByRrID"},
    {"method"=>"POST", "path"=>"/api/v1/review-requests/{rrID}/approve", "tag"=>"Apps", "operationId"=>"appsPostApiV1ReviewRequestsByRrIDApprove"},
    {"method"=>"POST", "path"=>"/api/v1/review-requests/{rrID}/reject", "tag"=>"Apps", "operationId"=>"appsPostApiV1ReviewRequestsByRrIDReject"},
    {"method"=>"GET", "path"=>"/api/v1/review-requests/history", "tag"=>"Apps", "operationId"=>"appsGetApiV1ReviewRequestsHistory"},
    {"method"=>"GET", "path"=>"/api/v1/review-requests/pending", "tag"=>"Apps", "operationId"=>"appsGetApiV1ReviewRequestsPending"},
    {"method"=>"GET", "path"=>"/api/v1/templates", "tag"=>"Apps", "operationId"=>"appsGetApiV1Templates"},
    {"method"=>"GET", "path"=>"/api/v1/tenants", "tag"=>"Tenants", "operationId"=>"tenantsGetApiV1Tenants"},
    {"method"=>"POST", "path"=>"/api/v1/tenants", "tag"=>"Tenants", "operationId"=>"tenantsPostApiV1Tenants"},
    {"method"=>"DELETE", "path"=>"/api/v1/tenants/{tenantID}", "tag"=>"Tenants", "operationId"=>"tenantsDeleteApiV1TenantsByTenantID"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}", "tag"=>"Tenants", "operationId"=>"tenantsGetApiV1TenantsByTenantID"},
    {"method"=>"PATCH", "path"=>"/api/v1/tenants/{tenantID}", "tag"=>"Tenants", "operationId"=>"tenantsPatchApiV1TenantsByTenantID"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/app-bootstraps", "tag"=>"Deploy", "operationId"=>"deployPostApiV1TenantsByTenantIDAppBootstraps"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/app-bootstraps/{bootstrapID}", "tag"=>"Deploy", "operationId"=>"deployGetApiV1TenantsByTenantIDAppBootstrapsByBootstrapID"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/apps", "tag"=>"Apps", "operationId"=>"appsGetApiV1TenantsByTenantIDApps"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/apps", "tag"=>"Apps", "operationId"=>"appsPostApiV1TenantsByTenantIDApps"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/apps/check-availability", "tag"=>"Apps", "operationId"=>"appsGetApiV1TenantsByTenantIDAppsCheckAvailability"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/apps/icon/upload-url", "tag"=>"Apps", "operationId"=>"appsPostApiV1TenantsByTenantIDAppsIconUploadUrl"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/audit-events", "tag"=>"Audit", "operationId"=>"auditGetApiV1TenantsByTenantIDAuditEvents"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/audit-events/{eventID}", "tag"=>"Audit", "operationId"=>"auditGetApiV1TenantsByTenantIDAuditEventsByEventID"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/audit-events/anonymize", "tag"=>"Audit", "operationId"=>"auditPostApiV1TenantsByTenantIDAuditEventsAnonymize"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/audit-events/integrity-check", "tag"=>"Audit", "operationId"=>"auditGetApiV1TenantsByTenantIDAuditEventsIntegrityCheck"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/catalog/connectors", "tag"=>"Gateway", "operationId"=>"gatewayGetApiV1TenantsByTenantIDCatalogConnectors"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/catalog/resources", "tag"=>"Gateway", "operationId"=>"gatewayGetApiV1TenantsByTenantIDCatalogResources"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/catalog/resources/{connector}/{path}", "tag"=>"Gateway", "operationId"=>"gatewayGetApiV1TenantsByTenantIDCatalogResourcesByConnectorByPath"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/catalog/resources/{connector}/{path}", "tag"=>"Gateway", "operationId"=>"gatewayPostApiV1TenantsByTenantIDCatalogResourcesByConnectorByPath"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/categories", "tag"=>"Apps", "operationId"=>"appsGetApiV1TenantsByTenantIDCategories"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/categories", "tag"=>"Apps", "operationId"=>"appsPostApiV1TenantsByTenantIDCategories"},
    {"method"=>"DELETE", "path"=>"/api/v1/tenants/{tenantID}/categories/{categoryID}", "tag"=>"Apps", "operationId"=>"appsDeleteApiV1TenantsByTenantIDCategoriesByCategoryID"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/categories/{categoryID}", "tag"=>"Apps", "operationId"=>"appsGetApiV1TenantsByTenantIDCategoriesByCategoryID"},
    {"method"=>"PATCH", "path"=>"/api/v1/tenants/{tenantID}/categories/{categoryID}", "tag"=>"Apps", "operationId"=>"appsPatchApiV1TenantsByTenantIDCategoriesByCategoryID"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/connectors", "tag"=>"Gateway", "operationId"=>"gatewayGetApiV1TenantsByTenantIDConnectors"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/connectors", "tag"=>"Gateway", "operationId"=>"gatewayPostApiV1TenantsByTenantIDConnectors"},
    {"method"=>"DELETE", "path"=>"/api/v1/tenants/{tenantID}/connectors/{connectorID}", "tag"=>"Gateway", "operationId"=>"gatewayDeleteApiV1TenantsByTenantIDConnectorsByConnectorID"},
    {"method"=>"PATCH", "path"=>"/api/v1/tenants/{tenantID}/connectors/{connectorID}", "tag"=>"Gateway", "operationId"=>"gatewayPatchApiV1TenantsByTenantIDConnectorsByConnectorID"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/connectors/{connectorID}/credentials", "tag"=>"Gateway", "operationId"=>"gatewayPostApiV1TenantsByTenantIDConnectorsByConnectorIDCredentials"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/connectors/{connectorID}/discover", "tag"=>"Gateway", "operationId"=>"gatewayGetApiV1TenantsByTenantIDConnectorsByConnectorIDDiscover"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/discover/apps", "tag"=>"Apps", "operationId"=>"appsGetApiV1TenantsByTenantIDDiscoverApps"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/gateway/query", "tag"=>"Gateway", "operationId"=>"gatewayPostApiV1TenantsByTenantIDGatewayQuery"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/grants", "tag"=>"Authorization", "operationId"=>"authorizationGetApiV1TenantsByTenantIDGrants"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/grants/{grantID}/grant", "tag"=>"Authorization", "operationId"=>"authorizationPostApiV1TenantsByTenantIDGrantsByGrantIDGrant"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/grants/{grantID}/revoke", "tag"=>"Authorization", "operationId"=>"authorizationPostApiV1TenantsByTenantIDGrantsByGrantIDRevoke"},
    {"method"=>"DELETE", "path"=>"/api/v1/tenants/{tenantID}/icon", "tag"=>"Tenants", "operationId"=>"tenantsDeleteApiV1TenantsByTenantIDIcon"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/icon/upload-url", "tag"=>"Tenants", "operationId"=>"tenantsPostApiV1TenantsByTenantIDIconUploadUrl"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/identity-providers", "tag"=>"Auth", "operationId"=>"authGetApiV1TenantsByTenantIDIdentityProviders"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/identity-providers", "tag"=>"Auth", "operationId"=>"authPostApiV1TenantsByTenantIDIdentityProviders"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/identity-providers/{providerID}/disable", "tag"=>"Auth", "operationId"=>"authPostApiV1TenantsByTenantIDIdentityProvidersByProviderIDDisable"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/identity-providers/{providerID}/enable", "tag"=>"Auth", "operationId"=>"authPostApiV1TenantsByTenantIDIdentityProvidersByProviderIDEnable"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/invitations", "tag"=>"Tenants", "operationId"=>"tenantsGetApiV1TenantsByTenantIDInvitations"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/invitations", "tag"=>"Tenants", "operationId"=>"tenantsPostApiV1TenantsByTenantIDInvitations"},
    {"method"=>"DELETE", "path"=>"/api/v1/tenants/{tenantID}/invitations/{invitationID}", "tag"=>"Tenants", "operationId"=>"tenantsDeleteApiV1TenantsByTenantIDInvitationsByInvitationID"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/invitations/bulk", "tag"=>"Tenants", "operationId"=>"tenantsPostApiV1TenantsByTenantIDInvitationsBulk"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/members", "tag"=>"Tenants", "operationId"=>"tenantsGetApiV1TenantsByTenantIDMembers"},
    {"method"=>"PATCH", "path"=>"/api/v1/tenants/{tenantID}/members/{membershipID}", "tag"=>"Tenants", "operationId"=>"tenantsPatchApiV1TenantsByTenantIDMembersByMembershipID"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/members/{membershipID}/deactivate", "tag"=>"Tenants", "operationId"=>"tenantsPostApiV1TenantsByTenantIDMembersByMembershipIDDeactivate"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/members/{membershipID}/reactivate", "tag"=>"Tenants", "operationId"=>"tenantsPostApiV1TenantsByTenantIDMembersByMembershipIDReactivate"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/resources", "tag"=>"Gateway", "operationId"=>"gatewayGetApiV1TenantsByTenantIDResources"},
    {"method"=>"DELETE", "path"=>"/api/v1/tenants/{tenantID}/resources/{resourceID}", "tag"=>"Gateway", "operationId"=>"gatewayDeleteApiV1TenantsByTenantIDResourcesByResourceID"},
    {"method"=>"PATCH", "path"=>"/api/v1/tenants/{tenantID}/resources/{resourceID}", "tag"=>"Gateway", "operationId"=>"gatewayPatchApiV1TenantsByTenantIDResourcesByResourceID"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/resources/{resourceID}/move", "tag"=>"Gateway", "operationId"=>"gatewayPostApiV1TenantsByTenantIDResourcesByResourceIDMove"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/resources/{resourceID}/tags", "tag"=>"Gateway", "operationId"=>"gatewayPostApiV1TenantsByTenantIDResourcesByResourceIDTags"},
    {"method"=>"DELETE", "path"=>"/api/v1/tenants/{tenantID}/resources/{resourceID}/tags/{tagID}", "tag"=>"Gateway", "operationId"=>"gatewayDeleteApiV1TenantsByTenantIDResourcesByResourceIDTagsByTagID"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/resources/bulk", "tag"=>"Gateway", "operationId"=>"gatewayPostApiV1TenantsByTenantIDResourcesBulk"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/resources/namespaces", "tag"=>"Gateway", "operationId"=>"gatewayPostApiV1TenantsByTenantIDResourcesNamespaces"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/subjects", "tag"=>"Authorization", "operationId"=>"authorizationGetApiV1TenantsByTenantIDSubjects"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/subjects", "tag"=>"Authorization", "operationId"=>"authorizationPostApiV1TenantsByTenantIDSubjects"},
    {"method"=>"DELETE", "path"=>"/api/v1/tenants/{tenantID}/subjects/{subjectID}", "tag"=>"Authorization", "operationId"=>"authorizationDeleteApiV1TenantsByTenantIDSubjectsBySubjectID"},
    {"method"=>"PATCH", "path"=>"/api/v1/tenants/{tenantID}/subjects/{subjectID}", "tag"=>"Authorization", "operationId"=>"authorizationPatchApiV1TenantsByTenantIDSubjectsBySubjectID"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/subjects/{subjectID}/move", "tag"=>"Authorization", "operationId"=>"authorizationPostApiV1TenantsByTenantIDSubjectsBySubjectIDMove"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/subjects/{subjectID}/tags", "tag"=>"Authorization", "operationId"=>"authorizationPostApiV1TenantsByTenantIDSubjectsBySubjectIDTags"},
    {"method"=>"DELETE", "path"=>"/api/v1/tenants/{tenantID}/subjects/{subjectID}/tags/{tagID}", "tag"=>"Authorization", "operationId"=>"authorizationDeleteApiV1TenantsByTenantIDSubjectsBySubjectIDTagsByTagID"},
    {"method"=>"GET", "path"=>"/api/v1/tenants/{tenantID}/tags", "tag"=>"Authorization", "operationId"=>"authorizationGetApiV1TenantsByTenantIDTags"},
    {"method"=>"POST", "path"=>"/api/v1/tenants/{tenantID}/tags", "tag"=>"Authorization", "operationId"=>"authorizationPostApiV1TenantsByTenantIDTags"},
    {"method"=>"DELETE", "path"=>"/api/v1/tenants/{tenantID}/tags/{tagID}", "tag"=>"Authorization", "operationId"=>"authorizationDeleteApiV1TenantsByTenantIDTagsByTagID"},
    {"method"=>"PATCH", "path"=>"/api/v1/tenants/{tenantID}/tags/{tagID}", "tag"=>"Authorization", "operationId"=>"authorizationPatchApiV1TenantsByTenantIDTagsByTagID"},
    {"method"=>"GET", "path"=>"/api/v1/users/me/apps", "tag"=>"Apps", "operationId"=>"appsGetApiV1UsersMeApps"},
    {"method"=>"GET", "path"=>"/auth/{providerID}/start", "tag"=>"Auth", "operationId"=>"authGetAuthByProviderIDStart"},
    {"method"=>"GET", "path"=>"/auth/github", "tag"=>"identity", "operationId"=>"identityGetAuthGithub"},
    {"method"=>"GET", "path"=>"/auth/github/callback", "tag"=>"identity", "operationId"=>"identityGetAuthGithubCallback"},
    {"method"=>"GET", "path"=>"/auth/google_oauth2/callback", "tag"=>"Auth", "operationId"=>"authGetAuthGoogleOauth2Callback"},
    {"method"=>"GET", "path"=>"/auth/google_oauth2/start", "tag"=>"Auth", "operationId"=>"authGetAuthGoogleOauth2Start"},
    {"method"=>"POST", "path"=>"/auth/logout", "tag"=>"Auth", "operationId"=>"authPostAuthLogout"},
    {"method"=>"GET", "path"=>"/auth/oidc/callback", "tag"=>"Auth", "operationId"=>"authGetAuthOidcCallback"},
    {"method"=>"GET", "path"=>"/auth/providers", "tag"=>"Auth", "operationId"=>"authGetAuthProviders"},
    {"method"=>"POST", "path"=>"/auth/refresh", "tag"=>"Auth", "operationId"=>"authPostAuthRefresh"},
    {"method"=>"GET", "path"=>"/auth/silent/callback", "tag"=>"Auth", "operationId"=>"authGetAuthSilentCallback"},
    {"method"=>"GET", "path"=>"/auth/silent/start", "tag"=>"Auth", "operationId"=>"authGetAuthSilentStart"},
    {"method"=>"GET", "path"=>"/config/public", "tag"=>"Config", "operationId"=>"configGetConfigPublic"},
    {"method"=>"GET", "path"=>"/data/{tenantSlug}/{appSlug}/{table}", "tag"=>"Schema", "operationId"=>"schemaGetDataByTenantSlugByAppSlugByTable"},
    {"method"=>"POST", "path"=>"/data/{tenantSlug}/{appSlug}/{table}", "tag"=>"Schema", "operationId"=>"schemaPostDataByTenantSlugByAppSlugByTable"},
    {"method"=>"GET", "path"=>"/data/{tenantSlug}/{appSlug}/{table}/_count", "tag"=>"Schema", "operationId"=>"schemaGetDataByTenantSlugByAppSlugByTableCount"},
    {"method"=>"DELETE", "path"=>"/data/{tenantSlug}/{appSlug}/{table}/{id}", "tag"=>"Schema", "operationId"=>"schemaDeleteDataByTenantSlugByAppSlugByTableById"},
    {"method"=>"GET", "path"=>"/data/{tenantSlug}/{appSlug}/{table}/{id}", "tag"=>"Schema", "operationId"=>"schemaGetDataByTenantSlugByAppSlugByTableById"},
    {"method"=>"PATCH", "path"=>"/data/{tenantSlug}/{appSlug}/{table}/{id}", "tag"=>"Schema", "operationId"=>"schemaPatchDataByTenantSlugByAppSlugByTableById"},
    {"method"=>"GET", "path"=>"/internal/app-access", "tag"=>"Apps", "operationId"=>"appsGetInternalAppAccess"},
    {"method"=>"GET", "path"=>"/oauth/authorize", "tag"=>"Auth", "operationId"=>"authGetOauthAuthorize"},
    {"method"=>"POST", "path"=>"/oauth/device_authorization", "tag"=>"Auth", "operationId"=>"authPostOauthDeviceAuthorization"},
    {"method"=>"POST", "path"=>"/oauth/device/authorize", "tag"=>"Auth", "operationId"=>"authPostOauthDeviceAuthorize"},
    {"method"=>"GET", "path"=>"/oauth/device/lookup", "tag"=>"Auth", "operationId"=>"authGetOauthDeviceLookup"},
    {"method"=>"POST", "path"=>"/oauth/register", "tag"=>"Auth", "operationId"=>"authPostOauthRegister"},
    {"method"=>"POST", "path"=>"/oauth/revoke", "tag"=>"Auth", "operationId"=>"authPostOauthRevoke"},
    {"method"=>"POST", "path"=>"/oauth/token", "tag"=>"Auth", "operationId"=>"authPostOauthToken"},
    {"method"=>"GET", "path"=>"/oauth/userinfo", "tag"=>"Auth", "operationId"=>"authGetOauthUserinfo"},
    {"method"=>"GET", "path"=>"/tenants/{tenantID}/email-domains", "tag"=>"Tenants", "operationId"=>"tenantsGetTenantsByTenantIDEmailDomains"},
    {"method"=>"POST", "path"=>"/tenants/{tenantID}/email-domains", "tag"=>"Tenants", "operationId"=>"tenantsPostTenantsByTenantIDEmailDomains"},
    {"method"=>"DELETE", "path"=>"/tenants/{tenantID}/email-domains/{domain}", "tag"=>"Tenants", "operationId"=>"tenantsDeleteTenantsByTenantIDEmailDomainsByDomain"},
    {"method"=>"POST", "path"=>"/webhooks/github", "tag"=>"Deploy", "operationId"=>"deployPostWebhooksGithub"},
  ]
  ERROR_CODES = {
    "already_accessed" => ErrorInfo.new("conflict", 409, false),
    "already_active" => ErrorInfo.new("conflict", 409, false),
    "already_deleted" => ErrorInfo.new("conflict", 409, false),
    "already_exists" => ErrorInfo.new("conflict", 409, false),
    "already_inactive" => ErrorInfo.new("conflict", 409, false),
    "already_member" => ErrorInfo.new("conflict", 409, false),
    "already_revoked" => ErrorInfo.new("conflict", 409, false),
    "already_settled" => ErrorInfo.new("conflict", 409, false),
    "already_suspended" => ErrorInfo.new("conflict", 409, false),
    "app_unavailable" => ErrorInfo.new("conflict", 409, false),
    "bad_request" => ErrorInfo.new("validation", 400, false),
    "cannot_reactivate" => ErrorInfo.new("conflict", 409, false),
    "conflict" => ErrorInfo.new("conflict", 409, false),
    "cross_tenant" => ErrorInfo.new("validation", 400, false),
    "domain_blocked" => ErrorInfo.new("precondition_failed", 422, false),
    "domain_taken" => ErrorInfo.new("conflict", 409, false),
    "duplicate" => ErrorInfo.new("validation", 400, false),
    "empty" => ErrorInfo.new("validation", 400, false),
    "forbidden" => ErrorInfo.new("permission_denied", 403, false),
    "internal_error" => ErrorInfo.new("internal", 500, false),
    "invalid_format" => ErrorInfo.new("validation", 400, false),
    "invalid_state_transition" => ErrorInfo.new("conflict", 409, false),
    "invalid_value" => ErrorInfo.new("validation", 400, false),
    "invitation_expired" => ErrorInfo.new("not_found", 410, false),
    "last_admin" => ErrorInfo.new("conflict", 409, false),
    "not_admin" => ErrorInfo.new("permission_denied", 403, false),
    "not_allowed" => ErrorInfo.new("validation", 400, false),
    "not_deleted" => ErrorInfo.new("conflict", 409, false),
    "not_found" => ErrorInfo.new("not_found", 404, false),
    "not_member" => ErrorInfo.new("permission_denied", 403, false),
    "not_suspended" => ErrorInfo.new("conflict", 409, false),
    "pending_exists" => ErrorInfo.new("conflict", 409, false),
    "permanently_deleted" => ErrorInfo.new("not_found", 410, false),
    "precondition_failed" => ErrorInfo.new("precondition_failed", 412, false),
    "required" => ErrorInfo.new("validation", 400, false),
    "schema_name_taken" => ErrorInfo.new("conflict", 409, false),
    "slug_taken" => ErrorInfo.new("conflict", 409, false),
    "temporarily_unavailable" => ErrorInfo.new("unavailable", 429, true),
    "token_expired" => ErrorInfo.new("unauthenticated", 401, true),
    "token_invalid" => ErrorInfo.new("unauthenticated", 401, true),
    "token_missing" => ErrorInfo.new("unauthenticated", 401, true),
    "too_long" => ErrorInfo.new("validation", 400, false),
  }
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
  class Client
    attr_reader :base_url, :apps
    def initialize(base_url: DEFAULT_BASE_URL, token: nil, token_type: nil, default_tenant_id: nil, default_tenant_slug: nil)
      @base_url = base_url.sub(%r{/$}, ''); @token = token; @token_type = token_type&.to_sym; @default_tenant_id = default_tenant_id; @default_tenant_slug = default_tenant_slug; @apps = AppsClient.new(self)
    end
    def redacted_token
      @token.nil? || @token.empty? ? '' : '***REDACTED***'
    end
    def request(operation_id, path_params: {}, query: {}, body: nil)
      route = ROUTE_BY_OP.fetch(operation_id); path = route['path'].dup; path_params.each { |k, v| path.gsub!("{#{k}}", URI.encode_www_form_component(v.to_s)) }; raise Error.new(category: 'validation', code: 'required', message: 'missing path parameter') if path.include?(123.chr) || path.include?(125.chr)
      uri = URI(@base_url + path); uri.query = URI.encode_www_form(query) unless query.empty?
      req_class = Net::HTTP.const_get(route['method'].capitalize); req = req_class.new(uri); req['X-Request-ID'] = request_id
      if body then req['Content-Type'] = 'application/json'; req.body = JSON.generate(body) end
      if @token
        case @token_type
        when :pat then req['X-Api-Key'] = @token
        when :jwt then req['Authorization'] = "Bearer #{@token}"
        else raise Error.new(category: 'validation', code: 'required', message: 'tokenType must be explicit')
        end
      end
      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }
      parsed = res.body && !res.body.empty? ? JSON.parse(res.body) : {}
      if res.code.to_i >= 400
        err = parsed['error'] || {}; info = ERROR_CODES[err['code']]; retryable = err.key?('retryable') ? !!err['retryable'] : !!info&.retryable; raise Error.new(category: err['category'] || info&.category || 'unknown', code: err['code'] || "http_#{res.code}", message: err['message'], status: res.code.to_i, retryable: retryable, request_id: err['request_id'] || err['requestId'])
      end
      AxHub.camelize(parsed)
    end
    private
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
    return 'data' if tag == 'Schema'
    return 'deployments' if ['Deploy', 'deploy'].include?(tag)
    'gateway'
  end
  CONTEXT_ROUTES = %w[apps identity tenants authz audit gateway data deployments].map { |name| [name, ROUTES.select { |route| context_name(route) == name }] }.to_h
end

require_relative 'axhub_sdk/operations'
