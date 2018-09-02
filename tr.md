
## `local tr = require'tr'`

Text shaping and rendering engine for multi-language Unicode text using
portable technologies exclusively for pixel-perfect consistent output
across platforms. Uses [harfbuzz] for complex text shaping, [fribidi] for
bidirectional text, [libunibreak] for line breaking and [freetype] for
glyph rasterization. Used by [ui] for all text rendering.

### Features

  * subpixel positioning
  * OMG color emoticons!
  * word wrapping and alignments
  * hit testing, cursors and selections
  * control over OpenType features
  * cursor positioning and coloring inside ligatures
  * OpenType-assisted auto-hinter enabled in freetype

### Not-yet implemented

  * full justification
  * subscript, superscript
  * underline, strikethrough
  * glyph substitution
  * shaping across words
  * hyphenation
  * letter spacing
  * vertical layout

### API

---------------------------------------------------- ------------------------------------
`tr() -> tr`                                         create a render object
`tr:free()`                                          free the render object
__font management__
`tr:add_font_file(file, ...)`                        add a font file
`tr:add_mem_font(buf, sz, ...)`                      add a font file from a buffer
__layouting__
`tr:flatten(text_tree) -> text_runs`                 flatten a text tree
`tr:shape(text_tree | text_runs) -> segs`            shape a text tree / text runs
`segs:layout(x, y, w, h, [ha], [va]) -> segs`        layout shaped text
`segs:bounding_box() -> x, y, w, h`                  bounding box of laid out text
__rendering__
`segs:paint(cr)`                                     paint laid out text
`tr:textbox(text_tree, cr, x, y, w, h, [ha], [va])`  shape, layout and paint text
__cursors__
`segs:cursor([offset]) -> cursor`                    create a cursor
`cursor:pos() -> x, y, h, rtl`                       cursor position, height and direction
`cursor:set_offset(offset)`                          move cursor to text offset
`cursor:hit_test(x, y, ...) -> off, seg, i, line_i`  hit test
`cursor:move_to(x, y, ...)`                          move cursor to closest position
`cursor:next_cursor([delta]) -> off, seg, i, line_i` next/prev cursor in text
`cursor:move(dir[, delta])`                          move cursor in text
__selections__
`segs:selection() -> sel`                            create a selection
`sel:rectangles(write_func)`                         get selection rectangles
---------------------------------------------------- ------------------------------------

### `tr:add_font_file(file, name, [slant], [weight])`

Register a font file, associating it with a name, slant and weight.

Multiple combinations of (name, weight, slant) can be registered with the
same font. See [freetype] for supported font formats.

The font is not loaded immediately, but it's loaded and unloaded on demand.

### `tr:add_mem_font(buf, sz, [slant], [weight])`

Add a font file from a memory buffer.

### `tr:flatten(text_tree) -> text_runs`

Convert a tree of nested text nodes into a flat array of codepoints and an
accompanying flat list of *text runs* containing metadata for each piece
of text contained in the tree.

The text tree is a list whose elements can be either Lua strings containing
utf-8 text or other text trees. Text tree nodes also contain attributes which
describe how the text should be rendered. All attributes are automatically
inherited from parent nodes and can be overriden in child nodes.

Attributes can be:

  * `font_name`: font name in the format `'family [weight] [slant][, size]'`
  (parsed by `tr_font_db.lua`).
  * `font_size`: font size override.
  * `font_weight`: font weight override: `'bold'`, `'thin'` etc. or a weight
  number between `100` and `900`.
  * `font_slant`: font slant override: `'italic'`, `'normal'`.
  * `bold`, `b`, `italic`, `i`: `font_weight` and `font_slant` overrides.
  * `features`: a list of OpenType features in string form, eg.
  `'+kern -liga smcp'`
  * `script`: an [ISO-15924] script tag (the default is auto-detected).
  * `lang`: a [BCP-47] language-country code (the default is auto-detected).
  * `dir`: `'ltr'`, `'rtl'`, `'auto'`: bidi direction for current and
  subsequent paragraphs.
  * `line_spacing`: line spacing multiplication factor
  (defaults to `1`).
  * `paragraph_spacing`: paragraph spacing multiplication factor
  (defaults to `2`).
  * `nowrap`: disable word wrapping.
  * `color`: a color in format `'#rrggbb'`, `'hsv(h, s, v)'`, etc.
  (see [color] for supported formats; defaults to `tr.rs.default_color`
  which is `'#888'`).
  * `operator`: the cairo operator (defaults to `tr.rs.default_operator`
  which is `'over'`).

[ISO-15924]: https://www.unicode.org/iso15924/iso15924-codes.html

[BCP-47]: https://www.iana.org/assignments/language-subtag-registry/language-subtag-registry

The resulting table contains the text runs in its array part, plus:

  * `codepoints` - the `uint32_t[?]` array of codepoints.
  * `len` - text length in codepoints.

The text runs are set up to inherit their corresponding text tree node,
and also contain the fields:

  * `offset` - offset in the flattened text, in codepoints.
  * `len` - text run length in codepoints.
  * `font`, `font_size` - resolved font object and font size.

