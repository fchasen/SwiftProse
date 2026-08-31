# Fences

```swift
struct Point {
    var x: Double
    var y: Double
}
```

```javascript
const add = (a, b) => a + b;
console.log(add(1, 2));
```

```css
.editor {
  font-family: -apple-system, sans-serif;
}
```

```html
<div class="editor" data-role="surface">
  <p>hello</p>
</div>
```

```
no info string at all
just three lines
of plain text
```

```text
an info string the highlighter has no grammar for
```

    an indented code block
    second line

Fence inside a list:

- item
  ```swift
  let inner = true
  ```
- next item

Fence inside a quote:

> ```swift
> let quoted = true
> ```

An unterminated fence closes the document:

```swift
let never = "closed"
