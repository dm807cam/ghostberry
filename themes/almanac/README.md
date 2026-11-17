# Almanac

The Ghost theme that ships with [Ghostberry](https://github.com/dm807cam/ghostberry):
a side rail, a serif reading column, and images only where you want them.

- Ghost 5 and 6. Checked with [gscan](https://gscan.ghost.org): no errors, no warnings.
- Light and dark mode (follows the reader's device, or force one in the theme settings).
- Table of contents on posts, built from the `h2` and `h3` headings.
- Styles for every editor card, including wide and full-width images.
- Members: subscribe forms, sign-in and account links, native comments, search.
- Fonts are in `assets/fonts` (SIL Open Font License, see `OFL.txt`). No build step:
  edit `assets/css/screen.css` and the `.hbs` templates directly.

Ghostberry re-installs this theme on every update. To customise it, change
`"name"` in `package.json` and upload it to Ghost as your own theme.

Theme code: MIT, like Ghostberry.
