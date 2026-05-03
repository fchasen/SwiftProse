/**
 * tree-sitter grammar for Phabricator's Remarkup overlay.
 *
 * This is NOT a complete Remarkup parser — it's an *overlay* meant to run
 * as a second pass alongside `tree-sitter-markdown` on the same source.
 * Markdown handles structure (paragraphs, headings, code blocks, fences,
 * lists, blockquotes); this grammar adds tokens for the Remarkup-specific
 * inline patterns so they become first-class AST nodes that highlights.scm
 * can target:
 *
 *   - //italic//                — Remarkup's italic syntax
 *   - D123, T999                — Phabricator revision / task autolinks
 *   - {F1234}, {P567}           — file / paste embeds (with optional
 *                                 trailing config like `{F1234, layout=…}`)
 *   - @user, @bob.smith         — user mentions
 *   - NOTE: WARNING: IMPORTANT: TODO:
 *                               — callouts (only at start of line — but the
 *                                 grammar is permissive about this; see below)
 *   - ==Heading==               — Remarkup heading syntax
 *
 * Word-boundary handling: the `text` rule's first alternative consumes
 * contiguous alphanumeric runs as a single token. That means `D12` inside
 * `fooD12bar` stays inside the surrounding word run instead of being
 * split out as a `revision_link` — getting word-boundary semantics for
 * free without writing an external scanner.
 *
 * Line-start anchoring (callout, heading): tree-sitter doesn't have a
 * built-in `^` anchor without an external scanner, so the grammar will
 * also accept mid-line matches. Callers can post-filter by checking the
 * preceding character if they want strict line-start behavior.
 */

module.exports = grammar({
  name: 'remarkup',

  extras: $ => [],

  rules: {
    document: $ => repeat($._chunk),

    _chunk: $ => choice(
      $.heading,
      $.callout,
      $.italic,
      $.revision_link,
      $.task_link,
      $.file_embed,
      $.paste_embed,
      $.user_mention,
      $.text,
      $.newline,
    ),

    // Single-token italic: must close on the same line. If the closing `//`
    // isn't there, the whole thing falls back through to text — no half-
    // matched italic state can be entered.
    italic: $ => token(/\/\/[^\/\n]+\/\//),

    revision_link: $ => /D\d+/,

    task_link: $ => /T\d+/,

    file_embed: $ => seq(
      '{F',
      token.immediate(/\d+/),
      optional(token.immediate(/[^}]*/)),
      token.immediate('}'),
    ),

    paste_embed: $ => seq(
      '{P',
      token.immediate(/\d+/),
      optional(token.immediate(/[^}]*/)),
      token.immediate('}'),
    ),

    user_mention: $ => /@[a-zA-Z0-9_.-]+/,

    callout: $ => seq(
      choice('NOTE', 'WARNING', 'IMPORTANT', 'TODO'),
      ':',
    ),

    // Single-token heading. The `[^=\n]+` is non-greedy enough at the
    // tokenizer level (regex anchors via the trailing `={2,}`) that
    // `== title ==` parses cleanly.
    heading: $ => token(/={2,} +[^=\n]+? +={2,}/),

    // Catch-all. First alternative wins on contiguous word characters
    // (so `D12` inside a word stays inside it). Second alternative is the
    // single-char fallback, low precedence — so unclosed `//` etc. fall
    // back to plain text instead of producing a parse error.
    text: $ => choice(
      /[a-zA-Z0-9_]+/,
      token(prec(-1, /./)),
    ),

    newline: $ => '\n',
  },
});
