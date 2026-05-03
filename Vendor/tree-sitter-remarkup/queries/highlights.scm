; Highlight tags for Phabricator's Remarkup overlay.
; Tags map onto Marginalia's `HighlightTag` enum so the same theme
; attributes that style markdown emphasis / links also style Remarkup.

(italic) @text.emphasis

(revision_link) @text.uri
(task_link) @text.uri

(file_embed) @text.uri
(paste_embed) @text.uri

(user_mention) @text.reference

(callout) @text.title
(heading) @text.title
