# bedsense: AI image prompts for the product renders

One fixed description of the object, then only the view and render style
change per image. Paste the base block at the start of every prompt.

## Base block

```
A contact-free bed sensor for care beds: a flat rectangular pad about the size of a deck of playing cards lying flat and roughly as thick as a finger, matte white polycarbonate top with softly rounded corners and edges, a textured grey silicone anti-slip underside, no screen, no visible seams, no text, no logo. Along one short edge there is a thin horizontal status light bar and a single large soft-touch button; this edge is the only part visible when the pad is slid between the mattress and the bed base. A fabric-covered USB-C cable exits the same edge. Calm medical-device aesthetic, Scandinavian industrial design, premium but plain.
```

## Closed product, different directions

```
[base] Three-quarter view from above, product photography on a white seamless background, soft studio lighting, subtle shadow, photorealistic, single object centred, status light bar glowing soft green.
```

```
[base] Straight-down top view, orthographic, centred on a white background, even lighting, photorealistic.
```

```
[base] Side profile view emphasising how thin the pad is, the lit edge and cable visible, white background, product photography.
```

```
[base] Close-up of the lit edge: the thin status light bar glowing amber and the single large button, shallow depth of field, white background, photorealistic macro product shot.
```

```
[base] Underside view showing the textured grey silicone anti-slip pad covering the whole bottom surface, white background, product photography.
```

```
[base] Front, side and top views arranged in a row like an orthographic drawing sheet, white background, consistent scale, clean product visualisation.
```

## Open (exploded) and cross-section

```
[base] Exploded view technical render: parts separated vertically along one axis with even spacing, top shell with a light pipe for the status bar, rectangular green printed circuit board with a square microcontroller, a tiny motion-sensor chip and a small shielded wireless module, soft-touch button, bottom shell, textured silicone pad below. Thin grey leader lines, white background, clean engineering illustration style, photorealistic materials.
```

```
[base] Cutaway cross-section across the width of the pad showing shell thickness, circuit board, light pipe and silicone pad stacked inside, clean technical illustration, white background, muted colours.
```

## Transparent / ghosted

```
[base] Semi-transparent ghosted shell render, x-ray style, the circuit board and light pipe visible through a frosted translucent housing, subtle internal shading, light grey background, technical product visualisation.
```

```
[base] Fully transparent crystal-clear housing variant with internals visible, dramatic dark background, rim lighting, premium product render.
```

## In use

```
[base] Cutaway illustration of a home care bed from the side: mattress on a slatted base, the pad lying flat between mattress and base at chest level, its lit edge peeking out at the mattress edge glowing green, a thin line showing the cable running to a wall socket, clean technical illustration, no people.
```

```
[base] A bright nursing home bedroom, an empty adjustable care bed with white linen, the sensor's lit edge visible at the mattress edge glowing amber, soft window light, photorealistic, no people, no text.
```

```
[base] A home bedroom at night, lamp on, the sensor's lit edge glowing softly red at the edge of the mattress, bedside table in the foreground, moody but calm, photorealistic, no people.
```

```
[base] A caregiver's hand holding a phone showing a simple notification card with a bed icon and a placeholder line of text, blurred care bed in the background, photorealistic, cropped at the wrist, no face.
```

## Kit and variants

```
[base] Flat lay of the full kit from above: the sensor pad, fabric USB-C cable, small white power adapter, a bed-rail clip for the cable, and a folded quick-start card with no readable text, arranged on a light grey surface, soft shadows, product photography.
```

```
[base] Three colourways side by side on a white background: white, warm grey, clinical blue, same angle and lighting, product photography.
```

## Model-specific notes

- Midjourney: set the aspect ratio to 4:3 and the style to raw in the settings panel
  (16:9 for the bed scenes, 1:1 for the edge close-up). Generate the three-quarter hero first and
  pass it as an image or omni reference to every other prompt so the pad stays
  consistent.
- Stable Diffusion, Flux, ComfyUI: same text, one fixed seed, negative prompt:
  `text, logo, watermark, screen, extra buttons, extra cables, people, face, blurry, deformed`.
- ChatGPT images, Gemini, Ideogram: plain language works as written; in
  follow-ups say "the same device as the previous image".
- Models add displays to anything medical; keep "no screen". They also draw
  readable (gibberish) text on phones and cards; keep "placeholder text" and
  "no readable text".
- "Size of a deck of playing cards" is there because millimetres mean nothing
  to these models. Real dimensions are in `plan.md`.
