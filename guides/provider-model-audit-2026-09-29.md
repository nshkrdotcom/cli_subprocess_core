# Provider model audit — 2026-09-29

Claude’s [model overview](https://platform.claude.com/docs/en/models/overview) lists Fable 5.1, Opus 5.5, Sonnet 5.5, and Haiku 4.5. Pinned 5.5 IDs are retained in CLI arguments. [Claude Code](https://code.claude.com/docs/en/model-config) defaults Opus/Sonnet 5.5 to medium effort; Sonnet’s API default is high. Native aliases remain provider dependent.

[Amp modes](https://ampcode.com/modes) route low/medium/high/ultra to GLM-5.3 Flash, Opus 5.5, GPT-6 Astra, and Fable 5.1 respectively. Core’s `amp-1` is an SDK policy identifier, not a selectable foundation model. This catalog audit does not change Amp mode controls.

[Cursor’s model page](https://cursor.com/docs/models-and-pricing) includes Composer 2.5 and newer third-party models. Those display names do not verify native CLI identifiers; the existing Cursor snapshot remains unchanged pending authenticated discovery. Unknown model passthrough is available explicitly.

[Antigravity models](https://antigravity.google/docs/models/) match authenticated `agy models` on this date. Add the three missing non-Gemini identifiers. Existing Gemini family identifiers and reasoning policy remain compatible.

Claude, Amp, and Cursor verification uses mocks only; no live account claim is made. Antigravity also receives a live SDK smoke test during its release.
