# Idea / context
Rating scales can soon have up to 10 levels with longer names (25). This is in ticket #844. The row of clickable levels used to pick a level needs to keep working with that many levels.

# Acceptance criteria
- The level picker shows up to 10 levels in one row
- When the levels no longer fit at a comfortable clickable size (at least 24×24px), the picker switches to the compact version:
  - each level is a box of equal size
  - the chosen level shows only a checkmark
- This works in all contexts we show the level selector:
  - when giving a review
  - on the results page



## Design
[See design (default) ](https://www.figma.com/design/Hn4Tc8Vw2Ys/Rating-levels--characters---availability?node-id=14-1083&t=Kb5mJr7NxQ2-1)and [design (compact).](https://www.figma.com/design/Hn4Tc8Vw2Ys/Rating-levels--characters---availability?node-id=14-1864&t=Kb5mJr7NxQ2-1)

## Additional test plan
Check these screens with, levels will need to stay readable and usable:
- [ ] The preview table on the rating scale page
- [ ] The summary step when requesting a review

Don't forget to test accessibility (non-exhaustive list):
- [ ] The feature is keyboard accessible, the focus ring is always entirely visible
- [ ] Check that [axe DevTools](https://www.notion.so/acme/Browser-extensions-80a079efc2cf48d28d2fe5c6863ee423?p=b19ee2d057404db8&pm=s) don't show any errors

## Developer notes
Behind feature flag `rating_level_improvements`
