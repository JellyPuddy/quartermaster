# Idea / context
We allowed coaches to select other roles in #639 , now we will add the progress information for these roles.
<!-- If the title of the issue is not self-explanatory,
explain here what the feature is about, and why we want to build that. -->

# Acceptance criteria
- For any selected and applied roles, we show the **weighted average** up until today (default).
- Every bar has a role icon, and a tooltip on the icon & bar itself: ‘Role: x%’
  - If a role has no data (for the selected date), we show an empty bar with an ‘empty’ icon.
<!-- List what should be possible once this issue is complete. This is what the tester should test. -->

## Design
[Design](https://www.figma.com/design/Zp2Rg6Hd8Lc/Coach-dashboard?node-id=153-11805&p=f&t=Vm9xTq4LsB0-0)
[High Contrast Design](https://www.figma.com/design/Zp2Rg6Hd8Lc/Coach-dashboard?node-id=513-5984&t=Np7cWe3HjA1-1)

<!--
## Additional test plan
If this ticket involves adding a modal, please check it follows the modal guidelines:
https://app.notion.com/p/acme/Design-component-guidelines-31fb2d0ad7f680a2b2eae88c35e71e85?source=copy_link#3b3b2d0ad7f68067


Don't forget to test accessibility (non-exhaustive list):
- [ ] The feature is keyboard accessible, the focus ring is always entirely visible
- [ ] Check that [axe DevTools](https://www.notion.so/acme/Browser-extensions-80a079efc2cf48d28d2fe5c6863ee423?p=b19ee2d057404db8&pm=s) don't show any errors
-->

# Development notes
<!-- Should this be behind a feature flag? -->
Feature flag `coach_dashboard_roles` and this Feature flag should be behind the feature flag `new_coach_dashboard`

<!-- Decisions on architecture (link to diagram?), API documentation, model names... -->

<!-- # Out of scope -->
<!-- To avoid colleagues asking "and what about...?", list here what is out of scope for this feature. -->
