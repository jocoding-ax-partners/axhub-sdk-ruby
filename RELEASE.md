# Release Runbook

This SDK uses tag-triggered GitHub Actions releases. Do not create a `v*` tag until every checklist item below is true for the target repository.

## Shared release gate

1. Merge release-ready changes to `main` and wait for `ci.yml` to pass on the exact commit to tag.
2. Tag only a commit that is already contained in `origin/main`; each `release.yml` verifies this before publishing.
3. Use the package version currently committed in source metadata. Python/Ruby/JVM releases fail if `github.ref_name` does not match the source version.
4. Approve the GitHub Environment deployment only after checking the registry prerequisites below.
5. After publish, keep the smoke job result visible. A failed smoke job means the public artifact is not yet consumable and must be investigated before announcing release completion.

## Cross-SDK release order

- Go, Python, and Ruby can release independently once their registry/environment gates are ready.
- Java must be released to Maven Central before Kotlin.
- Kotlin release disables the local Java composite build and resolves `ai.axhub:axhub-sdk-java` from Maven Central, so the exact Java dependency version in `build.gradle.kts` must already be visible on Maven Central.

## Registry prerequisites

- Go: repository environment `github-release` is approved for the tag. No registry secret is required; the workflow creates the GitHub Release and then verifies module-proxy consumption.
- Python: PyPI trusted publisher is configured for repository `jocoding-ax-partners/axhub-sdk-python`, workflow `.github/workflows/release.yml`, and environment `pypi`.
- Ruby: RubyGems trusted publisher is configured for repository `jocoding-ax-partners/axhub-sdk-ruby`, workflow `.github/workflows/release.yml`, and environment `rubygems`.
- Java/Kotlin: Maven Central namespace `ai.axhub` is verified, environment `maven-central` contains `MAVEN_CENTRAL_USERNAME`, `MAVEN_CENTRAL_PASSWORD`, `GPG_SIGNING_KEY`, and `GPG_SIGNING_PASSWORD`, and release approval is restricted to authorized maintainers.

## Failure handling

- If a publish step fails, delete only local scratch artifacts; do not retag a different commit with the same version.
- If a smoke job fails after publish, inspect registry visibility first. For Maven Central, wait for propagation and rerun the smoke job only after confirming the POM URL is available.
- If Kotlin fails its Java preflight, publish/sync the Java SDK version first, then rerun Kotlin from the same tag once the Java POM is visible.

## Workflow hardening

- CI and release actions are pinned to full commit SHAs.
- Release workflows separate verification/build work from registry or repository-write publishing credentials.
- Checkout steps use `persist-credentials: false` unless a publish action explicitly requires a token.
