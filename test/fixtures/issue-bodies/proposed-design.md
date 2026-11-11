# Idea / context

A record has a nullable `display_name` since #325. Today only one importer fills it, and only the plain text preview shows it. The API already reports `display_name` on every record type, always `null` outside that case.

This issue is for agreeing, as a team, how a display name should show on each record type, and how a user gives one.

# Proposed Design
[Figma](https://www.figma.com/design/Qx7Lm2Fk9Rz/Record-display-name?node-id=11-1219&t=Wd3kPq8ZbT1-1
)
# Acceptance criteria

- [ ] Every record type shows its display name as agreed, and keeps its current title when it has none
- [ ] A user can give a record a display name
  - [ ] afterwards, on an existing version
  - [ ] A display name cannot be empty or only spaces
- [ ] Every record type can be collapsed

