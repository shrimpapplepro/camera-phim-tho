# LUT library (local, not in git)

TrueShot's filter library lives here: `catalog.json` plus one PNG strip per LUT.
The repository ships it **empty**. Fill it with your own `.cube` files:

```sh
python3 tools/pack_luts.py ~/path/to/my-cubes
```

See the main README for details.
