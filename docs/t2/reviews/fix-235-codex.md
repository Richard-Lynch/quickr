**Findings: none.**

The diagnosis is consistent with the code: selecting a question type adds it to the model, while the test’s `scrollTo` helper only drags upward. If the list inserts the card after the first drag, the helper can pass it and never return. The committed results show the failure before the change and ten passing repetitions of the affected test afterward; they do not independently establish the precise rendering delay.

The fix waits for the new card before scrolling. It does not retry the action or typing: the test still enters “Glasses” once and asserts that the created topic opens its record screen with the expected field.

`newTopic.q0.header` exists: the first card builds its identifier from the `newTopic` prefix and index zero, and attaches it to the card’s header button. It is an appropriate readiness signal for both callers, including the largest-text-size test, where the label can initially be below the screen.

A user could notice the delayed appearance or need to scroll back if they scroll immediately after adding a question. The evidence supports a test scrolling race, but does not establish that the delay causes a persistent user-facing app defect. I did not rerun the simulator tests for this review.