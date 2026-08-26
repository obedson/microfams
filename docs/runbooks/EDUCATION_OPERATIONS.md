# Education Operations and Recovery

## Scope

The education workflow exposes public courses and tenant-scoped organization courses, lesson video content, authenticated learner progress, recommendations, and certificate generation. Progress is stored under the active organization and authenticated user.

This increment documents the existing workflow. It does not claim that learning paths, assessments, extension-officer tools, group learning, or offline content are complete.

## Deployment verification

1. Verify the course API and frontend deployment use the same release commit.
2. Open /courses and confirm public course cards load without authentication.
3. Sign in with a learner and open a course detail page.
4. Update progress and confirm the progress record is scoped to the active organization and learner.
5. Verify certificate generation requires completed progress and does not expose another organization's course or learner data.
6. Run the frontend build, component tests, backend course tests, and browser smoke in CI.

## Monitoring

Monitor course list/detail, progress, recommendation, and certificate endpoints by status code, organization, and correlation identifier. Alert on repeated progress upsert failures, certificate errors, unexpected cross-tenant no-row responses, or video-provider failures. Do not log learner notes, tokens, or private course metadata.

## Disable and recovery

If an education release is unsafe, disable new progress or certificate mutations at the backend authorization boundary while retaining read access to existing courses and progress evidence. Do not delete course content, progress, or certificates.

Correct data issues with a forward migration or compensating progress record; never rewrite historical completion evidence in place. Restore the previous application revision, rerun course API, frontend, and browser checks, and record the commit, tenant, time, reason, and verification result before re-enabling mutations.

Provider video failures must degrade to an actionable unavailable state; they must not mark a lesson complete or issue a certificate.
