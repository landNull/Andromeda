# Open help from the docs satellite

Open a page from the docs satellite with `-h` or `help`.

## Steps

1. Type `andromeda -h` to open the outline.
2. Type `andromeda -h pull` to open the page for that topic.
3. At any prompt that shows `(? help)`, type `?` or `help` to open the matching page.
4. Press `q` to return to the prompt.

## Result

The short page from the application folder opens. A command row sits at the bottom:

```
q leave   ? more   n next   b back
```

- `q` leaves
- `?` opens the full page
- `n` opens the next related page
- `b` returns

The full page and the related pages come from the docs satellite. The short page stays local.

## See also

- [Standards](https://github.com/landNull/d-LitFunc/blob/main/standards.md)
- [Outline](../outline.md)
