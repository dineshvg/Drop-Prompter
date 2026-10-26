# Third-party notices

Shade includes the following open-source software.

## Highlightr

Source code in `Sources/Shade/Highlightr/` is adapted from [Highlightr](https://github.com/raspu/Highlightr)
2.3.0. Changes: themes and highlight.js are loaded from folders chosen by Shade instead of a SwiftPM resource
bundle, custom language files can be registered, and the theme class is renamed to `HighlightTheme`.

```
Copyright (c) 2016 Illanes, Juan Pablo <jpillaness+highlightr@gmail.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## highlight.js

`Resources/Highlighting/highlight.min.js` and the themes in `Resources/Highlighting/themes/` come from
[highlight.js](https://highlightjs.org) 11.11.1, BSD 3-Clause License; see
`Resources/Highlighting/LICENSE-highlight.js.txt`.

## marked

`Resources/Markdown/marked.min.js` comes from [marked](https://marked.js.org) 15.0.12, MIT License, Copyright (c)
2018+ MarkedJS and 2011-2018 Christopher Jeffrey; see `Resources/Markdown/LICENSE-marked.md`.

## SwiftTerm

Terminal cards use [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT License), included as a Swift
package dependency.
