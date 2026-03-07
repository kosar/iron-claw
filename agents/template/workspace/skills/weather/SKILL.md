# Weather skill

Use this for any weather request (e.g. "weather in Rome", "weather in Tokyo", "temperature in Paris").

## How to use

Call the **exec** tool with this exact command pattern:

```
curl -s "wttr.in/<CITY>?format=3"
```

Replace `<CITY>` with the place name (e.g. Rome, Tokyo, Paris, London). Examples:

- `curl -s "wttr.in/Rome?format=3"`
- `curl -s "wttr.in/Tokyo?format=3"`
- `curl -s "wttr.in/Paris?format=3"`

Then summarize the output for the user.

**Do not use web_fetch** for weather. Weather websites return 404 when fetched by tools. Always use exec + wttr.in.
