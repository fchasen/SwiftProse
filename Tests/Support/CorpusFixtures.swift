import Foundation

package struct CorpusSample: Sendable {
    package let name: String
    package let source: String
    package let expected: String

    package init(_ name: String, _ source: String, expected: String? = nil) {
        self.name = name
        self.source = source
        self.expected = expected ?? source
    }

    package var isCanonical: Bool { source == expected }
    package var testDescription: String { name }
}

package enum CorpusFixtures {
    package static let bugzilla: [CorpusSample] = [
        CorpusSample("steps to reproduce", #"""
        Steps to reproduce:

        1. Open `about:preferences`
        2. Click **Privacy & Security**
        3. Toggle *Enhanced Tracking Protection*

        Actual results:

        The toggle resets after a restart.

        Expected results:

        The setting persists.
        """#),
        CorpusSample("crash stack", #"""
        This crashes on startup with the following stack:

        ```
        #0 mozilla::dom::Element::GetAttr(int, nsAtom*, nsAString&) const
        #1 nsGenericHTMLElement::GetURIAttr(nsAtom*, nsAtom*, nsIURI**) const
        #2 0x00007ff6`a1b2c3d4
        ```

        Regressed by bug 1234567. See https://crash-stats.mozilla.org/report/index/0a1b2c3d-4e5f-6789-abcd-ef0123456789 for details.
        """#),
        CorpusSample("reply with quote", #"""
        (In reply to Jane Doe [:jane] from comment #4)

        > Can we land this before the merge?
        >
        > It blocks the release.

        Yes, the patch is ready. See D123456.
        """#),
        CorpusSample("status checklist and table", #"""
        ## Status

        - [x] Patch reviewed
        - [ ] Uplift requested
          - [ ] Beta
          - [ ] ESR

        | Branch | Status |
        | --- | --- |
        | beta | affected |
        | release | unaffected |
        """#),
        CorpusSample("regression range", #"""
        Regression window:

        - Last good: 2026-09-01
        - First bad: 2026-09-02
        - Pushlog: https://hg.mozilla.org/integration/autoland/pushloghtml?fromchange=abc&tochange=def

        ### Profile

        https://share.firefox.dev/3abcdEF
        """#),
        CorpusSample("multibyte and emoji", #"""
        日本語の**テキスト**と 👨‍👩‍👧 emoji, café, naïve, and Ελληνικά.

        > 引用された*テキスト*
        """#),
        CorpusSample("escapes and entities", #"""
        Use \*literal\* stars, a backslash \\ and &amp; &lt;tags&gt; &copy; &#169; &#x41;.
        """#),
        CorpusSample("hard and soft breaks", "Line one  \nline two\nline three\n\nNext paragraph"),
        CorpusSample("nested containers", #"""
        > - quoted item
        >   - nested item
        >
        >     continuation paragraph
        > - second
        >
        > ```js
        > let x = 1;
        > ```
        """#),
        CorpusSample("ordered with continuation", #"""
        3. Three

           More about three.
        4. Four
           ```sh
           ./mach build
           ```
        5. Five
        """#),
        CorpusSample("thematic break styles", "Above\n\n***\n\nMiddle\n\n___\n\nBelow\n\n* * *\n\nEnd"),
        CorpusSample("html block and inline html", #"""
        <details>
        <summary>Log</summary>
        output
        </details>

        Press <kbd>Ctrl</kbd>+<kbd>C</kbd>.
        """#),
        CorpusSample("inline marks", #"""
        **Bold**, *italic*, ***both***, ~~struck~~, `code`, **a *b* c**, **a _b_**, and [a **link**](https://bugzilla.mozilla.org/show_bug.cgi?id=1).
        """#),
        CorpusSample("code span backticks", "Use ``a`b`` and `` `x` `` here."),
        CorpusSample("image", "Screenshot: ![the toolbar](https://bug1234567.bmoattachments.org/attachment.cgi?id=999)"),
        CorpusSample("fence inside fence", "````md\n```\ninner\n```\n````"),
        CorpusSample("escapes before bare url", "a \\*b\\* https://x.com &amp; end"),
        CorpusSample("escapes after leading bare url", "https://x.com then \\*b\\* &amp;"),
        CorpusSample("email addresses", "Reporter: me@x.com and you@y.org, cc \\*a\\*"),
        CorpusSample("code at link label edges", "See [`c` b](https://e.com), [b `c`](https://e.com) and [`word`](https://e.com/p)."),
        CorpusSample("empty fences", "Before\n\n```js\n```\n\n- a\n  ```\n  ```\n- b\n\n> ```\n> ```"),
        CorpusSample("blocks inside items", "- item\n\n  | a | b |\n  | --- | --- |\n  | 1 | 2 |\n- html\n\n  <div>\n  x\n  </div>\n- [x] **done** task with `code`"),
        CorpusSample("nested ordered lists", "1. a\n   1. b\n      1. c\n\n> 3. three\n> 4. four\n\n100. hundred\n101. next"),
        CorpusSample("quoted heading and rule", "> # Heading in quote\n>\n> text\n>\n> ***\n>\n> after"),
        CorpusSample("image inside link", "[![img](https://x.com/i.png)](https://x.com)"),
        CorpusSample("intraword marks", "**a**b a**b** *a*b a*b* _a_b x ~~~ y"),
        CorpusSample("email at line start", "dev@mozilla.org\nnext line &amp; more"),
        CorpusSample("indented code", "    let x = 1\n    print(x)"),
    ]

    package static let phabricator: [CorpusSample] = [
        CorpusSample("review nit", #"""
        nit: Please use `const auto&` here.

        > Why not `std::move`?

        Because the value is reused below:

        ```cpp
        auto value = Compute();
        Use(value);
        UseAgain(value);
        ```
        """#),
        CorpusSample("summary with test plan", #"""
        This patch moves the parser off the main thread.

        # Test Plan

        - `./mach test dom/base/test`
        - Manual: load a large page

        Depends on D111111.
        """#),
        CorpusSample("headings", "# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six"),
    ]

    package static let remarkupDrafts: [CorpusSample] = [
        CorpusSample("remarkup italic and mono", "This is //italic// and ##monospaced## text."),
        CorpusSample("remarkup link", "See [[https://example.com/docs | the docs]] for more."),
        CorpusSample("remarkup link with underscores", "[[https://example.com/a_b_c | snake_case link]]"),
        CorpusSample("remarkup label", "{nav,  icon=file, name=Ready} Looks good with one nit."),
        CorpusSample("remarkup label mid-line", "Thanks! {nav icon=check, name=Accepted} and //done//."),
        CorpusSample("remarkup object refs", "{F12345} {D99} {T1, size=full} [[D1234]] T5678 rMOZILLACENTRAL123 @fred"),
        CorpusSample("remarkup mixed", "**Bold** remarkup, //italic//, ~~strike~~, and `inline` code."),
        CorpusSample("remarkup multi-line", "Lines in remarkup\njust wrap like this\n\n= Heading-like text ="),
    ]

    package static var canonical: [CorpusSample] {
        (bugzilla + phabricator + remarkupDrafts).filter(\.isCanonical)
    }

    package static let canonicalizing: [CorpusSample] = [
        CorpusSample("compact table", "| a | b |\n|---|:-:|\n| 1 | 2 |", expected: "| a | b |\n| --- | :---: |\n| 1 | 2 |"),
        CorpusSample("padded table", "| Name   | Value |\n| :----- | ----: |\n| x      |     1 |", expected: "| Name | Value |\n| :--- | ---: |\n| x | 1 |"),
        CorpusSample("pipeless table", "a | b\n--|--\n1 | 2", expected: "| a | b |\n| --- | --- |\n| 1 | 2 |"),
        CorpusSample("ragged table rows", "| a | b |\n| --- | --- |\n| 1 |\n| 1 | 2 | 3 |", expected: "| a | b |\n| --- | --- |\n| 1 | |\n| 1 | 2 |"),
        CorpusSample("star bullets", "* star\n* list", expected: "- star\n- list"),
        CorpusSample("plus bullets", "+ plus\n+ list", expected: "- plus\n- list"),
        CorpusSample("setext h1", "Setext\n======", expected: "# Setext"),
        CorpusSample("closing hashes", "# Title #\n\n## Two ##", expected: "# Title\n\n## Two"),
        CorpusSample("angle autolinks", "<https://angle.com> and <me@x.com>", expected: "https://angle.com and me@x.com"),
        CorpusSample("reference link", "[ref][r]\n\n[r]: https://r.com", expected: "[ref](https://r.com)"),
        CorpusSample("backslash hard break", "Back\\\nslash", expected: "Back  \nslash"),
        CorpusSample("lazy quote continuation", "> quote\nlazy", expected: "> quote\n> lazy"),
        CorpusSample("lazy nested quote continuation", "> > nested\n> back", expected: "> > nested\n> > back"),
        CorpusSample("renumbered ordered list", "1. a\n1. b\n1. c", expected: "1. a\n2. b\n3. c"),
        CorpusSample("sequential ordinals", "3. three\n4. four\n10. ten", expected: "3. three\n4. four\n5. ten"),
        CorpusSample("paren ordered list", "1) paren\n2) list", expected: "1. paren\n2. list"),
        CorpusSample("loose list tightens", "- a\n- b\n\n- c", expected: "- a\n- b\n- c"),
        CorpusSample("deep indent sublist", "- a\n    - deep\n- b", expected: "- a\n  - deep\n- b"),
        CorpusSample("tilde fence", "~~~py\ncode\n~~~", expected: "```py\ncode\n```"),
        CorpusSample("unterminated fence", "```\nunterminated", expected: "```\nunterminated\n```"),
        CorpusSample("extra blank lines", "Para\n\n\n\nPara2", expected: "Para\n\nPara2"),
        CorpusSample("list interrupting paragraph", "STR:\n1. Open Firefox\n2. Crash", expected: "STR:\n\n1. Open Firefox\n2. Crash"),
        CorpusSample("quote after attribution line", "(In reply to Fred from comment #3)\n> Some quote\n\nReply.", expected: "(In reply to Fred from comment #3)\n\n> Some quote\n\nReply."),
        CorpusSample("heading after paragraph", "Ends with heading\n# H", expected: "Ends with heading\n\n# H"),
        CorpusSample("thematic break between lines", "a\n***\nb", expected: "a\n\n***\n\nb"),
        CorpusSample("blank before fence in item", "- a\n\n  ```swift\n  code\n  ```\n- b", expected: "- a\n  ```swift\n  code\n  ```\n- b"),
        CorpusSample("link title dropped", "[t](https://x.com \"Title\")", expected: "[t](https://x.com)"),
        CorpusSample("marks hoisted over link", "[**bold link**](https://x.com)", expected: "**[bold link](https://x.com)**"),
        CorpusSample("lazy quote line keeps literals", "> quote \\*a\\*\nlazy \\*b\\* &amp;", expected: "> quote \\*a\\*\n> lazy \\*b\\* &amp;"),
        CorpusSample("lazy item line keeps literals", "- item \\*a\\*\nlazy \\*b\\*", expected: "- item \\*a\\*\n  lazy \\*b\\*"),
        CorpusSample("blank line before fence in item", "- a\n\n  ```\n  ```", expected: "- a\n  ```\n  ```"),
        CorpusSample("fence holding one blank line", "```\n\n```", expected: "```\n```"),
        CorpusSample("marks split at soft breaks", "**bold\nacross lines**", expected: "**bold**\n**across lines**"),
        CorpusSample("single tilde strike", "~one~", expected: "~~one~~"),
        CorpusSample("trailing empty item", "- a\n-", expected: "- a"),
        CorpusSample("empty heading", "# \n\nx", expected: "x"),
        CorpusSample("trailing blank lines", "Body\n\n\n", expected: "Body"),
        CorpusSample("crlf", "a\r\nb\r\n\r\nc", expected: "a\nb\n\nc"),
        CorpusSample("splinter review", #"""
        Comment on attachment 123
        Patch v1

        Review of attachment 123:
        -----------------------------------------------------------------

        ::: dom/base/foo.cpp
        @@ -1,3 +1,4 @@
        > line

        nit: fix
        """#, expected: #"""
        Comment on attachment 123
        Patch v1

        ## Review of attachment 123:

        ::: dom/base/foo.cpp
        @@ -1,3 +1,4 @@

        > line

        nit: fix
        """#),
    ]
}
