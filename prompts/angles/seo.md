# Angle: SEO

**Scope.** Check changes that affect search-engine discoverability and crawlability. Read `/tmp/pr-review/diff.txt` and `/tmp/pr-review/meta.json`. Only flag issues introduced by this PR.

**Find:**

- `robots.txt` change that blocks production paths that should be crawled, or accidentally allows secrets / staging paths.
- `sitemap.xml` (or `sitemap.ts` in Next.js) drift: URLs added that 404; URLs removed that should remain; broken `lastmod` / `changefreq`.
- Missing or malformed `<title>` on a new page route.
- Missing or duplicated `<meta name="description">`.
- Missing or wrong `<link rel="canonical">` on a new indexable page; canonical pointing to a non-canonical URL.
- Open Graph (`og:title`, `og:description`, `og:image`, `og:url`) missing on a new shareable page.
- Twitter card meta missing or malformed.
- New `noindex` / `nofollow` on a page that should be indexed (or missing on a page that should not be).
- `hreflang` mismatches when changes touch i18n.
- Heading hierarchy regressions on new pages (no `<h1>`, multiple `<h1>`).
- Next.js `metadata` / `generateMetadata` exports that reference broken images, undefined variables, or missing keys for indexable routes.
- New routes lacking server-side rendering when content is meant to be indexed (client-only `useEffect` data fetches for indexable content).

**Skip:**

- Internal admin / authenticated pages — they should not be indexable.
- Style-only changes to existing SEO-correct pages.
- Pre-existing missing metadata not touched by this PR.

**Severity rubric:**

- `HIGH` + `blocking: true` — robots disallow over a production path; sitemap broken; new public page with `noindex`; canonical pointing to wrong host.
- `MEDIUM` + `blocking: false` — missing OG / twitter on a shareable page; missing description; weak title.
- `LOW` + `blocking: false` — heading-hierarchy nit; alt-text suggestion.

**Output.** Write findings as a JSON array to `/tmp/pr-review/findings.seo.json` using the schema in `_header.md`. Each finding gets `"angle": "seo"`.