NOTE: One text run is always created for each source table, even when there's
no text, in order to anchor the attributes to a segment and to create a
cursor.

NOTE: When flattening, each text node is set up to inherit its parent node
(this might change in a future version since it's not cool to modify user
input in general).

### `tr:shape(text_tree | text_runs) -> segments`

Shape a text tree (flattened or not) into a list of segments.

The segments can be laid out multiple times and must be laid out at least
once in order to be rendered.

### `segments:layout(x, y, w, h, [halign], [valign]) -> segments`

Layout the shaped text using word wrapping so that it fits into the box
described by `x, y, w, h`.

  * `halign` can be `'left'`, `'right'`, `'center'` (defaults to `'left'`).
  * `valign` can be `'top'`, `'bottom'`, `'middle'` (defaults to `'top'`).
  * returns `segments` for chain calling.
  * sets `segments.lines.x` and `segments.lines.y` which can be later changed
  without the need to call `layout()` again.
  * sets `text_runs` for accessing the codepoints.
  * once the text is laid out, it can be painted many times with `paint()`.

### `segments:paint(cr)`

Paint the shaped and laid out text into a graphics context.

When the `tr` object is created, a rasterizer object is created by calling
`tr:create_rasterizer()` which loads the module pointed out by
`tr.rasterizer_module` which defaults to `tr_raster_cairo` which implements
a simple rasterizer which can paint glyphs into a [cairo] context. To paint
glyphs using other graphics APIs you need to implement a new rasterizer.
Glyph caching and the actual rasterization is done in `tr_raster_ft` using
[freetype], so your rasterizer can subclass that and then it only needs to
handle blitting of 8-bit gray and 32-bit BGRA bitmaps and also bitmap scaling
if you use bitmap fonts, since freetype doesn't handle that.

### `tr:textbox(text_tree, cr, x, y, w, h, [halign], [valign]) -> segments`

Shape, layout and paint text. Return segments.

## Rendering stages

#### 1. Text tree flattening

The text comes into the engine in the most convenient form for the user,
which is a tree of nested text nodes, similar to HTML. It is first converted
into a flat array of codepoints and an accompanying list of *text runs*
containing metadata for each piece of text contained in the tree.

#### 2. Itemization and shaping

The flattened text is broken into paragraphs following the `U+2029`
Paragraph Separator marker. The Unicode Bidirectional Algorithm (UBA) is run
for each paragraph, resulting in a series of segments with different
bidirectional *embedding levels* with alternating directionality.

The text is also analyzed for *script* and *language*. The script is
auto-detected from the Unicode General Category class of each character and
the language is auto-detected from the script property of each character.
In addition, text nodes can override these properties for arbitrary portions
of the text using the `script` and `lang` attributes.

The Unicode Line Breaking Algorithm is run for each segment with a different
language (because the algorithm depends on language), resulting in a series of
segments which end at each soft wrap opportunity (whitespace, newline, etc.).

Segments also break whenever the font, font size or OpenType feature list
change.

In the end, segments are formed at the boundaries created by all of the above
segmentation rules and each segment is shaped separately with harfbuzz
resulting in a *glyph run*. Glyph runs are cached so that the same word with
the same combination of font, size, script, language, direction and OpenType
feature list is not shaped multiple times unnecessarily because shaping is
expensive.

A glyph run is a list of glyph indices (in its font), positions and advances
which can be passed directly to a glyph rasterizer for display. Glyph runs
also contain cursor positions (more on that later).

The segments can also contain sub-segments. Segments are formed at the
boundaries of property combinations which require separate shaping.
But text nodes don't necessarily create new segments all by themselves.
In fact it's possible to have two adjacent text nodes together forming a
single word but with a different color for each part of the word. In this
case a single segment with two sub-segments are created. Sub-segments are
created whenever the text node changes, regardless of whether any relevant
attributes actually change.

The end result of segmentation is thus a list of segments, each with its
own glyph run (which may be reused across multiple segments) and its own
list of sub-segments.

#### 3. Layouting

Layouting is the process of fitting and aligning the list of shaped segments
inside a box. First word wrapping is performed on the segments, in logical
order, resulting in a list of *lines*, each containing a list of segments.
Then BiDi reordering (the last part of the UBA) is performed on each line
based on each segment's embedding level, resulting in the segments to
possibly change their order in the line. The last step is horizontal and
vertical alignment of lines as a whole.

A list of segments can be laid out multiple times for different box dimensions
and alignments in O(n). Changing `segments.lines.x` and `segments.lines.y`
can also be done without re-layouting.

#### 4. Rendering

Rendering is the process of rasterizing the glyphs of the glyph runs
individually and then blitting the resulting bitmaps onto a raster surface
at the right positions. The parsing of font files for glyph outlines and the
actual rasterization is done by freetype, with the caveat that bitmap fonts
(emoticons) must be scaled separately because freetype doesn't handle that.
Rasterized/scaled glyphs are cached using a global LRU cache with a
configurable byte-size limit. Scaling and blitting depends on the target
surface and it's thus separated in a subclass of the freetype rasterizer
so that blitters can be created with minimum effort (the current cairo-based
blitter is under 200 LOC).

Rendering can be performed multiple times in O(n).
