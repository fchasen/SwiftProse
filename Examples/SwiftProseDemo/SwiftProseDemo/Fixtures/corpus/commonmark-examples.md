# CommonMark 0.31.2 examples

## Tabs

### Example 1
	foo	baz		bim

### Example 2
  	foo	baz		bim

### Example 3
    a	a
    ὐ	a

### Example 4
  - foo

	bar

### Example 5
- foo

		bar

### Example 6
>		foo

### Example 7
-		foo

### Example 8
    foo
	bar

### Example 9
 - foo
   - bar
	 - baz

### Example 10
#	Foo

### Example 11
*	*	*	

## Backslash escapes

### Example 12
\!\"\#\$\%\&\'\(\)\*\+\,\-\.\/\:\;\<\=\>\?\@\[\\\]\^\_\`\{\|\}\~

### Example 13
\	\A\a\ \3\φ\«

### Example 14
\*not emphasized*
\<br/> not a tag
\[not a link](/foo)
\`not code`
1\. not a list
\* not a list
\# not a heading
\[foo]: /url "not a reference"
\&ouml; not a character entity

### Example 15
\\*emphasis*

### Example 16
foo\
bar

### Example 17
`` \[\` ``

### Example 18
    \[\]

### Example 19
~~~
\[\]
~~~

### Example 20
<https://example.com?find=\*>

### Example 21
<a href="/bar\/)">

### Example 22
[foo](/bar\* "ti\*tle")

### Example 23
[foo]

[foo]: /bar\* "ti\*tle"

### Example 24
``` foo\+bar
foo
```

## Entity and numeric character references

### Example 25
&nbsp; &amp; &copy; &AElig; &Dcaron;
&frac34; &HilbertSpace; &DifferentialD;
&ClockwiseContourIntegral; &ngE;

### Example 26
&#35; &#1234; &#992; &#0;

### Example 27
&#X22; &#XD06; &#xcab;

### Example 28
&nbsp &x; &#; &#x;
&#87654321;
&#abcdef0;
&ThisIsNotDefined; &hi?;

### Example 29
&copy

### Example 30
&MadeUpEntity;

### Example 31
<a href="&ouml;&ouml;.html">

### Example 32
[foo](/f&ouml;&ouml; "f&ouml;&ouml;")

### Example 33
[foo]

[foo]: /f&ouml;&ouml; "f&ouml;&ouml;"

### Example 34
``` f&ouml;&ouml;
foo
```

### Example 35
`f&ouml;&ouml;`

### Example 36
    f&ouml;f&ouml;

### Example 37
&#42;foo&#42;
*foo*

### Example 38
&#42; foo

* foo

### Example 39
foo&#10;&#10;bar

### Example 40
&#9;foo

### Example 41
[a](url &quot;tit&quot;)

## Precedence

### Example 42
- `one
- two`

## Thematic breaks

### Example 43
***
---
___

### Example 44
+++

### Example 45
===

### Example 46
--
**
__

### Example 47
 ***
  ***
   ***

### Example 48
    ***

### Example 49
Foo
    ***

### Example 50
_____________________________________

### Example 51
 - - -

### Example 52
 **  * ** * ** * **

### Example 53
-     -      -      -

### Example 54
- - - -    

### Example 55
_ _ _ _ a

a------

---a---

### Example 56
 *-*

### Example 57
- foo
***
- bar

### Example 58
Foo
***
bar

### Example 59
Foo
---
bar

### Example 60
* Foo
* * *
* Bar

### Example 61
- Foo
- * * *

## ATX headings

### Example 62
# foo
## foo
### foo
#### foo
##### foo
###### foo

### Example 63
####### foo

### Example 64
#5 bolt

#hashtag

### Example 65
\## foo

### Example 66
# foo *bar* \*baz\*

### Example 67
#                  foo                     

### Example 68
 ### foo
  ## foo
   # foo

### Example 69
    # foo

### Example 70
foo
    # bar

### Example 71
## foo ##
  ###   bar    ###

### Example 72
# foo ##################################
##### foo ##

### Example 73
### foo ###     

### Example 74
### foo ### b

### Example 75
# foo#

### Example 76
### foo \###
## foo #\##
# foo \#

### Example 77
****
## foo
****

### Example 78
Foo bar
# baz
Bar foo

### Example 79
## 
#
### ###

## Setext headings

### Example 80
Foo *bar*
=========

Foo *bar*
---------

### Example 81
Foo *bar
baz*
====

### Example 82
  Foo *bar
baz*	
====

### Example 83
Foo
-------------------------

Foo
=

### Example 84
   Foo
---

  Foo
-----

  Foo
  ===

### Example 85
    Foo
    ---

    Foo
---

### Example 86
Foo
   ----      

### Example 87
Foo
    ---

### Example 88
Foo
= =

Foo
--- -

### Example 89
Foo  
-----

### Example 90
Foo\
----

### Example 91
`Foo
----
`

<a title="a lot
---
of dashes"/>

### Example 92
> Foo
---

### Example 93
> foo
bar
===

### Example 94
- Foo
---

### Example 95
Foo
Bar
---

### Example 96
---
Foo
---
Bar
---
Baz

### Example 97

====

### Example 98
---
---

### Example 99
- foo
-----

### Example 100
    foo
---

### Example 101
> foo
-----

### Example 102
\> foo
------

### Example 103
Foo

bar
---
baz

### Example 104
Foo
bar

---

baz

### Example 105
Foo
bar
* * *
baz

### Example 106
Foo
bar
\---
baz

## Indented code blocks

### Example 107
    a simple
      indented code block

### Example 108
  - foo

    bar

### Example 109
1.  foo

    - bar

### Example 110
    <a/>
    *hi*

    - one

### Example 111
    chunk1

    chunk2
  
 
 
    chunk3

### Example 112
    chunk1
      
      chunk2

### Example 113
Foo
    bar


### Example 114
    foo
bar

### Example 115
# Heading
    foo
Heading
------
    foo
----

### Example 116
        foo
    bar

### Example 117

    
    foo
    


### Example 118
    foo  

## Fenced code blocks

### Example 119
```
<
 >
```

### Example 120
~~~
<
 >
~~~

### Example 121
``
foo
``

### Example 122
```
aaa
~~~
```

### Example 123
~~~
aaa
```
~~~

### Example 124
````
aaa
```
``````

### Example 125
~~~~
aaa
~~~
~~~~

### Example 126
```

### Example 127
`````

```
aaa

### Example 128
> ```
> aaa

bbb

### Example 129
```

  
```

### Example 130
```
```

### Example 131
 ```
 aaa
aaa
```

### Example 132
  ```
aaa
  aaa
aaa
  ```

### Example 133
   ```
   aaa
    aaa
  aaa
   ```

### Example 134
    ```
    aaa
    ```

### Example 135
```
aaa
  ```

### Example 136
   ```
aaa
  ```

### Example 137
```
aaa
    ```

### Example 138
``` ```
aaa

### Example 139
~~~~~~
aaa
~~~ ~~

### Example 140
foo
```
bar
```
baz

### Example 141
foo
---
~~~
bar
~~~
# baz

### Example 142
```ruby
def foo(x)
  return 3
end
```

### Example 143
~~~~    ruby startline=3 $%@#$
def foo(x)
  return 3
end
~~~~~~~

### Example 144
````;
````

### Example 145
``` aa ```
foo

### Example 146
~~~ aa ``` ~~~
foo
~~~

### Example 147
```
``` aaa
```

## HTML blocks

### Example 148
<table><tr><td>
<pre>
**Hello**,

_world_.
</pre>
</td></tr></table>

### Example 149
<table>
  <tr>
    <td>
           hi
    </td>
  </tr>
</table>

okay.

### Example 150
 <div>
  *hello*
         <foo><a>

### Example 151
</div>
*foo*

### Example 152
<DIV CLASS="foo">

*Markdown*

</DIV>

### Example 153
<div id="foo"
  class="bar">
</div>

### Example 154
<div id="foo" class="bar
  baz">
</div>

### Example 155
<div>
*foo*

*bar*

### Example 156
<div id="foo"
*hi*

### Example 157
<div class
foo

### Example 158
<div *???-&&&-<---
*foo*

### Example 159
<div><a href="bar">*foo*</a></div>

### Example 160
<table><tr><td>
foo
</td></tr></table>

### Example 161
<div></div>
``` c
int x = 33;
```

### Example 162
<a href="foo">
*bar*
</a>

### Example 163
<Warning>
*bar*
</Warning>

### Example 164
<i class="foo">
*bar*
</i>

### Example 165
</ins>
*bar*

### Example 166
<del>
*foo*
</del>

### Example 167
<del>

*foo*

</del>

### Example 168
<del>*foo*</del>

### Example 169
<pre language="haskell"><code>
import Text.HTML.TagSoup

main :: IO ()
main = print $ parseTags tags
</code></pre>
okay

### Example 170
<script type="text/javascript">
// JavaScript example

document.getElementById("demo").innerHTML = "Hello JavaScript!";
</script>
okay

### Example 171
<textarea>

*foo*

_bar_

</textarea>

### Example 172
<style
  type="text/css">
h1 {color:red;}

p {color:blue;}
</style>
okay

### Example 173
<style
  type="text/css">

foo

### Example 174
> <div>
> foo

bar

### Example 175
- <div>
- foo

### Example 176
<style>p{color:red;}</style>
*foo*

### Example 177
<!-- foo -->*bar*
*baz*

### Example 178
<script>
foo
</script>1. *bar*

### Example 179
<!-- Foo

bar
   baz -->
okay

### Example 180
<?php

  echo '>';

?>
okay

### Example 181
<!DOCTYPE html>

### Example 182
<![CDATA[
function matchwo(a,b)
{
  if (a < b && a < 0) then {
    return 1;

  } else {

    return 0;
  }
}
]]>
okay

### Example 183
  <!-- foo -->

    <!-- foo -->

### Example 184
  <div>

    <div>

### Example 185
Foo
<div>
bar
</div>

### Example 186
<div>
bar
</div>
*foo*

### Example 187
Foo
<a href="bar">
baz

### Example 188
<div>

*Emphasized* text.

</div>

### Example 189
<div>
*Emphasized* text.
</div>

### Example 190
<table>

<tr>

<td>
Hi
</td>

</tr>

</table>

### Example 191
<table>

  <tr>

    <td>
      Hi
    </td>

  </tr>

</table>

## Link reference definitions

### Example 192
[foo]: /url "title"

[foo]

### Example 193
   [foo]: 
      /url  
           'the title'  

[foo]

### Example 194
[Foo*bar\]]:my_(url) 'title (with parens)'

[Foo*bar\]]

### Example 195
[Foo bar]:
<my url>
'title'

[Foo bar]

### Example 196
[foo]: /url '
title
line1
line2
'

[foo]

### Example 197
[foo]: /url 'title

with blank line'

[foo]

### Example 198
[foo]:
/url

[foo]

### Example 199
[foo]:

[foo]

### Example 200
[foo]: <>

[foo]

### Example 201
[foo]: <bar>(baz)

[foo]

### Example 202
[foo]: /url\bar\*baz "foo\"bar\baz"

[foo]

### Example 203
[foo]

[foo]: url

### Example 204
[foo]

[foo]: first
[foo]: second

### Example 205
[FOO]: /url

[Foo]

### Example 206
[ΑΓΩ]: /φου

[αγω]

### Example 207
[foo]: /url

### Example 208
[
foo
]: /url
bar

### Example 209
[foo]: /url "title" ok

### Example 210
[foo]: /url
"title" ok

### Example 211
    [foo]: /url "title"

[foo]

### Example 212
```
[foo]: /url
```

[foo]

### Example 213
Foo
[bar]: /baz

[bar]

### Example 214
# [Foo]
[foo]: /url
> bar

### Example 215
[foo]: /url
bar
===
[foo]

### Example 216
[foo]: /url
===
[foo]

### Example 217
[foo]: /foo-url "foo"
[bar]: /bar-url
  "bar"
[baz]: /baz-url

[foo],
[bar],
[baz]

### Example 218
[foo]

> [foo]: /url

## Paragraphs

### Example 219
aaa

bbb

### Example 220
aaa
bbb

ccc
ddd

### Example 221
aaa


bbb

### Example 222
  aaa
 bbb

### Example 223
aaa
             bbb
                                       ccc

### Example 224
   aaa
bbb

### Example 225
    aaa
bbb

### Example 226
aaa     
bbb     

## Blank lines

### Example 227
  

aaa
  

# aaa

  

## Block quotes

### Example 228
> # Foo
> bar
> baz

### Example 229
># Foo
>bar
> baz

### Example 230
   > # Foo
   > bar
 > baz

### Example 231
    > # Foo
    > bar
    > baz

### Example 232
> # Foo
> bar
baz

### Example 233
> bar
baz
> foo

### Example 234
> foo
---

### Example 235
> - foo
- bar

### Example 236
>     foo
    bar

### Example 237
> ```
foo
```

### Example 238
> foo
    - bar

### Example 239
>

### Example 240
>
>  
> 

### Example 241
>
> foo
>  

### Example 242
> foo

> bar

### Example 243
> foo
> bar

### Example 244
> foo
>
> bar

### Example 245
foo
> bar

### Example 246
> aaa
***
> bbb

### Example 247
> bar
baz

### Example 248
> bar

baz

### Example 249
> bar
>
baz

### Example 250
> > > foo
bar

### Example 251
>>> foo
> bar
>>baz

### Example 252
>     code

>    not code

## List items

### Example 253
A paragraph
with two lines.

    indented code

> A block quote.

### Example 254
1.  A paragraph
    with two lines.

        indented code

    > A block quote.

### Example 255
- one

 two

### Example 256
- one

  two

### Example 257
 -    one

     two

### Example 258
 -    one

      two

### Example 259
   > > 1.  one
>>
>>     two

### Example 260
>>- one
>>
  >  > two

### Example 261
-one

2.two

### Example 262
- foo


  bar

### Example 263
1.  foo

    ```
    bar
    ```

    baz

    > bam

### Example 264
- Foo

      bar


      baz

### Example 265
123456789. ok

### Example 266
1234567890. not ok

### Example 267
0. ok

### Example 268
003. ok

### Example 269
-1. not ok

### Example 270
- foo

      bar

### Example 271
  10.  foo

           bar

### Example 272
    indented code

paragraph

    more code

### Example 273
1.     indented code

   paragraph

       more code

### Example 274
1.      indented code

   paragraph

       more code

### Example 275
   foo

bar

### Example 276
-    foo

  bar

### Example 277
-  foo

   bar

### Example 278
-
  foo
-
  ```
  bar
  ```
-
      baz

### Example 279
-   
  foo

### Example 280
-

  foo

### Example 281
- foo
-
- bar

### Example 282
- foo
-   
- bar

### Example 283
1. foo
2.
3. bar

### Example 284
*

### Example 285
foo
*

foo
1.

### Example 286
 1.  A paragraph
     with two lines.

         indented code

     > A block quote.

### Example 287
  1.  A paragraph
      with two lines.

          indented code

      > A block quote.

### Example 288
   1.  A paragraph
       with two lines.

           indented code

       > A block quote.

### Example 289
    1.  A paragraph
        with two lines.

            indented code

        > A block quote.

### Example 290
  1.  A paragraph
with two lines.

          indented code

      > A block quote.

### Example 291
  1.  A paragraph
    with two lines.

### Example 292
> 1. > Blockquote
continued here.

### Example 293
> 1. > Blockquote
> continued here.

### Example 294
- foo
  - bar
    - baz
      - boo

### Example 295
- foo
 - bar
  - baz
   - boo

### Example 296
10) foo
    - bar

### Example 297
10) foo
   - bar

### Example 298
- - foo

### Example 299
1. - 2. foo

### Example 300
- # Foo
- Bar
  ---
  baz

## Lists

### Example 301
- foo
- bar
+ baz

### Example 302
1. foo
2. bar
3) baz

### Example 303
Foo
- bar
- baz

### Example 304
The number of windows in my house is
14.  The number of doors is 6.

### Example 305
The number of windows in my house is
1.  The number of doors is 6.

### Example 306
- foo

- bar


- baz

### Example 307
- foo
  - bar
    - baz


      bim

### Example 308
- foo
- bar

<!-- -->

- baz
- bim

### Example 309
-   foo

    notcode

-   foo

<!-- -->

    code

### Example 310
- a
 - b
  - c
   - d
  - e
 - f
- g

### Example 311
1. a

  2. b

   3. c

### Example 312
- a
 - b
  - c
   - d
    - e

### Example 313
1. a

  2. b

    3. c

### Example 314
- a
- b

- c

### Example 315
* a
*

* c

### Example 316
- a
- b

  c
- d

### Example 317
- a
- b

  [ref]: /url
- d

### Example 318
- a
- ```
  b


  ```
- c

### Example 319
- a
  - b

    c
- d

### Example 320
* a
  > b
  >
* c

### Example 321
- a
  > b
  ```
  c
  ```
- d

### Example 322
- a

### Example 323
- a
  - b

### Example 324
1. ```
   foo
   ```

   bar

### Example 325
* foo
  * bar

  baz

### Example 326
- a
  - b
  - c

- d
  - e
  - f

## Inlines

### Example 327
`hi`lo`

## Code spans

### Example 328
`foo`

### Example 329
`` foo ` bar ``

### Example 330
` `` `

### Example 331
`  ``  `

### Example 332
` a`

### Example 333
` b `

### Example 334
` `
`  `

### Example 335
``
foo
bar  
baz
``

### Example 336
``
foo 
``

### Example 337
`foo   bar 
baz`

### Example 338
`foo\`bar`

### Example 339
``foo`bar``

### Example 340
` foo `` bar `

### Example 341
*foo`*`

### Example 342
[not a `link](/foo`)

### Example 343
`<a href="`">`

### Example 344
<a href="`">`

### Example 345
`<https://foo.bar.`baz>`

### Example 346
<https://foo.bar.`baz>`

### Example 347
```foo``

### Example 348
`foo

### Example 349
`foo``bar``

## Emphasis and strong emphasis

### Example 350
*foo bar*

### Example 351
a * foo bar*

### Example 352
a*"foo"*

### Example 353
* a *

### Example 354
*$*alpha.

*£*bravo.

*€*charlie.

### Example 355
foo*bar*

### Example 356
5*6*78

### Example 357
_foo bar_

### Example 358
_ foo bar_

### Example 359
a_"foo"_

### Example 360
foo_bar_

### Example 361
5_6_78

### Example 362
пристаням_стремятся_

### Example 363
aa_"bb"_cc

### Example 364
foo-_(bar)_

### Example 365
_foo*

### Example 366
*foo bar *

### Example 367
*foo bar
*

### Example 368
*(*foo)

### Example 369
*(*foo*)*

### Example 370
*foo*bar

### Example 371
_foo bar _

### Example 372
_(_foo)

### Example 373
_(_foo_)_

### Example 374
_foo_bar

### Example 375
_пристаням_стремятся

### Example 376
_foo_bar_baz_

### Example 377
_(bar)_.

### Example 378
**foo bar**

### Example 379
** foo bar**

### Example 380
a**"foo"**

### Example 381
foo**bar**

### Example 382
__foo bar__

### Example 383
__ foo bar__

### Example 384
__
foo bar__

### Example 385
a__"foo"__

### Example 386
foo__bar__

### Example 387
5__6__78

### Example 388
пристаням__стремятся__

### Example 389
__foo, __bar__, baz__

### Example 390
foo-__(bar)__

### Example 391
**foo bar **

### Example 392
**(**foo)

### Example 393
*(**foo**)*

### Example 394
**Gomphocarpus (*Gomphocarpus physocarpus*, syn.
*Asclepias physocarpa*)**

### Example 395
**foo "*bar*" foo**

### Example 396
**foo**bar

### Example 397
__foo bar __

### Example 398
__(__foo)

### Example 399
_(__foo__)_

### Example 400
__foo__bar
