# Digital Window Truth

> Build the window people wish they had.

This document is the decision filter for Weather Aether's Digital Window work. When implementation novelty, feature pressure, or visual spectacle conflicts with it, this document wins.

## Mission

Create a believable digital window that reconnects people without an exterior view to the atmosphere beyond their walls.

The objective is not merely to display weather. It is to communicate what it feels like outside, then reward a longer look with restrained, mesmerizing detail.

## The one-second rule

Within one second of revealing the desktop, a user should be able to infer the broad state of the outside world before reading any text:

- time of day and quality of light
- clear, cloudy, foggy, wet, snowy, or stormy conditions
- calm or energetic motion
- the atmosphere's overall mood

The information panel confirms what the atmosphere has already communicated.

## Non-negotiable principles

### The atmosphere is the product

Weather observations are inputs. The rendered atmosphere is the experience. Clouds, precipitation, celestial bodies, color, contrast, haze, and motion must feel like parts of one world.

### The renderer serves the atmosphere

Canvas, Three.js, TWGL, shaders, and future rendering technologies are replaceable implementations. Artistic policy belongs in a renderer-independent atmospheric state, not scattered through drawing code.

### Light tells the story first

Conditions change the light before they change individual objects. A rainy scene is not a clear sky with rain drawn over it; the entire atmosphere responds.

### The user infers before reading

The visual field carries the primary signal. Text and icons provide precision and confirmation without competing with the window.

### Motion resembles nature, not software

Movement should be coherent, layered, and restrained. Constant-speed decorative animation weakens the illusion.

### Beauty follows restraint

No effect exists solely because it is impressive. Every visual decision must make the view more believable, legible, or emotionally connected to the outside world.

### Performance is a feature

This is persistent desktop ambience, not a game. Frame rate, resolution, draw calls, overdraw, allocations, network use, and idle work must remain deliberate and measurable. Work that cannot justify its cost is a bug.

### Lively compatibility is sacred

Every delivered wallpaper remains self-contained, portable, and fully functional when imported into Lively. It may not require ÆtherDesk, a CDN, a package manager, a build step, or an external runtime.

### Failure degrades gracefully

The preferred renderer may fall back to a simpler local renderer and ultimately to a static atmospheric presentation. Network failure, missing GPU features, or an unsupported host must never produce a black screen.

## The atmospheric boundary

The intended flow is:

```text
weather + astronomy + location + time + preferences
                         |
                         v
                 atmospheric state
                         |
                         v
                      renderer
```

The atmospheric state expresses visual meaning: light warmth, air clarity, horizon haze, cloud cover, cloud density, celestial visibility, precipitation intensity, motion energy, and related descriptors. Renderers interpret those values; they do not invent them independently.

## Decision questions

Every meaningful change should answer:

1. Does it help a windowless user understand what it feels like outside?
2. Does it strengthen a coherent atmosphere rather than add an isolated effect?
3. Would removing it make the illusion weaker?
4. Does its perceptual value justify its ongoing resource cost?
5. Does the standalone wallpaper still work in Lively?

## What we will not chase

- photorealism for its own sake
- maximum polygon or particle counts
- effects chosen for demo appeal
- framework adoption without measured value
- platform-exclusive paths in the portable baseline
- cloud dependence for the core experience
- benchmark wins that do not improve the perceived window

## Success

Success is hearing:

> I looked at my desktop and knew exactly what it felt like outside.

The renderer should be quiet enough to live with all day and compelling enough that the user occasionally reveals the desktop just to see what the world looks like now.

