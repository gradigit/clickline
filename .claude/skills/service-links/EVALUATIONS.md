# Evaluations for service-links

## Scenario 1: Happy path — new config (should-trigger)

**Given** user has just deployed their app and has no `.clickline` in the repo
**When** user says "add service links" or runs `/service-links`
**Then**
- [ ] Skill activates
- [ ] Checks for existing `.clickline` (finds none)
- [ ] Asks which services to configure (multiSelect)
- [ ] Collects URLs for each selected service
- [ ] Writes valid JSON to `$PWD/.clickline`
- [ ] Confirms with a summary showing the statusline preview

## Scenario 2: Updating existing config (should-trigger)

**Given** user already has a `.clickline` with a backend and frontend entry
**When** user says "add a database link to my statusline"
**Then**
- [ ] Skill activates
- [ ] Reads and displays existing `.clickline` entries
- [ ] Asks which services to add/update
- [ ] Preserves existing backend and frontend entries
- [ ] Appends new `db` entry
- [ ] Writes merged config back to `.clickline`

## Scenario 3: Edge case — custom label (should-trigger)

**Given** user wants a link to a service not in the preset list
**When** user says "add a link to my Sentry dashboard"
**Then**
- [ ] Skill activates
- [ ] User selects "Custom" option
- [ ] Skill asks for both label and URL
- [ ] Writes entry with custom label (e.g. `{"label": "sentry", "url": "..."}`)

## Scenario 4: Should-NOT-trigger — installing clickline

**Given** user wants to install the clickline statusline for the first time
**When** user says "how do I install clickline" or "set up the statusline"
**Then**
- [ ] Skill does NOT activate
- [ ] General installation instructions are provided instead
- [ ] No `.clickline` file is created
