1. **Primary rule:** No finding.

2. **Display order, roles and Skip:** No finding.

3. **Kinds and stable IDs:** No finding. Both definitions contain all 11 kinds and assign the specified IDs.

4. **Signatures:** No finding.

5. **Table coverage:** No finding. Both suites cover the rows expressible with today’s types: rows 4–9 and 12, plus the approved stub result for row 13. No expressible row is untested.

6. **Scope and existing callers:** No finding. `RunPanel.tsx` and `RunTile.tsx` are outside the listed areas, but contain only the approved rename to `primaryActionV1`; the existing caller behavior is unchanged.

7. **Swift/TypeScript divergence:** No finding.

8. **Code quality:** No finding. The TypeScript `void` statements and targeted eslint suppressions account for parameters reserved by the required signatures.

This review is based on inspection of the diff and referenced specs; I did not run the test suites.