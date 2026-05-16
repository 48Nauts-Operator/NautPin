# CI Workflow — TODO

The `init-forgejo-repo` skill skipped `.forgejo/workflows/ci.yml` because the upstream `48Nauts/forgejo-ci-workflow` repo doesn't yet ship a Swift recipe (it supports `rust`, `python`, `node`).

## What needs to happen

1. **Provision a macOS runner** on the cosmos NAS Forgejo Actions runner, with Xcode 15+ installed.
2. **Add `swift-ci.yml`** to `48Nauts/forgejo-ci-workflow` as a reusable workflow:
   - Inputs: `scheme` (default `NautPin`), `test-plan` (default `Unit`), `xcode-version` (default `latest`)
   - Steps: checkout → set xcode version → `just build` → `just test`
3. **Add `.forgejo/workflows/ci.yml`** here calling that reusable workflow:
   ```yaml
   name: CI
   on:
     push:
       branches: [main]
     pull_request:

   jobs:
     ci:
       uses: 48Nauts/forgejo-ci-workflow/.forgejo/workflows/swift-ci.yml@main
       with:
         scheme: NautPin
         test-plan: Unit

     incident:
       needs: ci
       if: failure()
       uses: 48Nauts/forgejo-ci-workflow/.forgejo/workflows/_auto-incident.yml@main
       secrets:
         token: ${{ secrets.GITHUB_TOKEN }}
       with:
         assignees: jarvis
   ```

Until then, branch-tracking issues and auto-incident on CI failure are wired up via `.forgejo/workflows/branch-issue.yml`, but actual build/test CI runs locally only.
