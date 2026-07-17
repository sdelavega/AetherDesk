# Shared Weather Animation Contract

Weather Aether renders a provider-neutral atmospheric state. A new animation
state may be added only when both Open-Meteo and WeatherKit can select it.
Provider-specific labels must fold into the nearest shared state.

| Visual state | Open-Meteo input | WeatherKit input |
| --- | --- | --- |
| `clear` | WMO 0–1 | clear, mostly clear |
| `partly` | WMO 2 | partly cloudy |
| `overcast` | WMO 3 | mostly cloudy, cloudy |
| `fog` | WMO 45, 48 | foggy |
| `rain` | WMO 51–55, 61–65, 80–82 | drizzle, rain, heavy rain, sun showers |
| `freezing` | WMO 56–57, 66–67 | freezing drizzle, freezing rain; wintry mix and sleet fold into this state |
| `snow` | WMO 71–77, 85–86 | flurries, snow, heavy snow; blowing snow and blizzard fold into this state |
| `thunder` | WMO 95 | isolated, scattered, and general thunderstorms; strong and tropical storms fold into this state |
| `hail` | WMO 96, 99 | hail |

WeatherKit-only categories such as smoke, dust, hot, frigid, breezy, and windy
may influence shared parameters in the future, but must not create animations
that Open-Meteo cannot select. Likewise, Open-Meteo-only detail such as rime
fog or snow grains may tune an existing state but must not create a dedicated
animation unavailable to WeatherKit.

Intensity and intermittency are parameters, not new states. Light, moderate,
heavy, steady, and shower variants should change density, speed, gusting, and
timing within the shared animation selected above.

Sources:

- [Open-Meteo WMO weather interpretation codes](https://open-meteo.com/en/docs)
- [WeatherKit WeatherCondition](https://developer.apple.com/documentation/weatherkit/weathercondition)
