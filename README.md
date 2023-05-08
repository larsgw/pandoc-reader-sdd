# SDD reader for Pandoc

A [custom reader](https://pandoc.org/custom-readers.html) for [Pandoc](https://pandoc.org/)
to turn [SDD](https://sdd.tdwg.org/) 1.1 datasets into documents (PDF, LaTeX, HTML, Markdown, etc.).
Requires Pandoc v2.16.2 or later.

Currently it only supports checklists and dichotomous keys (see [Unsupported features](#unsupported-features)).

## Usage

    pandoc -f path/to/sdd.lua [...]

### Examples

    pandoc -f sdd.lua -t html sdd.xml > sdd.html

    pandoc -f sdd.lua -t pdf --pdf-engine=xelatex -V mainfont="Times New Roman" sdd.xml > sdd.pdf

## Supported features

- Metadata (authors, publication date) is read from `<RevisionData>` (respectively `<Creators>`
  and `<DateCreated>`).
- The first `<TaxonHierarchy>` is used to structure the document, and if there is no hierarchy
  specified, the `<TaxonNames` are displayed in order.
- `<IdentifcationKey>`s are displayed before the taxonomy or, if a taxonomic `<Scope>` is specified,
  under the heading belonging to the first `<TaxonName>` in the `<Scope>`.
- The plain text and title belonging to `<NaturalLanguageDescription>`s are displayed under the
  headings of all the `<TaxonName>`s in the `<Scope>`.
- `<MediaObject>`s are displayed the first time they are referenced, in a `<TaxonName>` or `<Lead>`.
  Every `<MediaObject>` is expected to have a caption in the first `<Label>`.
- Taxon names are displayed in short in keys (no authorship, abbreviated generic epithet for
  species); in full in headings (with authorship); and if different the vernacular name is
  listed below the heading. This uses `<Representation>`/`<Label>` for the vernacular/fallback name,
  `<CanonicalName>` (`<Simple>`) and `<CanonicalAuthorship>` for the scientific name, and `<Rank>`
  for determining when to italicize.

### Standard-permitted extensions

Valid extensions, according to the XSD.

- `<MediaObject>`s can have an element `<exif:PixelXDimension>` to specify the image width.

### Standard-disallowed extensions

Invalid extensions, according to the XSD.

- `<Lead>` can have both a `<TaxonName>` and `<Subkey>`, in which case only is the former is
  displayed, under the assumption that the subkey is listed in the heading belonging to the
  `<TaxonName>`.

### Unsupported features

- Only supports one `<Dataset>` per file, as document-level metadata is defined in `<Dataset>`
  and not `<Datasets>`.
- As `xml:lang` is mandatory on `<Dataset>` in SDD 1.1, making multi-language `<Dataset>`s difficult,
  `xml:lang` on sub-elements is not supported and the first label is used.
- Species and sample descriptions (`<CodedDescriptions>`, `<Specimens>`, and `<Characters>`) are not
  yet supported.
- Identifcation keys with `<Question>` are not yet supported.
- Publications (`<Publications>`) are not yet supported.
- The `role` of `<Label>` elements in `<MediaObject>` elements is not yet taken into account.
- The more detailed information that can be entered in `<CanonicalName>`, such as `<Genus>` and
  `<SpecificEpithet>`, is not yet handled.
