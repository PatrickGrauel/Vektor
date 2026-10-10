# App Store copy has moved

The current Mac App Store package is [docs/app-store-listing.md](docs/app-store-listing.md), generated from [metadata.json](docs/app-store/metadata.json).

Both earlier listing drafts informed the new copy. Their pilot-first positioning, outdated navigation, purchase claims and privacy assertions were checked against the current `App/` target. See the [code audit](docs/app-store/code-audit.md) for contradictions and the [Apple requirements](docs/app-store/apple-specs.md) for current limits.

- [Positioning and six screenshot recipes](docs/app-store/product-page.md)
- [App Preview storyboard and recording/export pipeline](docs/app-store/app-preview.md)
- [Repeatable screenshot production tooling](docs/app-store/tooling.md)

Do not reuse the older copy from Git history without checking the audit. The current build has purchase gating disabled, has no global summon shortcut, and fetches live rates at launch.
