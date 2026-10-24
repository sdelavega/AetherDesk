# Shared Weather Animation Contract

Weather Aether renders a provider-neutral atmospheric state. A new animation
state may be added only when both Open-Meteo and WeatherKit can select it.
Provider-specific labels must fold into the nearest shared state.

| Visual state | Open-Meteo input | WeatherKit input (WMO code) |
| --- | --- | --- |
| `clear` | WMO 0–1 | clear (0), mostly clear (1); breezy, windy, hot, frigid (1) |
| `partly` | WMO 2 | partly cloudy (2) |
| `overcast` | WMO 3 | mostly cloudy, cloudy (3) |
| `fog` | WMO 45, 48 | foggy (45); smoky (4), haze (5), blowing dust (7) fold into fog |
| `rain` | WMO 51–55, 61–65, 80–82 | drizzle (51), rain (61), heavy rain (65), sun showers (80) |
| `freezing` | WMO 56–57, 66–67 | freezing drizzle (56), freezing rain (66); wintry mix and sleet (66) fold into this state |
| `snow` | WMO 71–77, 85–86 | flurries, blowing snow, sun flurries (71); snow (73); heavy snow and blizzard (75) |
| `thunder` | WMO 95 | isolated, scattered, and general thunderstorms; strong storms, tropical storm, hurricane (95) |
| `hail` | WMO 96, 99 | hail (96) |

WeatherKit-only smoke, haze, and dust retain their condition labels and fold
into the shared fog animation. Codes 4–7 all select fog, including dust (6).
Hot, frigid, breezy, and windy select clear (1) and may influence shared
parameters in the future, but must not create animations that Open-Meteo
cannot select. Strong storms, tropical storms, and hurricanes select thunder
without inventing hail. Likewise, Open-Meteo-only detail such as rime fog or
snow grains may tune an existing state but must not create a dedicated
animation unavailable to WeatherKit.

Unknown WeatherKit raw strings map to WMO 0. Unrecognized WMO codes, including
68, select the existing clear fallback; 68 is not a new freezing state.

Intensity and intermittency are parameters, not new states. Light, moderate,
heavy, steady, and shower variants should change density, speed, gusting, and
timing within the shared animation selected above.

`Tests/JS/condition-matrix.json` pins every code in `WMO_DESC` plus 68 and all
34 WeatherKit raw conditions. JavaScript tests check the renderer against this
table; Swift tests check exact provider codes and their shared visual states.
The raw strings were verified from the installed SDK's WeatherKit
`.swiftinterface` and `WeatherCondition.allCases.map(\.rawValue)`.

Sources:

- [Open-Meteo WMO weather interpretation codes](https://open-meteo.com/en/docs)
- [WeatherKit WeatherCondition](https://developer.apple.com/documentation/weatherkit/weathercondition)
