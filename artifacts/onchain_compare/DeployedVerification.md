| Version | Simulated preOpGas (deployed) |
|---|---:|
| v1.0.0 | 43106 |
| v1.1.0 | 42921 |
| v1.1.0-sim | 42915 |

- Deltas (vs v1.1.0):
  - v1.0.0: +185 (+0.4%)
  - v1.1.0-sim: -6 (≈0.0%)

Notes
- Values are from EntryPoint v0.6 simulation using simulateHandleOp(op, target=0, data=0) and reading ExecutionResult.preOpGas (validation-only).
- These numbers are for deployed accounts (no initCode). For initCode (first-deploy), use simulateHandleOp and treat preOpGas as a lower-bound and apply a policy buffer, since deployment and postOp are not included in preOpGas.***

