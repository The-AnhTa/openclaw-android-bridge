# Dependency audit

Dependency security findings are recorded separately so transport work does not
silently change the pinned automation stack.

## 2026-10-06

The repository-root commands were:

```powershell
npm audit
npm audit --omit=dev
```

Both reported 26 findings in the pinned production dependency graph:

| Severity | Count |
| --- | ---: |
| Low | 1 |
| Moderate | 2 |
| High | 22 |
| Critical | 1 |

The critical transitive finding was reported against `proxy-addr`. npm also
reported `appium-mcp` as a directly affected high-severity dependency and
suggested a version change that conflicts with the required 1.95.0 pin.

The separate VM client dependency graph reported zero vulnerabilities when its
lockfile was generated and again after adding pinned development bundler
`esbuild` 0.28.2. The bundler runs only on the laptop/development machine; its
single-file output requires only Node.js 22 or newer on the VM. No
`npm audit fix`, dependency upgrade, downgrade, or transitive override was
applied during Milestone 3.
